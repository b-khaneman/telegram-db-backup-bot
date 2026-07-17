#!/usr/bin/env bash
# Interactive + idempotent installer — Ubuntu 22.04 / 24.04
# Usage: sudo bash scripts/install-ubuntu.sh
set -euo pipefail

APP_USER="${APP_USER:-backupbot}"
APP_GROUP="${APP_GROUP:-$APP_USER}"
SERVICE_NAME="${SERVICE_NAME:-backup-bot}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${APP_DIR:-/opt/telegram-db-backup-bot}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "با sudo اجرا کنید: sudo bash scripts/install-ubuntu.sh"
  exit 1
fi

prompt() {
  local msg="$1" def="${2:-}" val
  if [[ -n "$def" ]]; then
    read -r -p "$msg [$def]: " val || true
    echo "${val:-$def}"
  else
    read -r -p "$msg: " val || true
    echo "$val"
  fi
}

prompt_secret() {
  local msg="$1" val
  read -r -s -p "$msg: " val || true
  echo "" >&2
  echo "$val"
}

echo "=========================================="
echo "  Backup Glass — نصب تعاملی اوبونتو"
echo "=========================================="
echo ""

export DEBIAN_FRONTEND=noninteractive
echo "==> نصب بسته‌های سیستم"
apt-get update -y
apt-get install -y --no-install-recommends \
  python3 python3-venv python3-pip ca-certificates curl openssl rsync \
  sqlite3 default-mysql-client postgresql-client gzip tzdata jq
apt-get install -y --no-install-recommends mariadb-client 2>/dev/null || true

if ! id -u "${APP_USER}" >/dev/null 2>&1; then
  useradd --system --home "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
fi

echo "==> کپی پروژه به ${APP_DIR}"
mkdir -p "${APP_DIR}"
rsync -a \
  --exclude '.venv/' --exclude '__pycache__/' --exclude '.git/' \
  --exclude 'data/' --exclude '.env' --exclude '*.pyc' \
  "${SOURCE_DIR}/" "${APP_DIR}/"
mkdir -p "${APP_DIR}/data/backups"
chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"

echo "==> venv + pip"
if [[ ! -d "${APP_DIR}/.venv" ]]; then
  sudo -u "${APP_USER}" python3 -m venv "${APP_DIR}/.venv"
fi
sudo -u "${APP_USER}" "${APP_DIR}/.venv/bin/pip" install --upgrade pip
sudo -u "${APP_USER}" "${APP_DIR}/.venv/bin/pip" install -r "${APP_DIR}/requirements.txt"

echo ""
echo "-- تنظیمات ربات --"
BOT_TOKEN=""
while [[ -z "$BOT_TOKEN" ]]; do
  BOT_TOKEN="$(prompt_secret '1) BOT_TOKEN از BotFather')"
  [[ -z "$BOT_TOKEN" ]] && echo "توکن خالی است."
done

echo "==> اعتبارسنجی توکن (getMe)..."
ME_JSON="$(curl -fsS "https://api.telegram.org/bot${BOT_TOKEN}/getMe" || true)"
if ! echo "$ME_JSON" | grep -q '"ok":true'; then
  echo "ERROR: توکن نامعتبر. ${ME_JSON:-network error}"
  exit 1
fi
BOT_USERNAME="$(echo "$ME_JSON" | jq -r '.result.username // empty' 2>/dev/null || true)"
echo "OK ربات: @${BOT_USERNAME:-unknown}"

ADMIN_IDS=""
while [[ -z "$ADMIN_IDS" ]]; do
  ADMIN_IDS="$(prompt '2) ADMIN_IDS (عددی، چندتایی با کاما)')"
  if ! echo "$ADMIN_IDS" | grep -Eq '^[0-9]+(,[0-9]+)*$'; then
    echo "فقط عدد و کاما. مثال: 123456789"
    ADMIN_IDS=""
  fi
done
FIRST_ADMIN="$(echo "$ADMIN_IDS" | cut -d, -f1)"

