from __future__ import annotations

import logging
from pathlib import Path

from aiogram import Bot, F, Router
from aiogram.filters import Command, CommandStart, StateFilter
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import CallbackQuery, FSInputFile, Message

from app.backup import (
    TELEGRAM_MAX_BYTES,
    BackupResult,
    create_backup,
    format_backup_caption_ex,
    zip_listing_messages,
)
from app.bot import keyboards as kb
from app.bot import texts
from app.config import get_settings
from app.scheduler import get_scheduler
from app.storage import get_storage

logger = logging.getLogger(__name__)
router = Router(name="admin")


class AddDb(StatesGroup):
    engine = State()
    name = State()
    host = State()
    port = State()
    user = State()
    password = State()
    database = State()
    file_path = State()


class SchEdit(StatesGroup):
    time = State()
    interval = State()
    minutes = State()


def _target_chat(message_chat_id: int) -> int:
    settings = get_settings()
    storage = get_storage()
    return (
        settings.backup_chat_id
        or storage.state.notify_chat_id
        or message_chat_id
    )


async def send_backup_file(bot: Bot, chat_id: int, result: BackupResult) -> None:
    if not result.ok or not result.path or not result.path.exists():
        await bot.send_message(
            chat_id,
            texts.backup_done_line(False, result.db_name, 0, result.duration_sec, result.error),
            parse_mode="HTML",
        )
        return

    caption, omitted = format_backup_caption_ex(result)

    if result.size > TELEGRAM_MAX_BYTES:
        await bot.send_message(
            chat_id,
            f"{caption}\n\n⚠️ فایل بزرگ‌تر از محدودیت تلگرام است.\n"
            f"مسیر سرور: <code>{result.path}</code>",
            parse_mode="HTML",
        )
    else:
        await bot.send_document(
            chat_id,
            document=FSInputFile(result.path),
            caption=caption,
            parse_mode="HTML",
        )

    # Caption is capped at 1024 chars; when entries were omitted, deliver the
    # complete archive listing in follow-up messages (no silent truncation).
    if omitted > 0:
        for msg in zip_listing_messages(result):
            try:
                await bot.send_message(chat_id, msg, parse_mode="HTML")
            except Exception:  # noqa: BLE001
                logger.exception("Failed to send zip listing chunk")


async def run_and_deliver(
    bot: Bot,
    chat_id: int,
    status_message: Message | None = None,
) -> list[BackupResult]:
    storage = get_storage()
    dbs = [d for d in storage.list_databases() if d.enabled]
    if not dbs:
        if status_message:
            await status_message.edit_text(
                texts.glass_box("بکاپ", ["دیتابیس فعالی وجود ندارد."]),
                parse_mode="HTML",
                reply_markup=kb.after_backup_kb(),
            )
        return []

    results: list[BackupResult] = []
    for db in dbs:
        if status_message:
            try:
                await status_message.edit_text(
                    texts.backup_progress_text(db.name),
                    parse_mode="HTML",
                )
            except Exception:  # noqa: BLE001
                pass
        result = await create_backup(db)
        results.append(result)
        await send_backup_file(bot, chat_id, result)

    ok_n = sum(1 for r in results if r.ok)
    summary = texts.glass_box(
        "نتیجه بکاپ",
        [
            f"موفق: <b>{ok_n}</b> / {len(results)}",
            *[
                texts.backup_done_line(r.ok, r.db_name, r.size, r.duration_sec, r.error, r.warning)
                for r in results
            ],
        ],
    )
    if status_message:
        await status_message.edit_text(
            summary,
            parse_mode="HTML",
            reply_markup=kb.after_backup_kb(),
        )
    else:
        await bot.send_message(chat_id, summary, parse_mode="HTML", reply_markup=kb.after_backup_kb())
    return results


@router.message(CommandStart())
async def cmd_start(message: Message, state: FSMContext) -> None:
    await state.clear()
    storage = get_storage()
    storage.set_notify_chat(message.chat.id)
    await message.answer(
        texts.home_text(),
        parse_mode="HTML",
        reply_markup=kb.main_panel_kb(),
    )


