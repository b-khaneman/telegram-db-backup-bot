#!/usr/bin/env bash
# Interactive menu + installer — Ubuntu 22.04 / 24.04
# Usage: sudo bash scripts/install-ubuntu.sh
set -euo pipefail

APP_USER="${APP_USER:-backupbot}"
APP_GROUP="${APP_GROUP:-$APP_USER}"
SERVICE_NAME="${SERVICE_NAME:-backup-bot}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${APP_DIR:-/opt/telegram-db-backup-bot}"
REPO_URL="${REPO_URL:-https://github.com/b-khaneman/telegram-db-backup-bot.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
PASARGUARD_ENV="${PASARGUARD_ENV:-/opt/pasarguard/.env}"
PASARGUARD_DATA_DIR="${PASARGUARD_DATA_DIR:-/var/lib/pasarguard}"

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

require_app_dir() {
  if [[ ! -d "${APP_DIR}" ]]; then
    echo "نصب یافت نشد در ${APP_DIR}. ابتدا گزینه نصب را اجرا کنید."
    return 1
  fi
}

ensure_system_packages() {
  export DEBIAN_FRONTEND=noninteractive
  echo "==> نصب/بررسی بسته‌های سیستم"
  apt-get update -y
  apt-get install -y --no-install-recommends \
    python3 python3-venv python3-pip ca-certificates curl openssl rsync git \
    sqlite3 default-mysql-client postgresql-client gzip tzdata jq
  apt-get install -y --no-install-recommends mariadb-client 2>/dev/null || true
}

ensure_app_user() {
  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    useradd --system --home "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
  fi
}

sync_code_to_app_dir() {
  local src="$1"
  mkdir -p "${APP_DIR}"
  rsync -a \
    --exclude '.venv/' --exclude '__pycache__/' --exclude '.git/' \
    --exclude 'data/' --exclude '.env' --exclude '*.pyc' \
    "${src}/" "${APP_DIR}/"
  mkdir -p "${APP_DIR}/data/backups"
  chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"
}

ensure_venv() {
  if [[ ! -d "${APP_DIR}/.venv" ]]; then
    sudo -u "${APP_USER}" python3 -m venv "${APP_DIR}/.venv"
  fi
  sudo -u "${APP_USER}" "${APP_DIR}/.venv/bin/pip" install --upgrade pip
  sudo -u "${APP_USER}" "${APP_DIR}/.venv/bin/pip" install -r "${APP_DIR}/requirements.txt"
}

install_systemd_unit() {
  local unit_dst="/etc/systemd/system/${SERVICE_NAME}.service"
  sed \
    -e "s|__APP_DIR__|${APP_DIR}|g" \
    -e "s|__APP_USER__|${APP_USER}|g" \
    -e "s|__APP_GROUP__|${APP_GROUP}|g" \
    "${APP_DIR}/deploy/backup-bot.service" > "${unit_dst}"
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service"
}

restart_service() {
  systemctl restart "${SERVICE_NAME}.service"
  sleep 1
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
}