echo ""
echo "3) حالت آپدیت تلگرام — webhook نیاز به HTTPS عمومی دارد"
PUBLIC_BASE_URL="$(prompt '   PUBLIC_BASE_URL (خالی = polling)' '')"
PUBLIC_BASE_URL="$(echo "$PUBLIC_BASE_URL" | sed 's|/*$||')"
WEBHOOK_PATH="/telegram/webhook"
WEBHOOK_SECRET=""
USE_WEBHOOK=0
WEBHOOK_STATUS="polling"
if [[ -n "$PUBLIC_BASE_URL" ]]; then
  if [[ ! "$PUBLIC_BASE_URL" =~ ^https:// ]]; then
    echo "WARNING: باید https:// باشد — polling"
    PUBLIC_BASE_URL=""
  else
    USE_WEBHOOK=1
    WEBHOOK_SECRET="$(openssl rand -hex 16)"
  fi
fi

PANEL_PASSWORD="$(prompt '4) رمز پنل وب (خالی = تصادفی)' '')"
if [[ -z "$PANEL_PASSWORD" ]]; then
  PANEL_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)"
  echo "   رمز تولید شد: ${PANEL_PASSWORD}"
fi
WEB_SECRET="$(openssl rand -hex 32)"
WEB_PORT="$(prompt '5) پورت پنل وب' '8080')"

INTERVAL_MIN="$(prompt '6) بازه بکاپ پیوسته (دقیقه 1-60)' '15')"
if ! [[ "$INTERVAL_MIN" =~ ^[0-9]+$ ]] || (( INTERVAL_MIN < 1 || INTERVAL_MIN > 60 )); then
  INTERVAL_MIN=15
fi

echo ""
echo "7) اتصال دیتابیس"
echo "   [1] تشخیص خودکار"
echo "   [2] ورود دستی"
DB_MODE="$(prompt 'انتخاب' '1')"

DB_ENGINE="mysql"
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_USER="root"
DB_PASS=""
DB_NAME=""
DB_FILE=""
DB_DISPLAY=""
DETECTED_LINES=()

detect_candidates() {
  local n=0
  DETECTED_LINES=()
  for f in /root/.my.cnf "${HOME}/.my.cnf" /etc/mysql/debian.cnf; do
    [[ -f "$f" ]] || continue
    local u p h
    u="$(awk -F= '/^user/ {gsub(/ /,"",$2); print $2; exit}' "$f" 2>/dev/null || true)"
    p="$(awk -F= '/^password/ {gsub(/ /,"",$2); print $2; exit}' "$f" 2>/dev/null || true)"
    h="$(awk -F= '/^host/ {gsub(/ /,"",$2); print $2; exit}' "$f" 2>/dev/null || true)"
    [[ -z "$u" ]] && continue
    n=$((n+1))
    DETECTED_LINES+=("${n}|mysql|${h:-127.0.0.1}|3306|${u}|${p}|cnf:${f}|")
  done
  while IFS= read -r -d '' wp; do
    local name user pass host ph pp
    name="$(grep -E "DB_NAME" "$wp" | head -1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/" || true)"
    user="$(grep -E "DB_USER" "$wp" | head -1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/" || true)"
    pass="$(grep -E "DB_PASSWORD" "$wp" | head -1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/" || true)"
    host="$(grep -E "DB_HOST" "$wp" | head -1 | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/" || true)"
    [[ -z "$name" || -z "$user" ]] && continue
    ph="${host%%:*}"; pp="3306"
    [[ "$host" == *:* ]] && pp="${host##*:}"
    n=$((n+1))
    DETECTED_LINES+=("${n}|mysql|${ph:-127.0.0.1}|${pp}|${user}|${pass}|wp:${wp}|${name}")
  done < <(find /var/www -name wp-config.php -type f -print0 2>/dev/null | head -z -n 20 || true)
  for dc in /opt/*/docker-compose.yml /var/www/*/docker-compose.yml; do
    [[ -f "$dc" ]] || continue
    grep -qiE 'MYSQL_DATABASE|MARIADB_DATABASE|POSTGRES_DB' "$dc" || continue
    local eng="mysql" name user pass port=3306
    name="$(grep -E 'MYSQL_DATABASE|MARIADB_DATABASE|POSTGRES_DB' "$dc" | head -1 | sed -E 's/.*[:=][[:space:]"]*([^"[:space:]]+).*/\1/' || true)"
    user="$(grep -E 'MYSQL_USER|MARIADB_USER|POSTGRES_USER' "$dc" | head -1 | sed -E 's/.*[:=][[:space:]"]*([^"[:space:]]+).*/\1/' || true)"
    pass="$(grep -E 'MYSQL_PASSWORD|MARIADB_PASSWORD|POSTGRES_PASSWORD' "$dc" | head -1 | sed -E 's/.*[:=][[:space:]"]*([^"[:space:]]+).*/\1/' || true)"
    grep -qi POSTGRES "$dc" && eng="postgresql" && port=5432
    [[ -z "$name" ]] && continue
    n=$((n+1))
    DETECTED_LINES+=("${n}|${eng}|127.0.0.1|${port}|${user:-root}|${pass}|docker:${dc}|${name}")
  done
}

if [[ "$DB_MODE" == "1" ]]; then
  detect_candidates
  if [[ ${#DETECTED_LINES[@]} -eq 0 ]]; then
    echo "چیزی پیدا نشد — دستی"
    DB_MODE="2"
  else
    echo "موارد یافت‌شده:"
    for line in "${DETECTED_LINES[@]}"; do
      IFS='|' read -r num eng host port user pass src dbn <<< "$line"
      echo "  [$num] $eng $user@${host}:${port} src=$src db=${dbn:-?}"
    done
    CHOICE="$(prompt 'شماره (0=دستی)' '1')"
    if [[ "$CHOICE" == "0" ]]; then
      DB_MODE="2"
    else
      SEL=""
      for line in "${DETECTED_LINES[@]}"; do
        [[ "$line" == "${CHOICE}|"* ]] && SEL="$line" && break
      done
      if [[ -z "$SEL" ]]; then
        DB_MODE="2"
      else
        IFS='|' read -r _ DB_ENGINE DB_HOST DB_PORT DB_USER DB_PASS _SRC DB_NAME <<< "$SEL"
        DB_NAME="$(prompt 'نام دیتابیس هدف' "${DB_NAME}")"
        DB_DISPLAY="$(prompt 'نام نمایشی' "${DB_NAME}")"
      fi
    fi
  fi
fi

if [[ "$DB_MODE" != "1" ]]; then
  echo "موتور: [1]mysql [2]mariadb [3]postgresql [4]sqlite"
  ECHOICE="$(prompt 'انتخاب' '1')"
  case "$ECHOICE" in
    2) DB_ENGINE="mariadb" ;;
    3) DB_ENGINE="postgresql"; DB_PORT="5432" ;;
    4) DB_ENGINE="sqlite" ;;
    *) DB_ENGINE="mysql" ;;
  esac
  DB_DISPLAY="$(prompt 'نام نمایشی' 'main-db')"
  if [[ "$DB_ENGINE" == "sqlite" ]]; then
    DB_FILE="$(prompt 'مسیر فایل SQLite')"
    DB_NAME="$(basename "$DB_FILE")"
  else
    DB_HOST="$(prompt 'هاست' '127.0.0.1')"
    DB_PORT="$(prompt 'پورت' "$DB_PORT")"
    DB_USER="$(prompt 'کاربر' 'root')"
    DB_PASS="$(prompt_secret 'رمز دیتابیس (خالی OK)')"
    DB_NAME=""
    while [[ -z "$DB_NAME" ]]; do
      DB_NAME="$(prompt 'نام دیتابیس هدف')"
    done
  fi
fi

echo "==> نوشتن .env"
cat > "${APP_DIR}/.env" <<EOF
BOT_TOKEN=${BOT_TOKEN}
ADMIN_IDS=${ADMIN_IDS}
BACKUP_CHAT_ID=${FIRST_ADMIN}

WEB_HOST=0.0.0.0
WEB_PORT=${WEB_PORT}
WEB_SECRET=${WEB_SECRET}
PANEL_PASSWORD=${PANEL_PASSWORD}

PUBLIC_BASE_URL=${PUBLIC_BASE_URL}
WEBHOOK_URL=
WEBHOOK_PATH=${WEBHOOK_PATH}
WEBHOOK_SECRET=${WEBHOOK_SECRET}

DATA_DIR=${APP_DIR}/data
BACKUP_DIR=${APP_DIR}/data/backups
KEEP_LOCAL_BACKUPS=5
TIMEZONE=Asia/Tehran
EOF
chown "${APP_USER}:${APP_GROUP}" "${APP_DIR}/.env"
chmod 600 "${APP_DIR}/.env"

echo "==> ثبت دیتابیس + زمان‌بندی دقیقه‌ای"
# Escape for Python triple-quoted strings via base64 to avoid injection issues
B64_PASS="$(printf '%s' "$DB_PASS" | base64 -w0 2>/dev/null || printf '%s' "$DB_PASS" | base64)"
B64_FILE="$(printf '%s' "$DB_FILE" | base64 -w0 2>/dev/null || printf '%s' "$DB_FILE" | base64)"
B64_DISP="$(printf '%s' "$DB_DISPLAY" | base64 -w0 2>/dev/null || printf '%s' "$DB_DISPLAY" | base64)"
B64_DBN="$(printf '%s' "$DB_NAME" | base64 -w0 2>/dev/null || printf '%s' "$DB_NAME" | base64)"

sudo -u "${APP_USER}" APP_DIR="${APP_DIR}" DB_ENGINE="${DB_ENGINE}" DB_HOST="${DB_HOST}" \
  DB_PORT="${DB_PORT}" DB_USER="${DB_USER}" B64_PASS="${B64_PASS}" B64_FILE="${B64_FILE}" \
  B64_DISP="${B64_DISP}" B64_DBN="${B64_DBN}" INTERVAL_MIN="${INTERVAL_MIN}" FIRST_ADMIN="${FIRST_ADMIN}" \
  "${APP_DIR}/.venv/bin/python" <<'PY'
import base64, json, os, time, uuid
from pathlib import Path

def b64(k):
    return base64.b64decode(os.environ[k]).decode("utf-8")

p = Path(os.environ["APP_DIR"]) / "data" / "state.json"
p.parent.mkdir(parents=True, exist_ok=True)
db = {
    "id": uuid.uuid4().hex[:12],
    "name": b64("B64_DISP"),
    "engine": os.environ["DB_ENGINE"],
    "host": os.environ["DB_HOST"],
    "port": int(os.environ["DB_PORT"] or 0),
    "user": os.environ["DB_USER"],
    "password": b64("B64_PASS"),
    "database": b64("B64_DBN"),
    "file_path": b64("B64_FILE"),
    "enabled": True,
    "created_at": time.time(),
}
mins = int(os.environ["INTERVAL_MIN"])
state = {
    "databases": [db],
    "schedule": {
        "enabled": True,
        "hour": 3,
        "minute": 0,
        "mode": "minutes",
        "interval_hours": 24,
        "interval_minutes": mins,
        "last_run_at": None,
        "next_hint": f"هر {mins} دقیقه",
    },
    "notify_chat_id": int(os.environ["FIRST_ADMIN"]),
    "keep_local_backups": 5,
    "last_backup": {},
    "activity": [{"t": time.time(), "msg": "نصب تعاملی انجام شد"}],
}
p.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
print("state.json OK")
PY
chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}/data"

if [[ "$USE_WEBHOOK" -eq 1 ]]; then
  WH_URL="${PUBLIC_BASE_URL}${WEBHOOK_PATH}"
  echo "==> setWebhook -> ${WH_URL}"
  WH_RESP="$(curl -fsS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
    --data-urlencode "url=${WH_URL}" \
    --data-urlencode "secret_token=${WEBHOOK_SECRET}" \
    -d "drop_pending_updates=true" || true)"
  if echo "$WH_RESP" | grep -q '"ok":true'; then
    WEBHOOK_STATUS="OK ${WH_URL}"
    echo "OK Webhook"
  else
    echo "ERROR setWebhook: ${WH_RESP}"
    CONT="$(prompt 'ادامه با polling؟ (y/n)' 'y')"
    if [[ "$CONT" =~ ^[Yy]$ ]]; then
      sed -i 's|^PUBLIC_BASE_URL=.*|PUBLIC_BASE_URL=|' "${APP_DIR}/.env"
      sed -i 's|^WEBHOOK_SECRET=.*|WEBHOOK_SECRET=|' "${APP_DIR}/.env"
      curl -fsS "https://api.telegram.org/bot${BOT_TOKEN}/deleteWebhook" >/dev/null || true
      WEBHOOK_STATUS="fallback polling"
      USE_WEBHOOK=0
    else
      exit 1
    fi
  fi