@router.message(Command("panel", "menu", "home"))
async def cmd_panel(message: Message, state: FSMContext) -> None:
    await state.clear()
    await message.answer(
        texts.home_text(),
        parse_mode="HTML",
        reply_markup=kb.main_panel_kb(),
    )


@router.message(Command("backup"))
async def cmd_backup(message: Message, bot: Bot) -> None:
    status = await message.answer(
        texts.glass_box("بکاپ فوری", ["شروع…"]),
        parse_mode="HTML",
    )
    await run_and_deliver(bot, _target_chat(message.chat.id), status)


@router.callback_query(F.data == "home")
async def cb_home(call: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.home_text(),
        parse_mode="HTML",
        reply_markup=kb.main_panel_kb(),
    )
    await call.answer()


@router.callback_query(F.data == "dbs")
async def cb_dbs(call: CallbackQuery) -> None:
    dbs = get_storage().list_databases()
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.databases_text(dbs),
        parse_mode="HTML",
        reply_markup=kb.databases_kb(dbs),
    )
    await call.answer()


@router.callback_query(F.data == "status")
async def cb_status(call: CallbackQuery) -> None:
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.status_text(),
        parse_mode="HTML",
        reply_markup=kb.main_panel_kb(),
    )
    await call.answer()


@router.callback_query(F.data == "schedule")
async def cb_schedule(call: CallbackQuery) -> None:
    s = get_storage().state.schedule
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.schedule_text(s),
        parse_mode="HTML",
        reply_markup=kb.schedule_kb(s),
    )
    await call.answer()


@router.callback_query(F.data == "sch_toggle")
async def cb_sch_toggle(call: CallbackQuery) -> None:
    storage = get_storage()
    s = storage.state.schedule
    storage.set_schedule(enabled=not s.enabled)
    get_scheduler().reload()
    s = storage.state.schedule
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.schedule_text(s),
        parse_mode="HTML",
        reply_markup=kb.schedule_kb(s),
    )
    await call.answer("زمان‌بندی به‌روز شد")


@router.callback_query(F.data.startswith("sch_mode:"))
async def cb_sch_mode(call: CallbackQuery) -> None:
    mode = call.data.split(":")[1]  # type: ignore[union-attr]
    storage = get_storage()
    storage.set_schedule(mode=mode)
    get_scheduler().reload()
    s = storage.state.schedule
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.schedule_text(s),
        parse_mode="HTML",
        reply_markup=kb.schedule_kb(s),
    )
    await call.answer()


@router.callback_query(F.data.startswith("sch_preset:"))
async def cb_sch_preset(call: CallbackQuery) -> None:
    _, h, m = call.data.split(":")  # type: ignore[union-attr]
    storage = get_storage()
    storage.set_schedule(hour=int(h), minute=int(m), mode="daily", enabled=True)
    get_scheduler().reload()
    s = storage.state.schedule
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.schedule_text(s),
        parse_mode="HTML",
        reply_markup=kb.schedule_kb(s),
    )
    await call.answer(f"تنظیم روی {int(h):02d}:{int(m):02d}")


@router.callback_query(F.data == "sch_set_time")
async def cb_sch_set_time(call: CallbackQuery, state: FSMContext) -> None:
    await state.set_state(SchEdit.time)
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.glass_box(
            "تنظیم ساعت",
            ["ساعت را به صورت HH:MM بفرستید.", "مثال: <code>03:30</code>"],
        ),
        parse_mode="HTML",
        reply_markup=kb.cancel_kb(),
    )
    await call.answer()