# Parse PasarGuard SQLALCHEMY_DATABASE_URL -> engine|host|port|user|pass|dbname|filepath
parse_pasarguard_env() {
  local env_file="${1:-$PASARGUARD_ENV}"
  [[ -r "$env_file" ]] || return 1
  PASARGUARD_ENV="$env_file" PASARGUARD_DATA_DIR="$PASARGUARD_DATA_DIR" python3 - <<'PY'
import os
from pathlib import Path
from urllib.parse import unquote, urlsplit

env_path = Path(os.environ["PASARGUARD_ENV"])
data_dir = Path(os.environ.get("PASARGUARD_DATA_DIR", "/var/lib/pasarguard"))
raw_url = ""
for raw_line in env_path.read_text(encoding="utf-8-sig").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key.strip() != "SQLALCHEMY_DATABASE_URL":
        continue
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        value = value[1:-1]
    raw_url = value.strip()
    break

if not raw_url:
    pass
else:
    parsed = urlsplit(raw_url)
    scheme = parsed.scheme.lower().split("+", 1)[0]
    if scheme in {"postgres", "postgresql", "timescaledb"}:
        engine, default_port = "postgresql", 5432
    elif scheme in {"mysql", "mariadb"}:
        engine, default_port = scheme, 3306
    elif scheme == "sqlite":
        engine, default_port = "sqlite", 0
    else:
        raise SystemExit(f"unsupported scheme: {scheme}")

    if engine == "sqlite":
        db_path = unquote(parsed.path or "")
        # sqlite:///rel  -> three slashes (relative)
        # sqlite:////abs -> four slashes (absolute unix)
        scheme_prefix = raw_url.split(":", 1)[0]
        is_relative = (
            raw_url.startswith(f"{scheme_prefix}:///")
            and not raw_url.startswith(f"{scheme_prefix}:////")
        )
        if is_relative:
            name = Path(db_path.lstrip("/")).name or "db.sqlite3"
            candidates = [
                data_dir / name,
                env_path.parent / name,
                Path(db_path.lstrip("/")),
            ]
            chosen = next((c for c in candidates if c.is_file()), None)
            db_path = str((chosen or (data_dir / name)).resolve())
        elif not Path(db_path).is_absolute():
            db_path = str((env_path.parent / db_path).resolve())
        fields = [engine, "", "0", "", "", Path(db_path).name, db_path]
    else:
        fields = [
            engine,
            parsed.hostname or "127.0.0.1",
            str(parsed.port or default_port),
            unquote(parsed.username or ""),
            unquote(parsed.password or ""),
            unquote((parsed.path or "").lstrip("/").split("?", 1)[0]),
            "",
        ]

    if all("|" not in item and "\n" not in item for item in fields):
        print("|".join(fields))
PY
}

detect_candidates() {
  local n=0
  DETECTED_LINES=()
  local pg_fields
  if pg_fields="$(parse_pasarguard_env "$PASARGUARD_ENV" 2>/dev/null || true)"; then
    if [[ -n "${pg_fields:-}" ]]; then
      local pg_eng pg_host pg_port pg_user pg_pass pg_name pg_file
      IFS='|' read -r pg_eng pg_host pg_port pg_user pg_pass pg_name pg_file <<< "$pg_fields"
      n=$((n+1))
      DETECTED_LINES+=("${n}|${pg_eng}|${pg_host}|${pg_port}|${pg_user}|${pg_pass}|pasarguard:${PASARGUARD_ENV}|${pg_name}|${pg_file}")
    fi
  fi
  for f in /root/.my.cnf "${HOME}/.my.cnf" /etc/mysql/debian.cnf; do
    [[ -f "$f" ]] || continue
    local u p h
    u="$(awk -F= '/^user/ {gsub(/ /,"",$2); print $2; exit}' "$f" 2>/dev/null || true)"
    p="$(awk -F= '/^password/ {gsub(/ /,"",$2); print $2; exit}' "$f" 2>/dev/null || true)"
    h="$(awk -F= '/^host/ {gsub(/ /,"",$2); print $2; exit}' "$f" 2>/dev/null || true)"
    [[ -z "$u" ]] && continue
    n=$((n+1))
    DETECTED_LINES+=("${n}|mysql|${h:-127.0.0.1}|3306|${u}|${p}|cnf:${f}||")
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
    DETECTED_LINES+=("${n}|mysql|${ph:-127.0.0.1}|${pp}|${user}|${pass}|wp:${wp}|${name}|")
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
    DETECTED_LINES+=("${n}|${eng}|127.0.0.1|${port}|${user:-root}|${pass}|docker:${dc}|${name}|")
  done
}

print_detected() {
  local line num eng host port user pass src dbn dbfile
  for line in "${DETECTED_LINES[@]}"; do
    IFS='|' read -r num eng host port user pass src dbn dbfile <<< "$line"
    if [[ "$eng" == "sqlite" ]]; then
      echo "  [$num] sqlite  src=$src  file=${dbfile:-$dbn}"
    else
      echo "  [$num] $eng ${user}@${host}:${port}  src=$src  db=${dbn:-?}"
    fi
  done
}

