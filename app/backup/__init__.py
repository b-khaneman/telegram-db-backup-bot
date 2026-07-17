from __future__ import annotations

import asyncio
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


async def backup_mysql_family(db: DatabaseConfig, out_sql: Path) -> None:
    """MySQL / MariaDB via mysqldump / mariadb-dump."""
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

    cmd = [
        dumper,
        f"--host={db.host}",
        f"--port={db.port}",
        f"--user={db.user}",
        "--single-transaction",
        "--quick",
        "--routines",
        "--triggers",
        "--events",
        "--hex-blob",
        "--default-character-set=utf8mb4",
        "--result-file",
        str(out_sql),
        db.database,
    ]
    code, _, stderr = await _run_cmd(cmd, env=env)
    if code != 0:
        raise RuntimeError(stderr.decode("utf-8", errors="replace")[:800] or f"{dumper} failed")


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
        with tempfile.TemporaryDirectory(prefix="dbbak_") as tmp:
            tmp_path = Path(tmp)
            raw = tmp_path / f"{base}.sql"

            if db.engine in (DbEngine.MYSQL, DbEngine.MARIADB):
                await backup_mysql_family(db, raw)
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


def format_backup_caption(result: BackupResult, *, max_chars: int = CAPTION_MAX_CHARS) -> str:
    """Build Telegram/HTML caption with DB name, archive size, and zip file list."""
    header = (
        f"🗄 <b>{result.db_name}</b>\n"
        f"📦 آرشیو: {human_size(result.size)} · ⏱ {result.duration_sec}s\n"
        f"<code>{result.path.name if result.path else '—'}</code>\n"
        f"📁 محتویات:"
    )
    entries = list(result.contents)
    if not entries and result.path and result.path.suffix.lower() == ".zip":
        try:
            entries = list_zip_contents(result.path)
        except Exception:  # noqa: BLE001
            entries = []

    if not entries:
        return header + "\n• —"

    lines: list[str] = []
    omitted = 0
    for entry in entries:
        line = f"• <code>{entry.name}</code> — {human_size(entry.size)}"
        candidate = header + "\n" + "\n".join(lines + [line])
        if len(candidate) > max_chars - 40:
            omitted = len(entries) - len(lines)
            break
        lines.append(line)

    body = header + "\n" + "\n".join(lines)
    if omitted > 0:
        more = f"\n… و {omitted} فایل دیگر"
        if len(body) + len(more) <= max_chars:
            body += more
    return body[:max_chars]


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
