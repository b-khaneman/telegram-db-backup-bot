from __future__ import annotations

import json
import secrets
import time
from dataclasses import asdict, dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any
from uuid import uuid4

from app.config import get_settings


class DbEngine(str, Enum):
    MYSQL = "mysql"
    MARIADB = "mariadb"
    POSTGRESQL = "postgresql"
    SQLITE = "sqlite"


@dataclass
class DatabaseConfig:
    id: str
    name: str
    engine: DbEngine
    host: str = "127.0.0.1"
    port: int = 3306
    user: str = "root"
    password: str = ""
    database: str = ""
    file_path: str = ""
    enabled: bool = True
    created_at: float = field(default_factory=time.time)

    def display_target(self) -> str:
        if self.engine == DbEngine.SQLITE:
            return self.file_path or "—"
        return f"{self.host}:{self.port}/{self.database}"


@dataclass
class ScheduleConfig:
    enabled: bool = False
    hour: int = 3
    minute: int = 0
    mode: str = "daily"  # daily | interval | minutes
    interval_hours: int = 24
    interval_minutes: int = 15
    last_run_at: float | None = None
    next_hint: str = ""


@dataclass
class LastBackupInfo:
    ok: bool | None = None
    at: float | None = None
    size: int = 0
    db_name: str = ""
    error: str | None = None
    path: str = ""
    duration_sec: float = 0.0


@dataclass
class AppState:
    databases: list[DatabaseConfig] = field(default_factory=list)
    schedule: ScheduleConfig = field(default_factory=ScheduleConfig)
    notify_chat_id: int | None = None
    keep_local_backups: int = 5
    last_backup: LastBackupInfo = field(default_factory=LastBackupInfo)
    activity: list[dict[str, Any]] = field(default_factory=list)


