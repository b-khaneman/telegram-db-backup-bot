from __future__ import annotations

import asyncio
import html
import logging
import os
import shutil
import tempfile
import time
import zipfile
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from app.config import get_settings
from app.storage import DatabaseConfig, DbEngine, get_storage

logger = logging.getLogger(__name__)

# Telegram hard limit for Bot API files is 50 MB
TELEGRAM_MAX_BYTES = 49 * 1024 * 1024

# Telegram caption hard limit is 1024 characters
CAPTION_MAX_CHARS = 1024

# Telegram message hard limit is 4096 characters; keep a safety margin
MESSAGE_MAX_CHARS = 3900


def h(text: str) -> str:
    """Escape <, > and & for Telegram HTML parse mode."""
    return html.escape(str(text), quote=False)


@dataclass
class ZipEntry:
    name: str
    size: int


@dataclass
class BackupResult:
    ok: bool
    db_id: str
    db_name: str
    path: Path | None = None
    size: int = 0
    error: str | None = None
    duration_sec: float = 0.0
    compressed: bool = True
    contents: list[ZipEntry] = field(default_factory=list)
    # Non-fatal issue (e.g. routines/events skipped); shown alongside success
    warning: str | None = None


def _stamp(tz: str) -> str:
    return datetime.now(ZoneInfo(tz)).strftime("%Y%m%d_%H%M%S")


def _safe_name(name: str) -> str:
    return "".join(c if c.isalnum() or c in "-_" else "_" for c in name)[:64]


async def _run_cmd(
    cmd: list[str],
    *,
    env: dict[str, str] | None = None,
    timeout: int = 3600,
) -> tuple[int, bytes, bytes]:
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=env,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise TimeoutError(f"Command timed out: {' '.join(cmd[:3])}…")
    return proc.returncode or 0, stdout, stderr


