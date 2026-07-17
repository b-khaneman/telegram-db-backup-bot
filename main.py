from __future__ import annotations

import asyncio
import logging
import sys

import uvicorn
from aiogram import Bot
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.types import Update
from fastapi import Request, Response

from app.backup import BackupResult
from app.bot import build_dispatcher
from app.bot.handlers import run_and_deliver, send_backup_file
from app.config import get_settings
from app.scheduler import get_scheduler
from app.storage import get_storage
from app.web import create_web_app, set_backup_notifier

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-7s | %(name)s | %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("backup-bot")


def _delivery_chat_id() -> int | None:
    settings = get_settings()
    storage = get_storage()
    if settings.backup_chat_id:
        return settings.backup_chat_id
    if storage.state.notify_chat_id:
        return storage.state.notify_chat_id
    if settings.admin_ids:
        return settings.admin_ids[0]
    return None


async def main() -> None:
    settings = get_settings()
    if not settings.admin_ids:
        logger.error("ADMIN_IDS خالی است. حداقل یک آیدی عددی در .env بگذارید.")
        sys.exit(1)

    bot = Bot(
        token=settings.bot_token,
        default=DefaultBotProperties(parse_mode=ParseMode.HTML),
    )
    dp = build_dispatcher()
    scheduler = get_scheduler()

    async def notify_results(results: list[BackupResult]) -> None:
        chat_id = _delivery_chat_id()
        if not chat_id:
            logger.warning("No chat_id for backup delivery")
            return
        for r in results:
            await send_backup_file(bot, chat_id, r)

    async def scheduled_job() -> None:
        chat_id = _delivery_chat_id()
        if not chat_id:
            logger.warning("Scheduled backup skipped: no chat_id")
            return
        logger.info("Running scheduled backup…")
        await run_and_deliver(bot, chat_id, status_message=None)

    set_backup_notifier(notify_results)
    scheduler.set_callback(scheduled_job)
    scheduler.start()

    web = create_web_app()

    webhook_path = settings.webhook_path if settings.webhook_path.startswith("/") else f"/{settings.webhook_path}"

    @web.post(webhook_path)
    async def telegram_webhook(request: Request) -> Response:
        if settings.webhook_secret:
            header = request.headers.get("X-Telegram-Bot-Api-Secret-Token", "")
            if header != settings.webhook_secret:
                return Response(status_code=403)
        data = await request.json()
        update = Update.model_validate(data, context={"bot": bot})
        await dp.feed_update(bot=bot, update=update)
        return Response(content='{"ok":true}', media_type="application/json")

    config = uvicorn.Config(
        web,
        host=settings.web_host,
        port=settings.web_port,
        log_level="info",
        loop="asyncio",
    )
    server = uvicorn.Server(config)

    use_webhook = settings.use_webhook()
    webhook_url = settings.resolved_webhook_url()

    logger.info(
        "Starting | mode=%s | panel http://%s:%s | tz=%s",
        "webhook" if use_webhook else "polling",
        settings.web_host,
        settings.web_port,
        settings.timezone,
    )

    try:
        if use_webhook and webhook_url:
            kwargs: dict = {
                "url": webhook_url,
                "drop_pending_updates": True,
                "allowed_updates": dp.resolve_used_update_types(),
            }
            if settings.webhook_secret:
                kwargs["secret_token"] = settings.webhook_secret
            await bot.set_webhook(**kwargs)
            logger.info("Webhook set: %s", webhook_url)
            await server.serve()
        else:
            await bot.delete_webhook(drop_pending_updates=False)
            await asyncio.gather(
                dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types()),
                server.serve(),
            )
    finally:
        scheduler.shutdown()
        await bot.session.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Stopped")
