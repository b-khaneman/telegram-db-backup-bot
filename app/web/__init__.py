from __future__ import annotations

import hashlib
import hmac
import logging
import re
import time
from datetime import datetime
from pathlib import Path
from typing import Optional
from zoneinfo import ZoneInfo

from fastapi import FastAPI, Form, Request
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware

from app.backup import (
    backup_all_enabled,
    create_backup,
    human_size,
    list_backup_files,
    test_connection,
)
from app.config import get_settings
from app.scheduler import get_scheduler
from app.storage import get_storage

logger = logging.getLogger(__name__)

BASE = Path(__file__).resolve().parent
templates = Jinja2Templates(directory=str(BASE / "templates"))

_bot_send = None


def set_backup_notifier(fn) -> None:  # type: ignore[no-untyped-def]
    global _bot_send
    _bot_send = fn


def _fmt_ts(ts: float | None, tz: str) -> str:
    if not ts:
        return "—"
    return datetime.fromtimestamp(ts, ZoneInfo(tz)).strftime("%Y-%m-%d %H:%M:%S")


def _next_run_info() -> tuple[str, str]:
    """Return (human next run, countdown)."""
    try:
        job = get_scheduler().scheduler.get_job("auto_backup")
        if not job or not job.next_run_time:
            return "—", "—"
        nxt = job.next_run_time
        settings = get_settings()
        local = nxt.astimezone(ZoneInfo(settings.timezone))
        delta = int((nxt.timestamp() - time.time()))
        if delta < 0:
            return local.strftime("%Y-%m-%d %H:%M"), "به‌زودی"
        m, s = divmod(delta, 60)
        h, m = divmod(m, 60)
        if h:
            cd = f"{h}س {m}د"
        elif m:
            cd = f"{m}د {s}ث"
        else:
            cd = f"{s}ث"
        return local.strftime("%Y-%m-%d %H:%M:%S"), cd
    except Exception:  # noqa: BLE001
        return "—", "—"


def _update_env_password(new_password: str) -> None:
    settings = get_settings()
    env_path = Path(".env")
    if not env_path.exists():
        # try absolute data-relative: project root via DATA_DIR parent
        env_path = settings.data_dir.parent / ".env"
    if not env_path.exists():
        raise FileNotFoundError(".env یافت نشد")
    text = env_path.read_text(encoding="utf-8")
    if re.search(r"^PANEL_PASSWORD=.*$", text, flags=re.M):
        text = re.sub(r"^PANEL_PASSWORD=.*$", f"PANEL_PASSWORD={new_password}", text, flags=re.M)
    else:
        text += f"\nPANEL_PASSWORD={new_password}\n"
    env_path.write_text(text, encoding="utf-8")
    get_settings.cache_clear()


