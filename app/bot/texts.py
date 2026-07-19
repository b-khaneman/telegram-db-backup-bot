from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

from app.backup import h, human_size
from app.config import get_settings
from app.storage import DatabaseConfig, ScheduleConfig, get_storage


GLASS = "░"


def glass_box(title: str, lines: list[str]) -> str:
    """Telegram «glass panel» text block — clean RTL-friendly admin card."""
    body = "\n".join(f"│  {line}" for line in lines)
    return (
        f"<b>✦ {title}</b>\n"
        f"<code>╭──────────────────────╮</code>\n"
        f"{body}\n"
        f"<code>╰──────────────────────╯</code>"
    )


def home_text() -> str:
    storage = get_storage()
    settings = get_settings()
    dbs = storage.list_databases()
    enabled = sum(1 for d in dbs if d.enabled)
    sch = storage.state.schedule
    sch_line = (
        f"فعال · {sch.next_hint}" if sch.enabled else "غیرفعال"
    )
    now = datetime.now(ZoneInfo(settings.timezone)).strftime("%Y-%m-%d %H:%M")
    return glass_box(
        "پنل مدیریت بکاپ",
        [
            f"دیتابیس‌ها: <b>{len(dbs)}</b> (فعال: {enabled})",
            f"زمان‌بندی: {sch_line}",
            f"منطقه زمانی: {settings.timezone}",
            f"اکنون: {now}",
            "",
            "از دکمه‌های زیر مدیریت کنید.",
        ],
    )


def databases_text(dbs: list[DatabaseConfig]) -> str:
    if not dbs:
        return glass_box(
            "دیتابیس‌ها",
            ["هنوز دیتابیسی ثبت نشده.", "با «➕ جدید» اضافه کنید."],
        )
    lines = []
    for i, db in enumerate(dbs, 1):
        flag = "ON" if db.enabled else "OFF"
        lines.append(f"{i}. <b>{db.name}</b> [{db.engine.value}] {flag}")
        lines.append(f"   {db.display_target()}")
    return glass_box("دیتابیس‌ها", lines)


def db_detail_text(db: DatabaseConfig) -> str:
    return glass_box(
        f"دیتابیس · {db.name}",
        [
            f"موتور: <b>{db.engine.value}</b>",
            f"هدف: <code>{db.display_target()}</code>",
            f"کاربر: <code>{db.user or '—'}</code>",
            f"وضعیت: {'فعال' if db.enabled else 'غیرفعال'}",
            f"شناسه: <code>{db.id}</code>",
        ],
    )


def schedule_text(s: ScheduleConfig) -> str:
    settings = get_settings()
    last = "—"
    if s.last_run_at:
        last = datetime.fromtimestamp(s.last_run_at, ZoneInfo(settings.timezone)).strftime(
            "%Y-%m-%d %H:%M"
        )
    if s.mode in ("minutes", "interval_minutes"):
        mode = f"هر {s.interval_minutes} دقیقه"
    elif s.mode == "interval":
        mode = f"هر {s.interval_hours} ساعت"
    else:
        mode = "روزانه (cron)"
    return glass_box(
        "زمان‌بندی بکاپ خودکار",
        [
            f"وضعیت: {'🟢 فعال' if s.enabled else '🔴 خاموش'}",
            f"حالت: {mode}",
            f"ساعت روزانه: {s.hour:02d}:{s.minute:02d}",
            f"بازه ساعتی: هر {s.interval_hours} ساعت",
            f"بازه دقیقه‌ای: هر {s.interval_minutes} دقیقه",
            f"آخرین اجرا: {last}",
            f"برنامه: {s.next_hint or '—'}",
            "",
            "بکاپ‌ها به‌صورت ZIP به تلگرام ارسال می‌شوند.",
        ],
    )


def status_text() -> str:
    settings = get_settings()
    storage = get_storage()
    backups = sorted(
        [
            p
            for p in settings.backup_dir.iterdir()
            if p.is_file() and p.suffix.lower() in {".zip", ".gz"}
        ],
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )[:8]
    lines = [
        f"مسیر بکاپ: <code>{settings.backup_dir}</code>",
        f"نگهداری محلی: آخرین {storage.state.keep_local_backups} فایل",
        f"دیتابیس ثبت‌شده: {len(storage.list_databases())}",
        "",
        "آخرین فایل‌ها:",
    ]
    if not backups:
        lines.append("— هیچ فایلی نیست")
    else:
        for p in backups:
            sz = human_size(p.stat().st_size)
            lines.append(f"• {p.name} ({sz})")
    return glass_box("وضعیت سیستم", lines)


def backup_progress_text(name: str) -> str:
    return glass_box("در حال بکاپ…", [f"دیتابیس: <b>{name}</b>", "لطفاً صبر کنید."])


def backup_done_line(ok: bool, name: str, size: int, duration: float, err: str | None) -> str:
    if ok:
        return f"✅ <b>{h(name)}</b> — {human_size(size)} · {duration}s"
    return f"❌ <b>{h(name)}</b> — {h(err) if err else 'خطا'}"