class Storage:
    def __init__(self, path: Path | None = None) -> None:
        settings = get_settings()
        self.path = path or (settings.data_dir / "state.json")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._state = self._load()

    def _load(self) -> AppState:
        if not self.path.exists():
            settings = get_settings()
            return AppState(keep_local_backups=settings.keep_local_backups)
        raw = json.loads(self.path.read_text(encoding="utf-8"))
        dbs = [
            DatabaseConfig(
                id=d["id"],
                name=d["name"],
                engine=DbEngine(d["engine"]),
                host=d.get("host", "127.0.0.1"),
                port=int(d.get("port", 3306)),
                user=d.get("user", "root"),
                password=d.get("password", ""),
                database=d.get("database", ""),
                file_path=d.get("file_path", ""),
                enabled=bool(d.get("enabled", True)),
                created_at=float(d.get("created_at", time.time())),
            )
            for d in raw.get("databases", [])
        ]
        s = raw.get("schedule", {})
        schedule = ScheduleConfig(
            enabled=bool(s.get("enabled", False)),
            hour=int(s.get("hour", 3)),
            minute=int(s.get("minute", 0)),
            mode=s.get("mode", "daily"),
            interval_hours=int(s.get("interval_hours", 24)),
            interval_minutes=int(s.get("interval_minutes", 15)),
            last_run_at=s.get("last_run_at"),
            next_hint=s.get("next_hint", ""),
        )
        lb = raw.get("last_backup", {}) or {}
        last_backup = LastBackupInfo(
            ok=lb.get("ok"),
            at=lb.get("at"),
            size=int(lb.get("size", 0) or 0),
            db_name=lb.get("db_name", "") or "",
            error=lb.get("error"),
            path=lb.get("path", "") or "",
            duration_sec=float(lb.get("duration_sec", 0) or 0),
        )
        settings = get_settings()
        return AppState(
            databases=dbs,
            schedule=schedule,
            notify_chat_id=raw.get("notify_chat_id"),
            keep_local_backups=int(raw.get("keep_local_backups", settings.keep_local_backups)),
            last_backup=last_backup,
            activity=list(raw.get("activity", []) or [])[-50:],
        )

    def save(self) -> None:
        payload: dict[str, Any] = {
            "databases": [
                {**asdict(d), "engine": d.engine.value} for d in self._state.databases
            ],
            "schedule": asdict(self._state.schedule),
            "notify_chat_id": self._state.notify_chat_id,
            "keep_local_backups": self._state.keep_local_backups,
            "last_backup": asdict(self._state.last_backup),
            "activity": self._state.activity[-50:],
        }
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(self.path)

    @property
    def state(self) -> AppState:
        return self._state

    def list_databases(self) -> list[DatabaseConfig]:
        return list(self._state.databases)

    def get_database(self, db_id: str) -> DatabaseConfig | None:
        for db in self._state.databases:
            if db.id == db_id:
                return db
        return None

    def add_database(self, **kwargs: Any) -> DatabaseConfig:
        engine = kwargs.get("engine")
        if isinstance(engine, str):
            engine = DbEngine(engine)
        defaults_port = {
            DbEngine.MYSQL: 3306,
            DbEngine.MARIADB: 3306,
            DbEngine.POSTGRESQL: 5432,
            DbEngine.SQLITE: 0,
        }
        db = DatabaseConfig(
            id=kwargs.get("id") or uuid4().hex[:12],
            name=kwargs["name"],
            engine=engine,
            host=kwargs.get("host", "127.0.0.1"),
            port=int(kwargs.get("port", defaults_port.get(engine, 3306))),
            user=kwargs.get("user", "root"),
            password=kwargs.get("password", ""),
            database=kwargs.get("database", ""),
            file_path=kwargs.get("file_path", ""),
            enabled=bool(kwargs.get("enabled", True)),
        )
        self._state.databases.append(db)
        self.save()
        self.log_activity(f"دیتابیس «{db.name}» اضافه شد")
        return db

    def update_database(self, db_id: str, **kwargs: Any) -> DatabaseConfig | None:
        db = self.get_database(db_id)
        if not db:
            return None
        for key, value in kwargs.items():
            if key == "engine" and isinstance(value, str):
                value = DbEngine(value)
            if hasattr(db, key) and value is not None:
                setattr(db, key, value)
        self.save()
        return db

    def delete_database(self, db_id: str) -> bool:
        before = len(self._state.databases)
        self._state.databases = [d for d in self._state.databases if d.id != db_id]
        if len(self._state.databases) != before:
            self.save()
            self.log_activity("یک دیتابیس حذف شد")
            return True
        return False

    def set_schedule(self, **kwargs: Any) -> ScheduleConfig:
        for key, value in kwargs.items():
            if hasattr(self._state.schedule, key) and value is not None:
                setattr(self._state.schedule, key, value)
        self.save()
        return self._state.schedule

    def set_notify_chat(self, chat_id: int | None) -> None:
        self._state.notify_chat_id = chat_id
        self.save()

    def set_keep_local(self, n: int) -> None:
        self._state.keep_local_backups = max(1, min(100, int(n)))
        self.save()

    def record_backup_result(self, ok: bool, db_name: str, size: int = 0,
                             error: str | None = None, path: str = "",
                             duration_sec: float = 0.0) -> None:
        self._state.last_backup = LastBackupInfo(
            ok=ok,
            at=time.time(),
            size=size,
            db_name=db_name,
            error=error,
            path=path,
            duration_sec=duration_sec,
        )
        msg = f"بکاپ {db_name}: {'موفق' if ok else 'ناموفق'}"
        if error:
            msg += f" — {error[:120]}"
        self.log_activity(msg)
        self.save()

    def log_activity(self, message: str) -> None:
        self._state.activity.append({"t": time.time(), "msg": message})
        self._state.activity = self._state.activity[-50:]
        self.save()


_storage: Storage | None = None


def get_storage() -> Storage:
    global _storage
    if _storage is None:
        _storage = Storage()
    return _storage


def new_csrf() -> str:
    return secrets.token_urlsafe(24)
