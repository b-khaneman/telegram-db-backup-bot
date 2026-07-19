# Telegram DB Backup Bot — Backup Glass

ربات تلگرام + پنل وب برای بکاپ **MySQL / MariaDB / PostgreSQL / SQLite**.

- **بکاپ کامل و قابل بازیابی:** MySQL/MariaDB با `--databases` (شامل CREATE DATABASE) + routines/triggers/events؛ PostgreSQL با `--create`؛ SQLite با `.backup` سازگار.
- **ارسال ZIP به تلگرام با فهرست کامل محتویات:** نام و حجم هر فایل داخل ZIP در کپشن؛ اگر فهرست در سقف ۱۰۲۴ کاراکتری کپشن جا نشود، ادامهٔ کامل فهرست در پیام(های) بعدی ارسال می‌شود — هیچ فایلی از قلم نمی‌افتد.

> راهنمای کامل نصب فارسی همین صفحه است. نسخهٔ جدا: [docs/INSTALL-FA.md](docs/INSTALL-FA.md)

---

## لینک ریپو / کلون

| | |
|---|---|
| **ریپو** | https://github.com/b-khaneman/telegram-db-backup-bot |
| **کلون** | دستور زیر |

```bash
git clone https://github.com/b-khaneman/telegram-db-backup-bot.git
cd telegram-db-backup-bot
```

---

## پیش‌نیازها