@router.message(SchEdit.time)
async def msg_sch_time(message: Message, state: FSMContext) -> None:
    raw = (message.text or "").strip()
    try:
        hh, mm = raw.split(":")
        hour, minute = int(hh), int(mm)
        if not (0 <= hour <= 23 and 0 <= minute <= 59):
            raise ValueError
    except ValueError:
        await message.answer("❌ فرمت نامعتبر. مثال: 03:30", reply_markup=kb.cancel_kb())
        return
    storage = get_storage()
    storage.set_schedule(hour=hour, minute=minute, mode="daily")
    get_scheduler().reload()
    await state.clear()
    s = storage.state.schedule
    await message.answer(
        texts.schedule_text(s),
        parse_mode="HTML",
        reply_markup=kb.schedule_kb(s),
    )


@router.callback_query(F.data.startswith("sch_mins:"))
async def cb_sch_mins(call: CallbackQuery) -> None:
    mins = int(call.data.split(":")[1])  # type: ignore[union-attr]
    storage = get_storage()
    storage.set_schedule(interval_minutes=mins, mode="minutes", enabled=True)
    get_scheduler().reload()
    s = storage.state.schedule
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.schedule_text(s),
        parse_mode="HTML",
        reply_markup=kb.schedule_kb(s),
    )
    await call.answer(f"هر {mins} دقیقه")


@router.callback_query(F.data == "sch_set_minutes")
async def cb_sch_set_minutes(call: CallbackQuery, state: FSMContext) -> None:
    await state.set_state(SchEdit.minutes)
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.glass_box(
            "بازه دقیقه‌ای",
            ["عدد بین ۱ تا ۶۰ بفرستید.", "مثال: <code>10</code>"],
        ),
        parse_mode="HTML",
        reply_markup=kb.cancel_kb(),
    )
    await call.answer()


@router.message(SchEdit.minutes)
async def msg_sch_minutes(message: Message, state: FSMContext) -> None:
    try:
        mins = int((message.text or "").strip())
        if mins < 1 or mins > 60:
            raise ValueError
    except ValueError:
        await message.answer("❌ عدد بین ۱ تا ۶۰", reply_markup=kb.cancel_kb())
        return
    storage = get_storage()
    storage.set_schedule(interval_minutes=mins, mode="minutes")
    get_scheduler().reload()
    await state.clear()
    s = storage.state.schedule
    await message.answer(
        texts.schedule_text(s),
        parse_mode="HTML",
        reply_markup=kb.schedule_kb(s),
    )


@router.callback_query(F.data == "sch_set_interval")
async def cb_sch_set_interval(call: CallbackQuery, state: FSMContext) -> None:
    await state.set_state(SchEdit.interval)
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.glass_box(
            "بازه بکاپ",
            ["تعداد ساعت را عدد بفرستید.", "مثال: <code>6</code> → هر ۶ ساعت"],
        ),
        parse_mode="HTML",
        reply_markup=kb.cancel_kb(),
    )
    await call.answer()


@router.message(SchEdit.interval)
async def msg_sch_interval(message: Message, state: FSMContext) -> None:
    try:
        hours = int((message.text or "").strip())
        if hours < 1 or hours > 168:
            raise ValueError
    except ValueError:
        await message.answer("❌ عدد بین ۱ تا ۱۶۸ بفرستید.", reply_markup=kb.cancel_kb())
        return
    storage = get_storage()
    storage.set_schedule(interval_hours=hours, mode="interval")
    get_scheduler().reload()
    await state.clear()
    s = storage.state.schedule
    await message.answer(
        texts.schedule_text(s),
        parse_mode="HTML",
        reply_markup=kb.schedule_kb(s),
    )


@router.callback_query(F.data == "backup_now")
async def cb_backup_now(call: CallbackQuery, bot: Bot) -> None:
    await call.answer("شروع بکاپ…")
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.glass_box("بکاپ فوری", ["در صف…"]),
        parse_mode="HTML",
    )
    await run_and_deliver(bot, _target_chat(call.message.chat.id), call.message)  # type: ignore[union-attr]


