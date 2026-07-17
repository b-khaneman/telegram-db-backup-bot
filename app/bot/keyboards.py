from __future__ import annotations

from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup

from app.storage import DatabaseConfig, ScheduleConfig


def main_panel_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [
                InlineKeyboardButton(text="🗄 دیتابیس‌ها", callback_data="dbs"),
                InlineKeyboardButton(text="⚡ بکاپ فوری", callback_data="backup_now"),
            ],
            [
                InlineKeyboardButton(text="⏱ زمان‌بندی", callback_data="schedule"),
                InlineKeyboardButton(text="📊 وضعیت", callback_data="status"),
            ],
            [
                InlineKeyboardButton(text="➕ افزودن دیتابیس", callback_data="db_add"),
                InlineKeyboardButton(text="🔄 تازه‌سازی", callback_data="home"),
            ],
        ]
    )


def databases_kb(dbs: list[DatabaseConfig]) -> InlineKeyboardMarkup:
    rows: list[list[InlineKeyboardButton]] = []
    for db in dbs:
        icon = "🟢" if db.enabled else "⚪"
        rows.append(
            [
                InlineKeyboardButton(
                    text=f"{icon} {db.name} · {db.engine.value}",
                    callback_data=f"db:{db.id}",
                )
            ]
        )
    rows.append(
        [
            InlineKeyboardButton(text="➕ جدید", callback_data="db_add"),
            InlineKeyboardButton(text="◀️ بازگشت", callback_data="home"),
        ]
    )
    return InlineKeyboardMarkup(inline_keyboard=rows)


def db_detail_kb(db: DatabaseConfig) -> InlineKeyboardMarkup:
    toggle = "⏸ غیرفعال" if db.enabled else "▶️ فعال"
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [
                InlineKeyboardButton(
                    text="⚡ بکاپ همین دیتابیس",
                    callback_data=f"backup_one:{db.id}",
                )
            ],
            [
                InlineKeyboardButton(text=toggle, callback_data=f"db_toggle:{db.id}"),
                InlineKeyboardButton(text="🗑 حذف", callback_data=f"db_del:{db.id}"),
            ],
            [InlineKeyboardButton(text="◀️ لیست دیتابیس‌ها", callback_data="dbs")],
        ]
    )


def confirm_delete_kb(db_id: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [
                InlineKeyboardButton(text="✅ بله، حذف شود", callback_data=f"db_del_ok:{db_id}"),
                InlineKeyboardButton(text="❌ انصراف", callback_data=f"db:{db_id}"),
            ]
        ]
    )


def schedule_kb(s: ScheduleConfig) -> InlineKeyboardMarkup:
    en = "🟢 روشن" if s.enabled else "🔴 خاموش"
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [InlineKeyboardButton(text=f"وضعیت: {en}", callback_data="sch_toggle")],
            [
                InlineKeyboardButton(text="⚡ هر N دقیقه", callback_data="sch_mode:minutes"),
                InlineKeyboardButton(text="📅 روزانه", callback_data="sch_mode:daily"),
            ],
            [
                InlineKeyboardButton(text="🔁 هر N ساعت", callback_data="sch_mode:interval"),
                InlineKeyboardButton(text="⏳ دقیقه", callback_data="sch_set_minutes"),
            ],
            [
                InlineKeyboardButton(text="۵د", callback_data="sch_mins:5"),
                InlineKeyboardButton(text="۱۵د", callback_data="sch_mins:15"),
                InlineKeyboardButton(text="۳۰د", callback_data="sch_mins:30"),
            ],
            [
                InlineKeyboardButton(text="🕐 ساعت روزانه", callback_data="sch_set_time"),
                InlineKeyboardButton(text="⏳ بازه ساعت", callback_data="sch_set_interval"),
            ],
            [InlineKeyboardButton(text="◀️ بازگشت", callback_data="home")],
        ]
    )


def engine_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [
                InlineKeyboardButton(text="MySQL", callback_data="engine:mysql"),
                InlineKeyboardButton(text="MariaDB", callback_data="engine:mariadb"),
            ],
            [
                InlineKeyboardButton(text="PostgreSQL", callback_data="engine:postgresql"),
                InlineKeyboardButton(text="SQLite", callback_data="engine:sqlite"),
            ],
            [InlineKeyboardButton(text="❌ انصراف", callback_data="home")],
        ]
    )


def cancel_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[[InlineKeyboardButton(text="❌ انصراف", callback_data="home")]]
    )


def after_backup_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [
                InlineKeyboardButton(text="⚡ دوباره", callback_data="backup_now"),
                InlineKeyboardButton(text="🏠 پنل", callback_data="home"),
            ]
        ]
    )