fi

echo "==> systemd"
UNIT_DST="/etc/systemd/system/${SERVICE_NAME}.service"
sed \
  -e "s|__APP_DIR__|${APP_DIR}|g" \
  -e "s|__APP_USER__|${APP_USER}|g" \
  -e "s|__APP_GROUP__|${APP_GROUP}|g" \
  "${APP_DIR}/deploy/backup-bot.service" > "${UNIT_DST}"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"
sleep 1
systemctl --no-pager --full status "${SERVICE_NAME}.service" || true

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo ""
echo "========== خلاصه نصب =========="
echo " مسیر:     ${APP_DIR}"
echo " سرویس:    ${SERVICE_NAME}"
echo " ربات:     @${BOT_USERNAME}"
echo " Webhook:  ${WEBHOOK_STATUS}"
echo " دیتابیس:  ${DB_DISPLAY} / ${DB_NAME} (${DB_ENGINE})"
echo " بازه:     هر ${INTERVAL_MIN} دقیقه"
echo " پنل:      http://${IP:-SERVER}:${WEB_PORT}"
echo " رمز پنل:  ${PANEL_PASSWORD}"
echo " لاگ:      journalctl -u ${SERVICE_NAME} -f"
echo " فایروال:  ufw allow ${WEB_PORT}/tcp"
echo "================================"
