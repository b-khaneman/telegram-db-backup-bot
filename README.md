# Telegram DB Backup Bot — Backup Glass

ربات تلگرام + پنل وب شیشه‌ای برای بکاپ MySQL / MariaDB / PostgreSQL / SQLite.

## پنل حرفه‌ای

- داشبورد: آخرین بکاپ، موفقیت/شکست، حجم، شمارش‌معکوس اجرای بعدی
- مدیریت چند دیتابیس (افزودن / تست اتصال / بکاپ تکی / حذف)
- بکاپ فوری + دانلود فایل از تاریخچه
- زمان‌بندی: هر N دقیقه (پیوسته) / روزانه / هر N ساعت
- نگهداری محلی (keep N)، فعالیت اخیر، تغییر رمز پنل

## نصب تعاملی روی Ubuntu (۲۲.۰۴ / ۲۴.۰۴)

```bash
cd telegram-db-backup-bot
chmod +x scripts/install-ubuntu.sh scripts/restart-service.sh
sudo bash scripts/install-ubuntu.sh
```

سوال‌های ترمینال:

1. **BOT_TOKEN** — اعتبارسنجی با `getMe`
2. **ADMIN_IDS** — آیدی عددی (با کاما)
3. **PUBLIC_BASE_URL** — اگر `https://...` بدهید، خودکار `setWebhook` روی `/telegram/webhook`؛ وگرنه **polling**
4. رمز پنل وب (+ تولید `WEB_SECRET`)
5. پورت پنل
6. بازه بکاپ پیوسته (دقیقه، پیش‌فرض ۱۵)
7. دیتابیس: **تشخیص خودکار** (`~/.my.cnf`، WordPress در `/var/www`، docker-compose) یا **دستی** + نام دیتابیس هدف

سرویس systemd با `systemctl restart backup-bot` بالا می‌آید.

**Webhook** به HTTPS عمومی (Nginx/Caddy) نیاز دارد که به پورت پنل پروکسی شود.

## توسعه محلی

```bash
python3 -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env
# ویرایش BOT_TOKEN و ADMIN_IDS
python main.py
```

پنل: `http://127.0.0.1:8080`

## تلگرام

`/start` → پنل دکمه‌ای · ⚡ بکاپ فوری · ⏱ زمان‌بندی · 🗄 دیتابیس‌ها

## امنیت

فایل `.env` و `data/state.json` و بکاپ‌ها در git نیستند. رمزها را commit نکنید.