write_db_into_state() {
  # Uses env: DB_ENGINE DB_HOST DB_PORT DB_USER DB_PASS DB_NAME DB_FILE DB_DISPLAY
  # MERGE=1 appends; otherwise replaces databases list but keeps schedule if present
  local merge="${1:-0}"
  local b64_pass b64_file b64_disp b64_dbn
  b64_pass="$(printf '%s' "$DB_PASS" | base64 -w0 2>/dev/null || printf '%s' "$DB_PASS" | base64)"
  b64_file="$(printf '%s' "$DB_FILE" | base64 -w0 2>/dev/null || printf '%s' "$DB_FILE" | base64)"
  b64_disp="$(printf '%s' "$DB_DISPLAY" | base64 -w0 2>/dev/null || printf '%s' "$DB_DISPLAY" | base64)"
  b64_dbn="$(printf '%s' "$DB_NAME" | base64 -w0 2>/dev/null || printf '%s' "$DB_NAME" | base64)"

  sudo -u "${APP_USER}" APP_DIR="${APP_DIR}" DB_ENGINE="${DB_ENGINE}" DB_HOST="${DB_HOST}" \
    DB_PORT="${DB_PORT}" DB_USER="${DB_USER}" B64_PASS="${b64_pass}" B64_FILE="${b64_file}" \
    B64_DISP="${b64_disp}" B64_DBN="${b64_dbn}" INTERVAL_MIN="${INTERVAL_MIN:-15}" \
    FIRST_ADMIN="${FIRST_ADMIN:-0}" MERGE="$merge" \
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
mins = int(os.environ.get("INTERVAL_MIN") or 15)
merge = os.environ.get("MERGE") == "1"
if merge and p.exists():
    state = json.loads(p.read_text(encoding="utf-8"))
    dbs = list(state.get("databases") or [])
    # replace existing PasarGuard-named entry if same target
    dbs = [d for d in dbs if not (
        d.get("name") == db["name"]
        and d.get("engine") == db["engine"]
        and d.get("database") == db["database"]
        and d.get("file_path") == db["file_path"]
    )]
    dbs.append(db)
    state["databases"] = dbs
    activity = list(state.get("activity") or [])
    activity.append({"t": time.time(), "msg": f"واردات پاسارگارد: {db['name']}"})
    state["activity"] = activity[-50:]
else:
    first_admin = int(os.environ.get("FIRST_ADMIN") or 0) or None
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
        "notify_chat_id": first_admin,
        "keep_local_backups": 5,
        "last_backup": {},
        "activity": [{"t": time.time(), "msg": "نصب تعاملی انجام شد"}],
    }
p.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
print("state.json OK")
PY
  chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}/data"
}

