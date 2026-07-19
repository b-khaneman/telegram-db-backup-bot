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
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

env_path = Path(os.environ["PASARGUARD_ENV"])
data_dir = Path(os.environ.get("PASARGUARD_DATA_DIR", "/var/lib/pasarguard"))

def parse_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError:
        return out
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        out[key.strip()] = value.strip()
    return out

def parse_compose_environment(path: Path) -> dict[str, str]:
    """Best-effort scrape of `environment:` KEY=VAL / KEY: VAL entries."""
    out: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError:
        return out
    for m in re.finditer(
        r"^\s*-?\s*([A-Z][A-Z0-9_]*)\s*[:=]\s*[\"']?([^\"'\n#]+)[\"']?\s*$",
        text,
        flags=re.M,
    ):
        key, value = m.group(1), m.group(2).strip()
        if key not in out and "${" not in value:
            out[key] = value
    return out

env_vars = parse_env_file(env_path)
raw_url = env_vars.get("SQLALCHEMY_DATABASE_URL", "")

# Aliases used when PasarGuard URL references vars defined elsewhere
# (typically docker-compose.yml of the bundled MySQL/MariaDB/Postgres).
ALIASES = {
    "DB_USER": ["MYSQL_USER", "MARIADB_USER", "POSTGRES_USER"],
    "DB_PASSWORD": [
        "MYSQL_PASSWORD", "MARIADB_PASSWORD", "POSTGRES_PASSWORD",
        "MYSQL_ROOT_PASSWORD", "MARIADB_ROOT_PASSWORD",
    ],
    "DB_NAME": ["MYSQL_DATABASE", "MARIADB_DATABASE", "POSTGRES_DB"],
    "DB_HOST": [],
    "DB_PORT": [],
}

compose_vars: dict[str, str] = {}
for compose in (env_path.parent / "docker-compose.yml", env_path.parent / "docker-compose.yaml"):
    if compose.is_file():
        compose_vars = parse_compose_environment(compose)
        break

def resolve_var(name: str) -> str | None:
    if name in env_vars and "${" not in env_vars[name]:
        return env_vars[name]
    if name in os.environ:
        return os.environ[name]
    if name in compose_vars:
        return compose_vars[name]
    for alias in ALIASES.get(name, []):
        for source in (env_vars, compose_vars):
            if alias in source and "${" not in source[alias]:
                return source[alias]
    return None

def expand_placeholders(url: str) -> str:
    def sub(m: re.Match) -> str:
        name = m.group(1) or m.group(2)
        value = resolve_var(name)
        return value if value is not None else m.group(0)

    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", sub, url)

if raw_url:
    raw_url = expand_placeholders(raw_url)

UNRESOLVED = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*")

def clean_field(value: str, label: str) -> str:
    """Never emit literal ${VAR} credentials; blank them so bash prompts."""
    if UNRESOLVED.search(value):
        print(f"WARN unresolved {label}: {value}", file=sys.stderr)
        return ""
    return value