async def _zip_file(src: Path, dest: Path, arcname: str | None = None) -> list[ZipEntry]:
    """Store dump inside a .zip archive; return contents with uncompressed sizes."""

    def _do() -> list[ZipEntry]:
        name = arcname or src.name
        with zipfile.ZipFile(dest, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
            zf.write(src, arcname=name)
            info = zf.getinfo(name)
            return [ZipEntry(name=info.filename, size=info.file_size)]

    return await asyncio.to_thread(_do)


def list_zip_contents(path: Path) -> list[ZipEntry]:
    with zipfile.ZipFile(path, "r") as zf:
        return [
            ZipEntry(name=i.filename, size=i.file_size)
            for i in zf.infolist()
            if not i.is_dir()
        ]


def is_mysql_proc_mismatch(stderr: bytes) -> bool:
    """True for the mysql.proc schema-mismatch failure (MariaDB error 1558).

    Happens when mysqldump talks to a MariaDB server whose system tables
    were never migrated with mariadb-upgrade; --routines/--events read
    mysql.proc and fail with e.g.
    "Column count of mysql.proc is wrong. ... error (1558)".
    """
    low = stderr.lower()
    return b"mysql.proc" in low or b"error (1558)" in low or b"(1558)" in low


ROUTINES_SKIPPED_WARNING = (
    "روتین‌ها و eventها در این بکاپ نیامدند (ناسازگاری mysql.proc در سرور). "
    "برای رفع دائمی روی سرور دیتابیس mariadb-upgrade را اجرا کنید."
)


def _mysql_dump_cmd(
    dumper: str, db: DatabaseConfig, out_sql: Path, *, include_routines: bool
) -> list[str]:
    cmd = [
        dumper,
        f"--host={db.host}",
        f"--port={db.port}",
        f"--user={db.user}",
        "--single-transaction",
        "--quick",
    ]
    if include_routines:
        cmd += ["--routines", "--events"]
    cmd += [
        # Triggers are stored per-table (not in mysql.proc) and stay safe
        "--triggers",
        "--hex-blob",
        "--no-tablespaces",
        "--default-character-set=utf8mb4",
        "--result-file",
        str(out_sql),
        # Full restorable dump: include CREATE DATABASE / USE statements
        "--databases",
        db.database,
    ]
    return cmd


async def _attempt_mysql_dump(
    dumper: str,
    db: DatabaseConfig,
    out_sql: Path,
    env: dict[str, str],
    *,
    include_routines: bool = True,
) -> tuple[int, bytes]:
    """Single dump attempt with the built-in --set-gtid-purged retry.

    MySQL 5.6+ writes GTID_PURGED into dumps which breaks restores on
    other servers; mariadb-dump does not know this option, so retry
    without it when the flag is rejected.
    """
    base_cmd = _mysql_dump_cmd(dumper, db, out_sql, include_routines=include_routines)
    cmd = base_cmd[:1] + ["--set-gtid-purged=OFF"] + base_cmd[1:]
    code, _, stderr = await _run_cmd(cmd, env=env)
    if code != 0 and b"set-gtid-purged" in stderr:
        code, _, stderr = await _run_cmd(base_cmd, env=env)
    return code, stderr


async def backup_mysql_family(db: DatabaseConfig, out_sql: Path) -> str | None:
    """MySQL / MariaDB via mysqldump / mariadb-dump.

    Returns a warning string when the dump succeeded but had to skip
    routines/events (mysql.proc mismatch, MariaDB error 1558):
      1. try the preferred dumper with --routines --events;
      2. on a proc-mismatch error retry with the other dumper binary
         (mysqldump <-> mariadb-dump) if it is installed;
      3. as a last resort retry without --routines --events and report
         the skip as a non-fatal warning.
    """
    dumpers = ["mysqldump", "mariadb-dump"]
    if db.engine == DbEngine.MARIADB:
        dumpers = ["mariadb-dump", "mysqldump"]

    dumper = next((d for d in dumpers if shutil.which(d)), None)
    if not dumper:
        raise RuntimeError(
            "mysqldump / mariadb-dump پیدا نشد. ابزار client دیتابیس را نصب کنید."
        )

    env = os.environ.copy()
    if db.password:
        env["MYSQL_PWD"] = db.password

    code, stderr = await _attempt_mysql_dump(dumper, db, out_sql, env)
    if code == 0:
        return None
    if not is_mysql_proc_mismatch(stderr):
        raise RuntimeError(stderr.decode("utf-8", errors="replace")[:800] or f"{dumper} failed")

    # The server is effectively MariaDB with unmigrated system tables
    # (stderr usually says "Created with MariaDB ..."); the other client
    # binary often handles it.
    alt = next((d for d in dumpers if d != dumper and shutil.which(d)), None)
    if alt:
        alt_code, alt_stderr = await _attempt_mysql_dump(alt, db, out_sql, env)
        if alt_code == 0:
            return None
        if not is_mysql_proc_mismatch(alt_stderr):
            logger.warning(
                "%s also failed (non-proc error): %s",
                alt,
                alt_stderr.decode("utf-8", errors="replace")[:200],
            )

    # Last resort: dump without routines/events (they live in mysql.proc);
    # triggers are kept. Surface the skip as a warning, not a failure.
    code, stderr = await _attempt_mysql_dump(dumper, db, out_sql, env, include_routines=False)
    if code != 0:
        raise RuntimeError(stderr.decode("utf-8", errors="replace")[:800] or f"{dumper} failed")
    logger.warning("Backup of %s skipped routines/events (mysql.proc mismatch)", db.name)
    return ROUTINES_SKIPPED_WARNING


async def backup_postgresql(db: DatabaseConfig, out_sql: Path) -> None:
    if not shutil.which("pg_dump"):
        raise RuntimeError("pg_dump پیدا نشد. PostgreSQL client tools را نصب کنید.")

    env = os.environ.copy()
    if db.password:
        env["PGPASSWORD"] = db.password

    cmd = [
        "pg_dump",
        "-h",
        db.host,
        "-p",
        str(db.port),
        "-U",
        db.user,
        "-d",
        db.database,
        "-F",
        "p",
        # Full restorable dump: CREATE DATABASE + reconnect before restoring objects
        "--create",
        "--no-owner",
        "--no-acl",
        "-f",
        str(out_sql),
    ]
    code, _, stderr = await _run_cmd(cmd, env=env)
    if code != 0:
        raise RuntimeError(stderr.decode("utf-8", errors="replace")[:800] or "pg_dump failed")


async def backup_sqlite(db: DatabaseConfig, out_sql: Path) -> None:
    src = Path(db.file_path)
    if not src.exists():
        raise FileNotFoundError(f"فایل SQLite یافت نشد: {src}")

    def _copy() -> None:
        # Prefer sqlite3 .backup if available for consistency under load
        if shutil.which("sqlite3"):
            import subprocess

            subprocess.run(
                ["sqlite3", str(src), f".backup '{out_sql}'"],
                check=True,
                capture_output=True,
            )
        else:
            shutil.copy2(src, out_sql)

    await asyncio.to_thread(_copy)


async def create_backup(db: DatabaseConfig) -> BackupResult:
    settings = get_settings()
    started = time.perf_counter()
    stamp = _stamp(settings.timezone)
    base = f"{_safe_name(db.name)}_{db.engine.value}_{stamp}"
    zip_path = settings.backup_dir / f"{base}.zip"

    try:
        warning: str | None = None
        with tempfile.TemporaryDirectory(prefix="dbbak_") as tmp:
            tmp_path = Path(tmp)
            raw = tmp_path / f"{base}.sql"

            if db.engine in (DbEngine.MYSQL, DbEngine.MARIADB):
                warning = await backup_mysql_family(db, raw)
            elif db.engine == DbEngine.POSTGRESQL:
                await backup_postgresql(db, raw)
            elif db.engine == DbEngine.SQLITE:
                raw = tmp_path / f"{base}.db"
                await backup_sqlite(db, raw)
            else:
                raise ValueError(f"Unsupported engine: {db.engine}")

            if not raw.exists() or raw.stat().st_size == 0:
                raise RuntimeError("خروجی بکاپ خالی است.")

            contents = await _zip_file(raw, zip_path, arcname=raw.name)

        size = zip_path.stat().st_size
        _prune_old(db)
        result = BackupResult(
            ok=True,
            db_id=db.id,
            db_name=db.name,
            path=zip_path,
            size=size,
            duration_sec=round(time.perf_counter() - started, 2),
            compressed=True,
            contents=contents,
            warning=warning,
        )
        get_storage().record_backup_result(
            True, db.name, size=size, path=str(zip_path), duration_sec=result.duration_sec
        )
        return result
    except Exception as exc:  # noqa: BLE001 — surface to caller/UI
        logger.exception("Backup failed for %s", db.name)
        if zip_path.exists():
            try:
                zip_path.unlink(missing_ok=True)
            except OSError:
                pass
        result = BackupResult(
            ok=False,
            db_id=db.id,
            db_name=db.name,
            error=str(exc),
            duration_sec=round(time.perf_counter() - started, 2),
        )
        get_storage().record_backup_result(
            False, db.name, error=str(exc), duration_sec=result.duration_sec
        )
        return result


def _prune_old(db: DatabaseConfig) -> None:
    settings = get_settings()
    storage = get_storage()
    keep = max(1, storage.state.keep_local_backups or settings.keep_local_backups)
    prefix = f"{_safe_name(db.name)}_{db.engine.value}_"
    # Prefer .zip archives; also prune legacy .gz dumps for the same prefix
    files = sorted(
        [
            p
            for p in settings.backup_dir.glob(f"{prefix}*")
            if p.is_file() and p.suffix.lower() in {".zip", ".gz"}
        ],
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    for old in files[keep:]:
        try:
            old.unlink(missing_ok=True)
        except OSError:
            logger.warning("Could not delete old backup %s", old)


def backup_entries(result: BackupResult) -> list[ZipEntry]:
    """All non-directory archive members with uncompressed sizes."""
    entries = list(result.contents)
    if not entries and result.path and result.path.suffix.lower() == ".zip":
        try:
            entries = list_zip_contents(result.path)
        except Exception:  # noqa: BLE001
            entries = []
    return entries


def _caption_header(result: BackupResult) -> str:
    warn = f"⚠️ {h(result.warning)}\n" if result.warning else ""
    return (
        f"🗄 <b>{h(result.db_name)}</b>\n"
        f"📦 آرشیو: {human_size(result.size)} · ⏱ {result.duration_sec}s\n"
        f"<code>{h(result.path.name) if result.path else '—'}</code>\n"
        f"{warn}"
        f"📁 محتویات:"
    )


def _entry_line(entry: ZipEntry) -> str:
    return f"• <code>{h(entry.name)}</code> — {human_size(entry.size)}"


def format_backup_caption_ex(
    result: BackupResult, *, max_chars: int = CAPTION_MAX_CHARS
) -> tuple[str, int]:
    """Telegram/HTML caption + number of entries that did not fit.

    When entries are omitted the complete listing must be delivered via
    zip_listing_messages(); nothing is silently truncated.
    """
    header = _caption_header(result)
    entries = backup_entries(result)

    if not entries:
        return header + "\n• —", 0

    lines: list[str] = []
    omitted = 0
    for entry in entries:
        line = _entry_line(entry)
        candidate = header + "\n" + "\n".join(lines + [line])
        if len(candidate) > max_chars - 60:
            omitted = len(entries) - len(lines)
            break
        lines.append(line)

    body = header + "\n" + "\n".join(lines)
    if omitted > 0:
        more = f"\n… و {omitted} فایل دیگر — فهرست کامل در پیام بعدی"
        if len(body) + len(more) <= max_chars:
            body += more
    return body[:max_chars], omitted


def format_backup_caption(result: BackupResult, *, max_chars: int = CAPTION_MAX_CHARS) -> str:
    return format_backup_caption_ex(result, max_chars=max_chars)[0]


def zip_listing_messages(
    result: BackupResult, *, max_chars: int = MESSAGE_MAX_CHARS
) -> list[str]:
    """Complete archive listing as HTML messages, chunked under Telegram's
    4096-char message limit. Every entry appears exactly once."""
    entries = backup_entries(result)
    if not entries:
        return []

    total = len(entries)
    chunks: list[str] = []
    current: list[str] = []

    def title(part: int) -> str:
        return f"📁 <b>{h(result.db_name)}</b> — فهرست کامل ({total} فایل) — بخش {part}:"

    part = 1
    current_len = len(title(part)) + 1
    for entry in entries:
        line = _entry_line(entry)
        if current and current_len + len(line) + 1 > max_chars:
            chunks.append(title(part) + "\n" + "\n".join(current))
            part += 1
            current = []
            current_len = len(title(part)) + 1
        current.append(line)
        current_len += len(line) + 1
    if current:
        chunks.append(title(part) + "\n" + "\n".join(current))

    if len(chunks) == 1:
        only = f"📁 <b>{h(result.db_name)}</b> — فهرست کامل ({total} فایل):\n" + \
            "\n".join(_entry_line(e) for e in entries)
        if len(only) <= max_chars:
            return [only]
    return chunks


async def backup_all_enabled() -> list[BackupResult]:
    storage = get_storage()
    results: list[BackupResult] = []
    for db in storage.list_databases():
        if not db.enabled:
            continue
        results.append(await create_backup(db))
    return results


def human_size(n: int) -> str:
    units = ["B", "KB", "MB", "GB"]
    size = float(n)
    for u in units:
        if size < 1024 or u == units[-1]:
            return f"{size:.1f} {u}" if u != "B" else f"{int(size)} {u}"
        size /= 1024
    return f"{n} B"


def list_backup_files(limit: int = 40) -> list[dict]:
    settings = get_settings()
    files = sorted(
        [
            p
            for p in settings.backup_dir.glob("*")
            if p.is_file() and p.suffix.lower() in {".zip", ".gz"}
        ],
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )[:limit]
    out = []
    for p in files:
        st = p.stat()
        contents: list[dict] = []
        if p.suffix.lower() == ".zip":
            try:
                contents = [
                    {"name": e.name, "size": e.size, "size_h": human_size(e.size)}
                    for e in list_zip_contents(p)
                ]
            except Exception:  # noqa: BLE001
                contents = []
        out.append(
            {
                "name": p.name,
                "path": str(p),
                "size": st.st_size,
                "size_h": human_size(st.st_size),
                "mtime": st.st_mtime,
                "contents": contents,
            }
        )
    return out


async def test_connection(db: DatabaseConfig) -> tuple[bool, str]:
    """Quick connectivity check without full dump."""
    try:
        if db.engine == DbEngine.SQLITE:
            p = Path(db.file_path)
            if not p.exists():
                return False, f"فایل یافت نشد: {p}"
            if p.stat().st_size < 0:
                return False, "فایل نامعتبر"
            return True, "فایل SQLite در دسترس است"

        if db.engine in (DbEngine.MYSQL, DbEngine.MARIADB):
            client = "mysql" if shutil.which("mysql") else ("mariadb" if shutil.which("mariadb") else None)
            if not client:
                return False, "کلاینت mysql/mariadb نصب نیست"
            env = os.environ.copy()
            if db.password:
                env["MYSQL_PWD"] = db.password
            cmd = [
                client,
                f"-h{db.host}",
                f"-P{db.port}",
                f"-u{db.user}",
                "-e",
                "SELECT 1",
                db.database,
            ]
            code, _, err = await _run_cmd(cmd, env=env, timeout=20)
            if code != 0:
                return False, err.decode("utf-8", errors="replace")[:300] or "اتصال ناموفق"
            return True, "اتصال MySQL/MariaDB موفق"

        if db.engine == DbEngine.POSTGRESQL:
            if not shutil.which("psql"):
                return False, "psql نصب نیست"
            env = os.environ.copy()
            if db.password:
                env["PGPASSWORD"] = db.password
            cmd = [
                "psql",
                "-h", db.host,
                "-p", str(db.port),
                "-U", db.user,
                "-d", db.database,
                "-c", "SELECT 1",
            ]
            code, _, err = await _run_cmd(cmd, env=env, timeout=20)
            if code != 0:
                return False, err.decode("utf-8", errors="replace")[:300] or "اتصال ناموفق"
            return True, "اتصال PostgreSQL موفق"

        return False, "موتور ناشناخته"
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)