def create_web_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="Backup Glass", docs_url=None, redoc_url=None)
    app.add_middleware(
        SessionMiddleware,
        secret_key=settings.web_secret,
        same_site="lax",
        https_only=False,
    )
    app.mount("/static", StaticFiles(directory=str(BASE / "static")), name="static")

    def _authed(request: Request) -> bool:
        return bool(request.session.get("auth"))

    def _check_password(password: str) -> bool:
        s = get_settings()
        expected = s.panel_password.encode()
        got = password.encode()
        return hmac.compare_digest(
            hashlib.sha256(expected).digest(),
            hashlib.sha256(got).digest(),
        )

    def _require(request: Request) -> RedirectResponse | None:
        if not _authed(request):
            return RedirectResponse("/login", status_code=303)
        return None

    @app.get("/login", response_class=HTMLResponse)
    async def login_page(request: Request):
        if _authed(request):
            return RedirectResponse("/", status_code=303)
        return templates.TemplateResponse("login.html", {"request": request, "error": None})

    @app.post("/login")
    async def login_post(request: Request, password: str = Form(...)):
        if _check_password(password):
            request.session["auth"] = True
            return RedirectResponse("/", status_code=303)
        return templates.TemplateResponse(
            "login.html",
            {"request": request, "error": "رمز نادرست است"},
            status_code=401,
        )

    @app.post("/logout")
    async def logout(request: Request):
        request.session.clear()
        return RedirectResponse("/login", status_code=303)

    @app.get("/", response_class=HTMLResponse)
    async def dashboard(request: Request):
        if redir := _require(request):
            return redir
        s = get_settings()
        storage = get_storage()
        dbs = storage.list_databases()
        next_at, countdown = _next_run_info()
        lb = storage.state.last_backup
        history = list_backup_files(30)
        activity = list(reversed(storage.state.activity[-20:]))
        for a in activity:
            a["t_h"] = _fmt_ts(a.get("t"), s.timezone)
        for h in history:
            h["mtime_h"] = _fmt_ts(h["mtime"], s.timezone)
        mode = "webhook" if s.use_webhook() else "polling"
        return templates.TemplateResponse(
            "dashboard.html",
            {
                "request": request,
                "dbs": dbs,
                "enabled_count": sum(1 for d in dbs if d.enabled),
                "schedule": storage.state.schedule,
                "flash": request.session.pop("flash", None),
                "keep_local": storage.state.keep_local_backups,
                "last_backup": lb,
                "last_backup_at": _fmt_ts(lb.at, s.timezone),
                "last_backup_size": human_size(lb.size) if lb.size else "—",
                "next_run": next_at,
                "countdown": countdown,
                "history": history,
                "activity": activity,
                "bot_mode": mode,
                "webhook_url": s.resolved_webhook_url() or "—",
                "timezone": s.timezone,
            },
        )

    @app.post("/schedule")
    async def save_schedule(
        request: Request,
        mode: str = Form("minutes"),
        hour: int = Form(3),
        minute: int = Form(0),
        interval_hours: int = Form(24),
        interval_minutes: int = Form(15),
        enabled: Optional[str] = Form(None),
    ):
        if redir := _require(request):
            return redir
        get_storage().set_schedule(
            enabled=bool(enabled),
            mode=mode,
            hour=max(0, min(23, hour)),
            minute=max(0, min(59, minute)),
            interval_hours=max(1, min(168, interval_hours)),
            interval_minutes=max(1, min(60, interval_minutes)),
        )
        get_scheduler().reload()
        request.session["flash"] = "زمان‌بندی ذخیره شد"
        return RedirectResponse("/", status_code=303)

    @app.post("/settings/retention")
    async def save_retention(request: Request, keep_local: int = Form(5)):
        if redir := _require(request):
            return redir
        get_storage().set_keep_local(keep_local)
        request.session["flash"] = f"نگهداری محلی: {keep_local} فایل"
        return RedirectResponse("/", status_code=303)

    @app.post("/settings/password")
    async def change_password(
        request: Request,
        current: str = Form(...),
        new_password: str = Form(...),
        confirm: str = Form(...),
    ):
        if redir := _require(request):
            return redir
        if not _check_password(current):
            request.session["flash"] = "رمز فعلی نادرست است"
            return RedirectResponse("/", status_code=303)
        if len(new_password) < 6:
            request.session["flash"] = "رمز جدید حداقل ۶ کاراکتر"
            return RedirectResponse("/", status_code=303)
        if new_password != confirm:
            request.session["flash"] = "تأیید رمز مطابقت ندارد"
            return RedirectResponse("/", status_code=303)
        try:
            _update_env_password(new_password)
            request.session["flash"] = "رمز پنل تغییر کرد (از ورود بعدی اعمال می‌شود)"
        except Exception as exc:  # noqa: BLE001
            request.session["flash"] = f"خطا: {exc}"
        return RedirectResponse("/", status_code=303)

    @app.post("/db/add")
    async def add_db(
        request: Request,
        name: str = Form(...),
        engine: str = Form(...),
        host: str = Form("127.0.0.1"),
        port: int = Form(3306),
        user: str = Form("root"),
        password: str = Form(""),
        database: str = Form(""),
        file_path: str = Form(""),
    ):
        if redir := _require(request):
            return redir
        get_storage().add_database(
            name=name.strip(),
            engine=engine,
            host=host.strip(),
            port=port,
            user=user.strip(),
            password=password,
            database=database.strip(),
            file_path=file_path.strip(),
        )
        request.session["flash"] = f"دیتابیس «{name}» اضافه شد"
        return RedirectResponse("/", status_code=303)

    @app.post("/db/{db_id}/toggle")
    async def toggle_db(request: Request, db_id: str):
        if redir := _require(request):
            return redir
        db = get_storage().get_database(db_id)
        if db:
            get_storage().update_database(db_id, enabled=not db.enabled)
        return RedirectResponse("/", status_code=303)

    @app.post("/db/{db_id}/delete")
    async def delete_db(request: Request, db_id: str):
        if redir := _require(request):
            return redir
        get_storage().delete_database(db_id)
        request.session["flash"] = "حذف شد"
        return RedirectResponse("/", status_code=303)

    @app.post("/db/{db_id}/test")
    async def test_db(request: Request, db_id: str):
        if redir := _require(request):
            return redir
        db = get_storage().get_database(db_id)
        if not db:
            request.session["flash"] = "دیتابیس یافت نشد"
            return RedirectResponse("/", status_code=303)
        ok, msg = await test_connection(db)
        get_storage().log_activity(f"تست اتصال {db.name}: {msg}")
        request.session["flash"] = ("✅ " if ok else "❌ ") + msg
        return RedirectResponse("/", status_code=303)

    @app.post("/backup/now")
    async def backup_now(request: Request):
        if redir := _require(request):
            return redir
        results = await backup_all_enabled()
        if _bot_send:
            try:
                await _bot_send(results)
            except Exception:  # noqa: BLE001
                logger.exception("Notify failed")
        ok = sum(1 for r in results if r.ok)
        request.session["flash"] = f"بکاپ انجام شد: {ok}/{len(results)} موفق"
        return RedirectResponse("/", status_code=303)

    @app.post("/backup/{db_id}")
    async def backup_one(request: Request, db_id: str):
        if redir := _require(request):
            return redir
        db = get_storage().get_database(db_id)
        if not db:
            request.session["flash"] = "دیتابیس یافت نشد"
            return RedirectResponse("/", status_code=303)
        result = await create_backup(db)
        if _bot_send:
            try:
                await _bot_send([result])
            except Exception:  # noqa: BLE001
                logger.exception("Notify failed")
        if result.ok and result.path:
            request.session["flash"] = (
                f"بکاپ {db.name} موفق — {human_size(result.size)} — {result.path}"
            )
        else:
            request.session["flash"] = f"خطا: {result.error}"
        return RedirectResponse("/", status_code=303)

    @app.get("/download/{filename}")
    async def download_backup(request: Request, filename: str):
        if redir := _require(request):
            return redir
        safe = Path(filename).name
        path = get_settings().backup_dir / safe
        if not path.exists() or not path.is_file():
            return RedirectResponse("/", status_code=303)
        return FileResponse(path, filename=safe, media_type="application/gzip")

    return app