@router.callback_query(F.data.startswith("backup_one:"))
async def cb_backup_one(call: CallbackQuery, bot: Bot) -> None:
    db_id = call.data.split(":")[1]  # type: ignore[union-attr]
    db = get_storage().get_database(db_id)
    if not db:
        await call.answer("یافت نشد", show_alert=True)
        return
    await call.answer("بکاپ…")
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.backup_progress_text(db.name),
        parse_mode="HTML",
    )
    result = await create_backup(db)
    chat_id = _target_chat(call.message.chat.id)  # type: ignore[union-attr]
    await send_backup_file(bot, chat_id, result)
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.glass_box(
            "نتیجه",
            [texts.backup_done_line(result.ok, result.db_name, result.size, result.duration_sec, result.error, result.warning)],
        ),
        parse_mode="HTML",
        reply_markup=kb.db_detail_kb(db),
    )


@router.callback_query(F.data.startswith("db:"))
async def cb_db_detail(call: CallbackQuery) -> None:
    db_id = call.data.split(":")[1]  # type: ignore[union-attr]
    db = get_storage().get_database(db_id)
    if not db:
        await call.answer("یافت نشد", show_alert=True)
        return
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.db_detail_text(db),
        parse_mode="HTML",
        reply_markup=kb.db_detail_kb(db),
    )
    await call.answer()


@router.callback_query(F.data.startswith("db_toggle:"))
async def cb_db_toggle(call: CallbackQuery) -> None:
    db_id = call.data.split(":")[1]  # type: ignore[union-attr]
    db = get_storage().get_database(db_id)
    if not db:
        await call.answer("یافت نشد", show_alert=True)
        return
    get_storage().update_database(db_id, enabled=not db.enabled)
    db = get_storage().get_database(db_id)
    assert db
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.db_detail_text(db),
        parse_mode="HTML",
        reply_markup=kb.db_detail_kb(db),
    )
    await call.answer("وضعیت تغییر کرد")


@router.callback_query(F.data.startswith("db_del:"))
async def cb_db_del(call: CallbackQuery) -> None:
    db_id = call.data.split(":")[1]  # type: ignore[union-attr]
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.glass_box("تأیید حذف", ["آیا مطمئن هستید؟ این عمل برگشت‌پذیر نیست."]),
        parse_mode="HTML",
        reply_markup=kb.confirm_delete_kb(db_id),
    )
    await call.answer()


@router.callback_query(F.data.startswith("db_del_ok:"))
async def cb_db_del_ok(call: CallbackQuery) -> None:
    db_id = call.data.split(":")[1]  # type: ignore[union-attr]
    get_storage().delete_database(db_id)
    dbs = get_storage().list_databases()
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.databases_text(dbs),
        parse_mode="HTML",
        reply_markup=kb.databases_kb(dbs),
    )
    await call.answer("حذف شد")


# ── Add database wizard ──────────────────────────────────────────────

@router.callback_query(F.data == "db_add")
async def cb_db_add(call: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await state.set_state(AddDb.engine)
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.glass_box("افزودن دیتابیس", ["موتور دیتابیس را انتخاب کنید:"]),
        parse_mode="HTML",
        reply_markup=kb.engine_kb(),
    )
    await call.answer()


@router.callback_query(F.data.startswith("engine:"), StateFilter(AddDb.engine))
async def cb_engine(call: CallbackQuery, state: FSMContext) -> None:
    engine = call.data.split(":")[1]  # type: ignore[union-attr]
    await state.update_data(engine=engine)
    await state.set_state(AddDb.name)
    await call.message.edit_text(  # type: ignore[union-attr]
        texts.glass_box("نام نمایشی", ["یک نام کوتاه برای این اتصال بفرستید.", "مثال: <code>فروشگاه اصلی</code>"]),
        parse_mode="HTML",
        reply_markup=kb.cancel_kb(),
    )
    await call.answer()


