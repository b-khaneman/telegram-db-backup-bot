from __future__ import annotations

from typing import Any, Awaitable, Callable, Dict

from aiogram import BaseMiddleware
from aiogram.types import CallbackQuery, Message, TelegramObject

from app.config import get_settings


class AdminOnlyMiddleware(BaseMiddleware):
    async def __call__(
        self,
        handler: Callable[[TelegramObject, Dict[str, Any]], Awaitable[Any]],
        event: TelegramObject,
        data: Dict[str, Any],
    ) -> Any:
        settings = get_settings()
        user = None
        if isinstance(event, Message):
            user = event.from_user
        elif isinstance(event, CallbackQuery):
            user = event.from_user

        if not user or user.id not in settings.admin_ids:
            if isinstance(event, Message):
                await event.answer("⛔️ دسترسی فقط برای ادمین مجاز است.")
            elif isinstance(event, CallbackQuery):
                await event.answer("⛔️ دسترسی ندارید", show_alert=True)
            return None
        return await handler(event, data)