do_install() {
  echo ""
  echo "=========================================="
  echo "  Backup Glass — نصب / نصب مجدد"
  echo "=========================================="
  echo ""

  ensure_system_packages
  ensure_app_user
  echo "==> کپی پروژه به ${APP_DIR}"
  sync_code_to_app_dir "${SOURCE_DIR}"
  echo "==> venv + pip"
  ensure_venv

  echo ""
  echo "-- تنظیمات ربات --"
  local BOT_TOKEN="" ADMIN_IDS="" FIRST_ADMIN="" PUBLIC_BASE_URL="" WEBHOOK_PATH WEBHOOK_SECRET
  local USE_WEBHOOK=0 WEBHOOK_STATUS="polling" PANEL_PASSWORD WEB_SECRET WEB_PORT INTERVAL_MIN
  local DB_MODE DB_ENGINE DB_HOST DB_PORT DB_USER DB_PASS DB_NAME DB_FILE DB_DISPLAY
  local DETECTED_LINES=() CHOICE SEL ECHOICE ME_JSON BOT_USERNAME WH_URL WH_RESP CONT IP

  BOT_TOKEN=""
  while [[ -z "$BOT_TOKEN" ]]; do
    BOT_TOKEN="$(prompt_secret '1) BOT_TOKEN از BotFather')"
    [[ -z "$BOT_TOKEN" ]] && echo "توکن خالی است."
  done

  echo "==> اعتبارسنجی توکن (getMe)..."
  ME_JSON="$(curl -fsS "https://api.telegram.org/bot${BOT_TOKEN}/getMe" || true)"
  if ! echo "$ME_JSON" | grep -q '"ok":true'; then
    echo "ERROR: توکن نامعتبر. ${ME_JSON:-network error}"
    return 1
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
  echo "   [1] تشخیص خودکار (شامل پاسارگارد)"
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

  if [[ "$DB_MODE" == "1" ]]; then
    detect_candidates
    if [[ ${#DETECTED_LINES[@]} -eq 0 ]]; then
      echo "چیزی پیدا نشد — دستی"
      DB_MODE="2"
    else
      echo "موارد یافت‌شده:"
      print_detected
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
          IFS='|' read -r _ DB_ENGINE DB_HOST DB_PORT DB_USER DB_PASS _SRC DB_NAME DB_FILE <<< "$SEL"
          if [[ "$DB_ENGINE" != "sqlite" ]]; then
            DB_NAME="$(prompt 'نام دیتابیس هدف' "${DB_NAME}")"
          fi
          DB_DISPLAY="$(prompt 'نام نمایشی' "${DB_NAME:-pasarguard}")"
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
  write_db_into_state 0

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
        return 1
      fi
    fi
  fi

  echo "==> systemd"
  install_systemd_unit
  restart_service

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
}

do_update() {
  echo ""
  echo "=========================================="
  echo "  به‌روزرسانی از GitHub"
  echo "=========================================="
  echo " ریپو: ${REPO_URL} (${REPO_BRANCH})"
  echo " هدف:  ${APP_DIR}"
  echo " حفظ:  .env و data/"
  echo ""

  ensure_system_packages
  ensure_app_user

  local work_dir="${SOURCE_DIR}"
  if [[ -d "${SOURCE_DIR}/.git" ]]; then
    echo "==> git pull در ${SOURCE_DIR}"
    git -C "${SOURCE_DIR}" fetch origin "${REPO_BRANCH}"
    git -C "${SOURCE_DIR}" pull --ff-only origin "${REPO_BRANCH}"
  else
    work_dir="/tmp/telegram-db-backup-bot-update"
    echo "==> کلون موقت به ${work_dir}"
    rm -rf "${work_dir}"
    git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${work_dir}"
  fi

  if [[ ! -d "${APP_DIR}" ]]; then
    echo "==> نصب اولیه در ${APP_DIR}"
  else
    echo "==> همگام‌سازی کد (بدون .env و data/)"
  fi
  sync_code_to_app_dir "${work_dir}"
  echo "==> وابستگی‌های Python"
  ensure_venv
  if [[ -f "${APP_DIR}/deploy/backup-bot.service" ]]; then
    install_systemd_unit
  fi
  if systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    echo "==> ری‌استارت سرویس"
    restart_service
  else
    echo "سرویس هنوز ثبت نشده — از منو گزینه نصب را بزنید."
  fi
  echo "OK به‌روزرسانی انجام شد."
}

do_restart() {
  require_app_dir || return 1
  echo "==> ری‌استارت ${SERVICE_NAME}"
  systemctl daemon-reload
  restart_service
}

do_status_logs() {
  echo ""
  echo "-- وضعیت سرویس --"
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
  echo ""
  echo "-- ۲۰ خط آخر لاگ (Ctrl+C برای خروج از follow) --"
  local mode
  mode="$(prompt '۱=وضعیت فقط  ۲=لاگ زنده (-f)' '1')"
  if [[ "$mode" == "2" ]]; then
    journalctl -u "${SERVICE_NAME}" -f
  else
    journalctl -u "${SERVICE_NAME}" -n 40 --no-pager || true
  fi
}

do_import_pasarguard() {
  echo ""
  echo "=========================================="
  echo "  واردات دیتابیس پاسارگارد"
  echo "=========================================="
  echo " فایل: ${PASARGUARD_ENV}"
  echo " (پس از تغییر: pasarguard edit-env)"
  echo ""

  require_app_dir || return 1
  if [[ ! -x "${APP_DIR}/.venv/bin/python" ]]; then
    echo "venv پیدا نشد — ابتدا نصب یا به‌روزرسانی را اجرا کنید."
    return 1
  fi

  local fields
  if ! fields="$(parse_pasarguard_env "$PASARGUARD_ENV")"; then
    echo "فایل پاسارگارد خوانده نشد: ${PASARGUARD_ENV}"
    return 1
  fi
  if [[ -z "${fields:-}" ]]; then
    echo "SQLALCHEMY_DATABASE_URL فعال در ${PASARGUARD_ENV} پیدا نشد."
    echo "با دستور زیر تنظیم کنید: pasarguard edit-env"
    return 1
  fi

  local DB_ENGINE DB_HOST DB_PORT DB_USER DB_PASS DB_NAME DB_FILE DB_DISPLAY
  IFS='|' read -r DB_ENGINE DB_HOST DB_PORT DB_USER DB_PASS DB_NAME DB_FILE <<< "$fields"
  DB_DISPLAY="$(prompt 'نام نمایشی' "${DB_NAME:-pasarguard}")"
  if [[ "$DB_ENGINE" == "sqlite" ]]; then
    echo "موتور: sqlite"
    echo "فایل:  ${DB_FILE}"
  else
    echo "موتور: ${DB_ENGINE}"
    echo "هدف:   ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
  fi
  local ok
  ok="$(prompt 'ثبت در state.json؟ (y/n)' 'y')"
  if [[ ! "$ok" =~ ^[Yy]$ ]]; then
    echo "لغو شد."
    return 0
  fi
  FIRST_ADMIN=0 INTERVAL_MIN=15 write_db_into_state 1
  echo "OK — دیتابیس پاسارگارد اضافه/به‌روز شد."
  local rs
  rs="$(prompt 'ری‌استارت سرویس؟ (y/n)' 'y')"
  if [[ "$rs" =~ ^[Yy]$ ]]; then
    restart_service
  fi
}

main_menu() {
  while true; do
    echo ""
    echo "=========================================="
    echo "  Backup Glass — منوی مدیریت"
    echo "=========================================="
    echo " مسیر نصب: ${APP_DIR}"
    echo " سرویس:    ${SERVICE_NAME}"
    echo " ریپو:     ${REPO_URL}"
    echo ""
    echo "  [1] نصب / نصب مجدد"
    echo "  [2] به‌روزرسانی از GitHub"
    echo "  [3] ری‌استارت سرویس"
    echo "  [4] وضعیت / لاگ"
    echo "  [5] واردات دیتابیس پاسارگارد"
    echo "  [0] خروج"
    echo ""
    local choice
    choice="$(prompt 'انتخاب' '0')"
    case "$choice" in
      1) do_install || true ;;
      2) do_update || true ;;
      3) do_restart || true ;;
      4) do_status_logs || true ;;
      5) do_import_pasarguard || true ;;
      0) echo "خداحافظ."; exit 0 ;;
      *) echo "گزینه نامعتبر." ;;
    esac
  done
}

# Direct subcommands for scripting / automation
case "${1:-}" in
  install|--install) do_install; exit $? ;;
  update|--update) do_update; exit $? ;;
  restart|--restart) do_restart; exit $? ;;
  status|--status) do_status_logs; exit $? ;;
  pasarguard|--pasarguard) do_import_pasarguard; exit $? ;;
  menu|--menu|"") main_menu ;;
  *)
    echo "استفاده: sudo bash scripts/install-ubuntu.sh [menu|install|update|restart|status|pasarguard]"
    exit 1
    ;;
esac