@router.message(AddDb.name)
async def add_name(message: Message, state: FSMContext) -> None:
    name = (message.text or "").strip()
    if len(name) < 2:
        await message.answer("نام خیلی کوتاه است.", reply_markup=kb.cancel_kb())
        return
    await state.update_data(name=name)
    data = await state.get_data()
    if data.get("engine") == "sqlite":
        await state.set_state(AddDb.file_path)
        await message.answer(
            texts.glass_box("مسیر فایل", ["مسیر کامل فایل SQLite را بفرستید.", "مثال: <code>/var/www/app.db</code>"]),
            parse_mode="HTML",
            reply_markup=kb.cancel_kb(),
        )
        return
    await state.set_state(AddDb.host)
    await message.answer(
        texts.glass_box("هاست", ["آدرس سرور را بفرستید.", "مثال: <code>127.0.0.1</code>"]),
        parse_mode="HTML",
        reply_markup=kb.cancel_kb(),
    )


@router.message(AddDb.host)
async def add_host(message: Message, state: FSMContext) -> None:
    await state.update_data(host=(message.text or "").strip())
    await state.set_state(AddDb.port)
    data = await state.get_data()
    default = "5432" if data.get("engine") == "postgresql" else "3306"
    await message.answer(
        texts.glass_box("پورت", [f"پورت را بفرستید یا <code>{default}</code> را ارسال کنید."]),
        parse_mode="HTML",
        reply_markup=kb.cancel_kb(),
    )


@router.message(AddDb.port)
async def add_port(message: Message, state: FSMContext) -> None:
    try:
        port = int((message.text or "").strip())
    except ValueError:
        await message.answer("پورت نامعتبر است.", reply_markup=kb.cancel_kb())
        return
    await state.update_data(port=port)
    await state.set_state(AddDb.user)
    await message.answer(
        texts.glass_box("کاربر", ["نام کاربری دیتابیس را بفرستید."]),
        parse_mode="HTML",
        reply_markup=kb.cancel_kb(),
    )


@router.message(AddDb.user)
async def add_user(message: Message, state: FSMContext) -> None:
    await state.update_data(user=(message.text or "").strip())
    await state.set_state(AddDb.password)
    await message.answer(
        texts.glass_box("رمز عبور", ["رمز را بفرستید. اگر خالی است <code>-</code> بفرستید."]),
        parse_mode="HTML",
        reply_markup=kb.cancel_kb(),
    )


@router.message(AddDb.password)
async def add_password(message: Message, state: FSMContext) -> None:
    pwd = (message.text or "").strip()
    if pwd == "-":
        pwd = ""
    await state.update_data(password=pwd)
    await state.set_state(AddDb.database)
    await message.answer(
        texts.glass_box("نام دیتابیس", ["نام دیتابیس را بفرستید."]),
        parse_mode="HTML",
        reply_markup=kb.cancel_kb(),
    )


@router.message(AddDb.database)
async def add_database(message: Message, state: FSMContext) -> None:
    await state.update_data(database=(message.text or "").strip())
    data = await state.get_data()
    db = get_storage().add_database(**data)
    await state.clear()
    # best-effort delete password message
    try:
        await message.delete()
    except Exception:  # noqa: BLE001
        pass
    await message.answer(
        texts.glass_box("ثبت شد ✅", [f"<b>{db.name}</b> اضافه شد.", db.display_target()]),
        parse_mode="HTML",
        reply_markup=kb.db_detail_kb(db),
    )


@router.message(AddDb.file_path)
async def add_sqlite_path(message: Message, state: FSMContext) -> None:
    path = (message.text or "").strip()
    if not Path(path).exists():
        await message.answer(
            "⚠️ فایل فعلاً وجود ندارد؛ در هر صورت ذخیره می‌شود. اگر مسیر اشتباه است بعداً ویرایش کنید.",
        )
    await state.update_data(file_path=path, host="", port=0, user="", password="", database="")
    data = await state.get_data()
    db = get_storage().add_database(**data)
    await state.clear()
    await message.answer(
        texts.glass_box("ثبت شد ✅", [f"<b>{db.name}</b> (SQLite)", f"<code>{path}</code>"]),
        parse_mode="HTML",
        reply_markup=kb.db_detail_kb(db),
    )
