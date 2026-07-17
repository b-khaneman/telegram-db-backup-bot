# راهنمای نصب — Backup Glass (فارسی)

نسخهٔ خلاصه و متمرکز نصب. راهنمای کامل‌تر در [README.md](../README.md) است.

## کلون

```bash
git clone https://github.com/b-khaneman/telegram-db-backup-bot.git
cd telegram-db-backup-bot
```

ریپو: https://github.com/b-khaneman/telegram-db-backup-bot

## پیش‌نیاز

- Ubuntu 22.04 / 24.04 + sudo
- توکن BotFather
- آیدی عددی ادمین تلگرام
- برای webhook: دامنه HTTPS که به پورت پنل پروکسی شود

## نصب یک‌خطی (تعاملی)

```bash
chmod +x scripts/install-ubuntu.sh scripts/restart-service.sh
sudo bash scripts/install-ubuntu.sh
```

### سوال‌های اسکریپت

1. **BOT_TOKEN** — اعتبارسنجی با API تلگرام  
2. **ADMIN_IDS** — عدد(ها) با کاما  
3. **PUBLIC_BASE_URL** — `https://...` = webhook؛ خالی = polling  
4. رمز پنل وب (خالی = تصادفی)  
5. پورت پنل (پیش‌فرض ۸۰۸۰)  
6. بازه بکاپ دقیقه‌ای (پیش‌فرض ۱۵)  
7. دیتابیس: تشخیص خودکار یا دستی  

مسیر نصب پیش‌فرض: `/opt/telegram-db-backup-bot`  
سرویس: `backup-bot`

## بعد از نصب

```bash
sudo systemctl status backup-bot
sudo journalctl -u backup-bot -f
```

پنل: `http://IP-SERVER:PORT` با رمز نمایش‌داده‌شده در پایان نصب.

## `.env` دستی

```bash
cp .env.example .env
```

فیلدهای مهم: `BOT_TOKEN`, `ADMIN_IDS`, `WEB_PORT`, `WEB_SECRET`, `PANEL_PASSWORD`, `PUBLIC_BASE_URL`, `KEEP_LOCAL_BACKUPS`, `TIMEZONE`.

جزئیات جدول فیلدها در README.

## ربات تلگرام

`/start` → دکمه‌ها: دیتابیس‌ها، بکاپ فوری، زمان‌بندی، وضعیت، افزودن دیتابیس.

## به‌روزرسانی

```bash
cd /path/to/telegram-db-backup-bot
git pull origin main
# همگام‌سازی به /opt و ری‌استارت — ببینید README بخش «به‌روزرسانی از گیت»
sudo systemctl restart backup-bot
```

`.env` و `data/` را نگه دارید؛ overwrite نکنید.