# MySQL/MariaDB/Postgres inside docker often use compose service hostnames
# that are unreachable from the host; map them to 127.0.0.1.
DOCKER_HOSTS = {"mysql", "mariadb", "postgres", "postgresql", "timescaledb", "db", "database"}

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
        host = clean_field(parsed.hostname or "127.0.0.1", "host") or "127.0.0.1"
        if host.lower() in DOCKER_HOSTS:
            print(f"WARN docker host '{host}' mapped to 127.0.0.1", file=sys.stderr)
            host = "127.0.0.1"
        try:
            port = str(parsed.port or default_port)
        except ValueError:
            port = str(default_port)
        fields = [
            engine,
            host,
            port,
            clean_field(unquote(parsed.username or ""), "user"),
            clean_field(unquote(parsed.password or ""), "password"),
            clean_field(unquote((parsed.path or "").lstrip("/").split("?", 1)[0]), "dbname"),
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

# Prompt for connection fields detectors could not resolve safely
# (e.g. PasarGuard URLs with unexpanded ${DB_USER} placeholders).
fill_missing_db_fields() {
  [[ "$DB_ENGINE" == "sqlite" ]] && return 0
  if [[ -z "$DB_USER" || -z "$DB_PASS" || -z "$DB_NAME" ]]; then
    echo "⚠️ بخشی از اطلاعات اتصال ناقص است (متغیر حل‌نشده در URL پاسارگارد یا مقدار خالی)."
    echo "   مقادیر را تکمیل/تأیید کنید:"
  fi
  DB_HOST="$(prompt 'هاست' "${DB_HOST:-127.0.0.1}")"
  DB_PORT="$(prompt 'پورت' "${DB_PORT:-3306}")"
  while [[ -z "$DB_USER" ]]; do
    DB_USER="$(prompt 'کاربر دیتابیس')"
  done
  if [[ -z "$DB_PASS" ]]; then
    DB_PASS="$(prompt_secret 'رمز دیتابیس (خالی OK)')"
  fi
  while [[ -z "$DB_NAME" ]]; do
    DB_NAME="$(prompt 'نام دیتابیس هدف')"
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

    def same_target(d):
        if d.get("engine") != db["engine"]:
            return False
        if db["engine"] == "sqlite":
            return d.get("file_path") == db["file_path"]
        return (
            d.get("database") == db["database"]
            and d.get("host") == db["host"]
            and int(d.get("port") or 0) == db["port"]
        )

    def broken_placeholder(d):
        return any("${" in str(d.get(k, "")) for k in ("user", "password", "database", "host"))

    # Replace (not duplicate) an entry pointing at the same PasarGuard source,
    # and sweep out broken ${VAR} imports of the same engine family.
    dbs = [d for d in dbs if not (
        same_target(d)
        or d.get("name") == db["name"]
        or broken_placeholder(d)
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
            fill_missing_db_fields
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

  # Fully non-interactive: no prompts anywhere in this path.
  # /opt copy is not a git repo (rsync excludes .git/), so always fetch a
  # fresh shallow clone from GitHub instead of relying on the caller's dir.
  UPDATE_TMP_CLONE="$(mktemp -d /tmp/backup-bot-update.XXXXXX)"
  trap '{ [[ -n "${UPDATE_TMP_CLONE:-}" ]] && rm -rf "${UPDATE_TMP_CLONE}"; } || true' EXIT
  echo "==> دریافت آخرین نسخه از GitHub"
  GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "${REPO_BRANCH}" \
    "${REPO_URL}" "${UPDATE_TMP_CLONE}/repo"

  if [[ ! -d "${APP_DIR}" ]]; then
    echo "==> نصب اولیه در ${APP_DIR}"
  else
    echo "==> همگام‌سازی کد (بدون .env و data/ و .venv)"
  fi
  sync_code_to_app_dir "${UPDATE_TMP_CLONE}/repo"
  rm -rf "${UPDATE_TMP_CLONE}"
  UPDATE_TMP_CLONE=""
  echo "==> وابستگی‌های Python"
  ensure_venv
  echo "==> بررسی/ترمیم state.json (متغیرهای حل‌نشده پاسارگارد)"
  repair_state_placeholders || true
  echo "==> تعمیر MariaDB پاسارگارد (mariadb-upgrade، best-effort)"
  repair_pasarguard_mariadb 0 || true
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

# Repair state.json entries that contain literal ${VAR} placeholders
# (imported before the PasarGuard expansion fix). Non-interactive.
repair_state_placeholders() {
  local state="${APP_DIR}/data/state.json"
  [[ -f "$state" ]] || return 0
  local py="${APP_DIR}/.venv/bin/python"
  [[ -x "$py" ]] || py="python3"
  local fields
  fields="$(parse_pasarguard_env "$PASARGUARD_ENV" 2>/dev/null || true)"
  STATE_FILE="$state" PG_FIELDS="${fields:-}" "$py" - <<'PY'
import json
import os
import time
from pathlib import Path

state_path = Path(os.environ["STATE_FILE"])
raw_fields = os.environ.get("PG_FIELDS", "")
pg = raw_fields.split("|") if raw_fields else []
# pg = [engine, host, port, user, password, dbname, filepath]

state = json.loads(state_path.read_text(encoding="utf-8"))
BROKEN_KEYS = ("user", "password", "database", "host")

def is_broken(entry: dict) -> bool:
    return any("${" in str(entry.get(k, "")) for k in BROKEN_KEYS)

def pg_usable_for(entry: dict) -> bool:
    if len(pg) != 7 or not pg[0] or pg[0] == "sqlite":
        return False
    if not pg[3] or not pg[5]:  # user and dbname must have resolved
        return False
    family = {"mysql", "mariadb"}
    if entry.get("engine") in family and pg[0] in family:
        return True
    return entry.get("engine") == pg[0]

repaired = 0
unrepaired = 0
for entry in state.get("databases", []):
    if not is_broken(entry):
        continue
    if pg_usable_for(entry):
        entry["engine"] = pg[0]
        entry["host"] = pg[1]
        entry["port"] = int(pg[2] or 0)
        entry["user"] = pg[3]
        entry["password"] = pg[4]
        entry["database"] = pg[5]
        repaired += 1
    else:
        unrepaired += 1
        print(f"WARNING: entry '{entry.get('name')}' still has unresolved "
              "${...} placeholders; run the pasarguard menu option to fix it.")

if repaired:
    activity = list(state.get("activity") or [])
    activity.append({"t": time.time(), "msg": f"ترمیم خودکار {repaired} اتصال پاسارگارد"})
    state["activity"] = activity[-50:]
    tmp = state_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(state_path)
    print(f"OK repaired {repaired} database entr{'y' if repaired == 1 else 'ies'}")
elif not unrepaired:
    print("state.json OK — no placeholder entries")
PY
  chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}/data" 2>/dev/null || true
}

# Find a running MariaDB/MySQL docker container. Prefer names containing
# "pasarguard". Prints the container name on stdout; returns 1 if none.
detect_mariadb_container() {
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1 || return 1
  local line name image image_lc name_lc preferred="" fallback=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name="${line%% *}"
    image="${line#* }"
    image_lc="$(printf '%s' "$image" | tr '[:upper:]' '[:lower:]')"
    name_lc="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    if [[ "$image_lc" != *mariadb* && "$image_lc" != *mysql* ]]; then
      continue
    fi
    # Skip phpMyAdmin / admin UIs that happen to mention mysql in the image
    if [[ "$image_lc" == *phpmyadmin* || "$image_lc" == *adminer* ]]; then
      continue
    fi
    if [[ "$name_lc" == *pasarguard* ]]; then
      preferred="$name"
      break
    fi
    [[ -z "$fallback" ]] && fallback="$name"
  done < <(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null || true)
  if [[ -n "$preferred" ]]; then
    echo "$preferred"
    return 0
  fi
  if [[ -n "$fallback" ]]; then
    echo "$fallback"
    return 0
  fi
  return 1
}

# Resolve MYSQL_ROOT_PASSWORD / MARIADB_ROOT_PASSWORD from PasarGuard .env,
# docker-compose.yml, then (optionally) docker inspect of CONTAINER.
# Prints the password on stdout; returns 1 if not found.
discover_mariadb_root_password() {
  local container="${1:-}"
  PASARGUARD_ENV="$PASARGUARD_ENV" CONTAINER="$container" python3 - <<'PY'
import os
import re
import subprocess
import sys
from pathlib import Path

env_path = Path(os.environ.get("PASARGUARD_ENV", "/opt/pasarguard/.env"))
container = os.environ.get("CONTAINER", "").strip()
KEYS = ("MYSQL_ROOT_PASSWORD", "MARIADB_ROOT_PASSWORD")

def parse_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError:
        return out
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        out[key.strip()] = value.strip()
    return out

def parse_compose_environment(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError:
        return out
    for m in re.finditer(
        r"^\s*-?\s*([A-Z][A-Z0-9_]*)\s*[:=]\s*[\"']?([^\"'\n#]+)[\"']?\s*$",
        text,
        flags=re.M,
    ):
        key, value = m.group(1), m.group(2).strip()
        if key not in out:
            out[key] = value
    return out

env_vars = parse_env_file(env_path) if env_path.is_file() else {}
compose_vars: dict[str, str] = {}
for compose in (env_path.parent / "docker-compose.yml", env_path.parent / "docker-compose.yaml"):
    if compose.is_file():
        compose_vars = parse_compose_environment(compose)
        break

UNRESOLVED = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*")

def resolve_var(name: str) -> str | None:
    for source in (env_vars, compose_vars):
        if name in source and not UNRESOLVED.search(source[name]):
            return source[name]
    if name in os.environ and not UNRESOLVED.search(os.environ[name]):
        return os.environ[name]
    return None

def expand(value: str) -> str:
    def sub(m: re.Match) -> str:
        name = m.group(1) or m.group(2)
        resolved = resolve_var(name)
        return resolved if resolved is not None else m.group(0)

    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", sub, value)

def clean(value: str) -> str:
    value = expand(value).strip()
    if not value or UNRESOLVED.search(value):
        return ""
    return value

for key in KEYS:
    for source in (env_vars, compose_vars):
        if key in source:
            pw = clean(source[key])
            if pw:
                print(pw)
                sys.exit(0)

if container:
    try:
        out = subprocess.check_output(
            ["docker", "inspect", "-f",
             "{{range .Config.Env}}{{println .}}{{end}}", container],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        out = ""
    for line in out.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in KEYS:
            pw = clean(value)
            if pw:
                print(pw)
                sys.exit(0)

sys.exit(1)
PY
}

# Run mariadb-upgrade (or mysql_upgrade) against a docker container.
# Uses MYSQL_PWD so passwords with special chars stay safe.
_run_docker_mariadb_upgrade() {
  local container="$1" pass="$2"
  local out rc=0
  # Prefer mariadb-upgrade (MariaDB 10.4+); fall back to legacy mysql_upgrade.
  if out="$(docker exec -e MYSQL_PWD="$pass" "$container" \
      mariadb-upgrade -u root --force 2>&1)"; then
    printf '%s\n' "$out"
    return 0
  fi
  rc=$?
  printf '%s\n' "$out"
  echo "==> mariadb-upgrade ناموفق (exit $rc) — تلاش با mysql_upgrade…"
  if out="$(docker exec -e MYSQL_PWD="$pass" "$container" \
      mysql_upgrade -u root --force 2>&1)"; then
    printf '%s\n' "$out"
    return 0
  fi
  rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

# Run native (host) mariadb-upgrade / mysql_upgrade.
_run_native_mariadb_upgrade() {
  local pass="$1"
  local out rc=0
  if command -v mariadb-upgrade >/dev/null 2>&1; then
    if out="$(MYSQL_PWD="$pass" mariadb-upgrade -u root --force 2>&1)"; then
      printf '%s\n' "$out"
      return 0
    fi
    rc=$?
    printf '%s\n' "$out"
    echo "==> mariadb-upgrade ناموفق (exit $rc) — تلاش با mysql_upgrade…"
  fi
  if command -v mysql_upgrade >/dev/null 2>&1; then
    if out="$(MYSQL_PWD="$pass" mysql_upgrade -u root --force 2>&1)"; then
      printf '%s\n' "$out"
      return 0
    fi
    rc=$?
    printf '%s\n' "$out"
    return "$rc"
  fi
  echo "نه mariadb-upgrade و نه mysql_upgrade روی میزبان پیدا شد."
  return 1
}

# Repair PasarGuard MariaDB mysql.proc mismatch via mariadb-upgrade.
# Args: interactive=1 (default) prompts for missing password; 0 = silent/best-effort.
repair_pasarguard_mariadb() {
  local interactive="${1:-1}"
  local container="" pass="" mode="docker"

  if container="$(detect_mariadb_container)"; then
    echo "کانتینر MariaDB/MySQL: ${container}"
  else
    container=""
    if command -v mariadb-upgrade >/dev/null 2>&1 \
        || command -v mysql_upgrade >/dev/null 2>&1; then
      mode="native"
      echo "کانتینر Docker پیدا نشد — استفاده از mariadb-upgrade محلی."
    else
      if [[ "$interactive" == "1" ]]; then
        echo "نه کانتینر MariaDB/MySQL و نه mariadb-upgrade محلی پیدا شد."
        echo "اگر پاسارگارد با Docker اجرا می‌شود، از root اجرا کنید و docker را بررسی کنید."
        return 1
      fi
      echo "SKIP تعمیر MariaDB: کانتینر/ابزار پیدا نشد."
      return 0
    fi
  fi

  pass="$(discover_mariadb_root_password "${container}" 2>/dev/null || true)"
  if [[ -z "$pass" ]]; then
    if [[ "$interactive" == "1" ]]; then
      pass="$(prompt_secret 'رمز root دیتابیس (MYSQL_ROOT_PASSWORD)')"
    fi
  else
    echo "رمز root از .env / compose / docker inspect خوانده شد."
  fi
  if [[ -z "$pass" ]]; then
    if [[ "$interactive" == "1" ]]; then
      echo "رمز root یافت نشد — لغو."
      return 1
    fi
    echo "WARNING: رمز root MariaDB پیدا نشد؛ mariadb-upgrade رد شد. منو گزینه ۶ یا: fixdb"
    return 0
  fi

  echo "==> اجرای mariadb-upgrade (idempotent)…"
  local ok=0
  if [[ "$mode" == "docker" ]]; then
    if _run_docker_mariadb_upgrade "$container" "$pass"; then
      ok=1
    fi
  else
    if _run_native_mariadb_upgrade "$pass"; then
      ok=1
    fi
  fi

  if [[ "$ok" -eq 1 ]]; then
    echo "OK — جداول سیستم ارتقا یافتند. روتین‌ها/eventها از این پس در بکاپ می‌آیند."
    return 0
  fi
  if [[ "$interactive" == "1" ]]; then
    echo "ERROR: mariadb-upgrade ناموفق بود. خروجی بالا را بررسی کنید."
    return 1
  fi
  echo "WARNING: mariadb-upgrade ناموفق بود (update ادامه می‌یابد). منو گزینه ۶ یا: fixdb"
  return 0
}

do_fix_mariadb() {
  echo ""
  echo "=========================================="
  echo "  تعمیر MariaDB پاسارگارد"
  echo "=========================================="
  echo " هدف: رفع خطای mysql.proc / error 1558 با mariadb-upgrade"
  echo ""
  repair_pasarguard_mariadb 1
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
  if [[ "$DB_ENGINE" != "sqlite" ]]; then
    fill_missing_db_fields
  fi
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
    echo "  [6] تعمیر MariaDB پاسارگارد"
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
      6) do_fix_mariadb || true ;;
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
  fixdb|--fixdb|mariadb-upgrade|--mariadb-upgrade) do_fix_mariadb; exit $? ;;
  menu|--menu|"") main_menu ;;
  *)
    echo "استفاده: sudo bash scripts/install-ubuntu.sh [menu|install|update|restart|status|pasarguard|fixdb]"
    exit 1
    ;;
esac