- سرور **Ubuntu 22.04 یا 24.04** (برای نصب با اسکریپت)
- دسترسی `sudo` / root
- توکن ربات از [@BotFather](https://t.me/BotFather)
- آیدی عددی ادمین تلگرام (مثلاً با [@userinfobot](https://t.me/userinfobot))
- برای **webhook**: دامنه با **HTTPS** عمومی که به پورت پنل پروکسی شود (Nginx/Caddy). بدون آن از **polling** استفاده کنید.
- کلاینت دیتابیس روی سرور (اسکریپت نصب معمولاً `mysql` / `mariadb-client` / `postgresql-client` / `sqlite3` را نصب می‌کند)

---

## نصب سریع روی Ubuntu (گام‌به‌گام)

### ۱) کلون پروژه

```bash
git clone https://github.com/b-khaneman/telegram-db-backup-bot.git
cd telegram-db-backup-bot
```

### ۲) منوی مدیریت (نصب / آپدیت / سرویس)

```bash
chmod +x scripts/install-ubuntu.sh scripts/restart-service.sh
sudo bash scripts/install-ubuntu.sh
```

به‌صورت پیش‌فرض **منوی فارسی** باز می‌شود:

| گزینه | کار |
|------|-----|
| ۱ | نصب / نصب مجدد |
| ۲ | به‌روزرسانی از GitHub (`origin/main`) بدون بازنویسی `.env` و `data/` |
| ۳ | ری‌استارت سرویس `backup-bot` |
| ۴ | وضعیت / لاگ |
| ۵ | واردات دیتابیس پاسارگارد از `/opt/pasarguard/.env` |
| ۶ | تعمیر MariaDB پاسارگارد (`mariadb-upgrade` داخل کانتینر — رفع خطای mysql.proc) |
| ۰ | خروج |

میانبر بدون منو:

```bash
sudo bash scripts/install-ubuntu.sh install
sudo bash scripts/install-ubuntu.sh update
sudo bash scripts/install-ubuntu.sh restart
sudo bash scripts/install-ubuntu.sh status
sudo bash scripts/install-ubuntu.sh pasarguard
sudo bash scripts/install-ubuntu.sh fixdb
```

مسیر نصب کامل (گزینه ۱) این کارها را انجام می‌دهد:

1. نصب بسته‌های سیستم (Python، کلاینت‌های دیتابیس، git، …)
2. کپی پروژه به `/opt/telegram-db-backup-bot`
3. ساخت venv و نصب وابستگی‌ها
4. پرسیدن تنظیمات (توکن، ادمین، webhook، پنل، دیتابیس)
5. نوشتن `.env` و ثبت دیتابیس اولیه در `data/state.json`
6. فعال‌سازی سرویس systemd به‌نام `backup-bot`

### ۳) بعد از نصب — خلاصه ترمینال

در انتهای نصب چیزی شبیه این می‌بینید:

- مسیر نصب: `/opt/telegram-db-backup-bot`
- آدرس پنل: `http://IP-SERVER:PORT`
- رمز پنل
- وضعیت webhook یا polling
- دستور لاگ: `journalctl -u backup-bot -f`

در صورت نیاز پورت پنل را در فایروال باز کنید:

```bash
sudo ufw allow 8080/tcp
```

(پورت را با همان مقداری که موقع نصب زدید جایگزین کنید.)

---

## سوال‌هایی که اسکریپت تعاملی می‌پرسد

| # | سوال | توضیح |
|---|------|--------|
| ۱ | **BOT_TOKEN** | توکن BotFather — با `getMe` اعتبارسنجی می‌شود |
| ۲ | **ADMIN_IDS** | آیدی عددی ادمین(ها)، چندتایی با کاما — مثال: `123456789` یا `111,222` |
| ۳ | **PUBLIC_BASE_URL** | اگر `https://your-domain.com` بدهید → webhook روی `/telegram/webhook`؛ خالی = **polling** |
| ۴ | رمز پنل وب | خالی = رمز تصادفی تولید و نمایش داده می‌شود (+ `WEB_SECRET` خودکار) |
| ۵ | پورت پنل | پیش‌فرض `8080` |
| ۶ | بازه بکاپ پیوسته | دقیقه ۱–۶۰، پیش‌فرض `15` |
| ۷ | دیتابیس | `[1]` تشخیص خودکار یا `[2]` ورود دستی |

**تشخیص خودکار** از این‌ها می‌خواند:

- پاسارگارد: متغیر `SQLALCHEMY_DATABASE_URL` از `/opt/pasarguard/.env`
- `~/.my.cnf` / `/root/.my.cnf` / `/etc/mysql/debian.cnf`
- WordPress: `wp-config.php` در `/var/www`
- `docker-compose.yml` با متغیرهای MySQL/MariaDB/Postgres

برای پنل پاسارگارد:

```bash
pasarguard edit-env
sudo bash scripts/install-ubuntu.sh          # منو → ۵ واردات پاسارگارد
# یا هنگام نصب، تشخیص خودکار گزینهٔ اول
```

نصب‌کننده اتصال MySQL، MariaDB، PostgreSQL/TimescaleDB یا SQLite پاسارگارد را از URL می‌خواند. برای SQLite نسبی، مسیر `/var/lib/pasarguard` اولویت دارد. رمزهای URL-encoded نیز decode می‌شوند.

**ورود دستی:** موتور (mysql / mariadb / postgresql / sqlite) + هاست، پورت، کاربر، رمز، نام دیتابیس (یا مسیر فایل SQLite).

**Webhook:** نیاز به HTTPS عمومی دارد که به پورت پنل پروکسی شود. اگر `setWebhook` شکست بخورد، می‌توانید با polling ادامه دهید.

---

## تنظیم `.env` دستی

اگر اسکریپت را اجرا نمی‌کنید، از نمونه کپی کنید:

```bash
cp .env.example .env
nano .env   # یا ویرایشگر دلخواه
```

| فیلد | معنی |
|------|------|
| `BOT_TOKEN` | توکن ربات |
| `ADMIN_IDS` | آیدی ادمین‌ها (کاما جدا) |
| `BACKUP_CHAT_ID` | چت دریافت بکاپ (معمولاً همان ادمین اول) |
| `WEB_HOST` | معمولاً `0.0.0.0` |
| `WEB_PORT` | پورت پنل (مثلاً `8080`) |
| `WEB_SECRET` | کلید امنیتی نشست پنل (رشته تصادفی بلند) |
| `PANEL_PASSWORD` | رمز ورود پنل وب |
| `PUBLIC_BASE_URL` | خالی = polling؛ یا `https://دامنه` برای webhook |
| `WEBHOOK_PATH` | پیش‌فرض `/telegram/webhook` |
| `WEBHOOK_SECRET` | توکن مخفی webhook (در نصب تعاملی خودکار) |
| `DATA_DIR` / `BACKUP_DIR` | مسیر داده و بکاپ‌ها |
| `KEEP_LOCAL_BACKUPS` | تعداد بکاپ محلی نگه‌داشته‌شده |
| `TIMEZONE` | مثلاً `Asia/Tehran` |

> فایل `.env` و بکاپ‌ها را commit نکنید.

---

## اجرای systemd و چک وضعیت / لاگ

```bash
# وضعیت
sudo systemctl status backup-bot

# ری‌استارت بعد از تغییر کد یا .env
sudo bash /opt/telegram-db-backup-bot/scripts/restart-service.sh
# یا:
sudo systemctl restart backup-bot

# لاگ زنده
sudo journalctl -u backup-bot -f
```

فعال‌سازی خودکار در بوت (اسکریپت نصب معمولاً انجام می‌دهد):

```bash
sudo systemctl enable backup-bot
```

---

## پنل وب

- آدرس بعد از نصب: `http://IP-SERVER:PORT` (مثلاً `http://203.0.113.10:8080`)
- ورود با **رمز پنل** که موقع نصب تنظیم/نمایش داده شد

قابلیت‌ها:

- داشبورد: آخرین بکاپ، موفقیت/شکست، حجم، شمارش‌معکوس اجرای بعدی
- مدیریت چند دیتابیس (افزودن / تست / بکاپ تکی / حذف)
- بکاپ فوری + دانلود از تاریخچه
- زمان‌بندی: هر N دقیقه / روزانه / هر N ساعت
- نگهداری محلی (keep N)، فعالیت اخیر، تغییر رمز پنل

توسعه محلی بدون systemd:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# ویرایش BOT_TOKEN و ADMIN_IDS
python main.py
```

پنل محلی: `http://127.0.0.1:8080`

---

## استفاده از ربات تلگرام

1. در تلگرام به ربات خود پیام دهید: `/start`
2. پنل دکمه‌ای باز می‌شود:

| دکمه | کار |
|------|-----|
| 🗄 دیتابیس‌ها | لیست / جزئیات / فعال‌سازی / حذف |
| ⚡ بکاپ فوری | بکاپ همه دیتابیس‌های فعال |
| ⏱ زمان‌بندی | روشن/خاموش، هر N دقیقه، روزانه، هر N ساعت |
| 📊 وضعیت | وضعیت کلی |
| ➕ افزودن دیتابیس | ویزارد افزودن MySQL/MariaDB/PostgreSQL/SQLite |
| 🔄 تازه‌سازی | بازگشت به منوی اصلی |

فقط `ADMIN_IDS` می‌توانند ربات را کنترل کنند.

---

## به‌روزرسانی از گیت

ساده‌ترین راه از منوی اسکریپت:

```bash
sudo bash /opt/telegram-db-backup-bot/scripts/install-ubuntu.sh update
# یا: sudo bash scripts/install-ubuntu.sh   → گزینه ۲
```

به‌روزرسانی **کاملاً غیرتعاملی** است: همیشه آخرین نسخه از GitHub در یک پوشهٔ موقت کلون می‌شود، به `/opt/telegram-db-backup-bot` همگام‌سازی می‌شود (**بدون** بازنویسی `.env` و `data/` و `.venv`)، وابستگی‌ها نصب و سرویس `backup-bot` ری‌استارت می‌شود. اگر رکورد دیتابیسی در `data/state.json` متغیر حل‌نشده مثل `${DB_USER}` داشته باشد، به‌صورت خودکار با اطلاعات پاسارگارد ترمیم می‌شود. در صورت وجود کانتینر MariaDB پاسارگارد، `mariadb-upgrade` هم به‌صورت best-effort اجرا می‌شود (رفع خطای mysql.proc).

دستی:

```bash
cd /path/to/telegram-db-backup-bot
git pull origin main
sudo rsync -a --exclude '.venv/' --exclude '__pycache__/' --exclude '.git/' \
  --exclude 'data/' --exclude '.env' \
  ./ /opt/telegram-db-backup-bot/
sudo -u backupbot /opt/telegram-db-backup-bot/.venv/bin/pip install -r /opt/telegram-db-backup-bot/requirements.txt
sudo systemctl restart backup-bot
```

---

## امنیت

- `.env`، `data/state.json` و بکاپ‌ها در git نیستند
- رمزها و توکن را در Issues/PR نگذارید
- پنل را پشت فایروال یا reverse-proxy با HTTPS نگه دارید

---

## English (short)

```bash
git clone https://github.com/b-khaneman/telegram-db-backup-bot.git
cd telegram-db-backup-bot
chmod +x scripts/install-ubuntu.sh
sudo bash scripts/install-ubuntu.sh
```

Interactive installer asks for bot token, admin IDs, optional HTTPS webhook base URL, panel password/port, backup interval, and database (auto-detect or manual). Service: `systemctl status backup-bot`. Full Persian guide above / [docs/INSTALL-FA.md](docs/INSTALL-FA.md).
