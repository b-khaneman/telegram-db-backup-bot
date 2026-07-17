from __future__ import annotations

import logging
from typing import Awaitable, Callable, Optional

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.interval import IntervalTrigger
from zoneinfo import ZoneInfo

from app.config import get_settings
from app.storage import get_storage

logger = logging.getLogger(__name__)

JobCallback = Callable[[], Awaitable[None]]


class BackupScheduler:
    def __init__(self) -> None:
        settings = get_settings()
        self.scheduler = AsyncIOScheduler(timezone=ZoneInfo(settings.timezone))
        self._job_id = "auto_backup"
        self._callback: Optional[JobCallback] = None

    def set_callback(self, callback: JobCallback) -> None:
        self._callback = callback

    def start(self) -> None:
        if not self.scheduler.running:
            self.scheduler.start()
        self.reload()

    def shutdown(self) -> None:
        if self.scheduler.running:
            self.scheduler.shutdown(wait=False)

    def reload(self) -> None:
        storage = get_storage()
        schedule = storage.state.schedule
        settings = get_settings()

        if self.scheduler.get_job(self._job_id):
            self.scheduler.remove_job(self._job_id)

        if not schedule.enabled or self._callback is None:
            schedule.next_hint = "غیرفعال"
            storage.save()
            return

        async def _wrapped() -> None:
            assert self._callback is not None
            await self._callback()
            import time

            storage.state.schedule.last_run_at = time.time()
            storage.save()

        tz = ZoneInfo(settings.timezone)
        if schedule.mode in ("minutes", "interval_minutes"):
            mins = max(1, min(60, int(schedule.interval_minutes or 15)))
            trigger = IntervalTrigger(minutes=mins, timezone=tz)
            hint = f"هر {mins} دقیقه"
            misfire = max(60, mins * 60)
        elif schedule.mode == "interval":
            hours = max(1, int(schedule.interval_hours))
            trigger = IntervalTrigger(hours=hours, timezone=tz)
            hint = f"هر {hours} ساعت"
            misfire = 3600
        else:
            trigger = CronTrigger(
                hour=schedule.hour,
                minute=schedule.minute,
                timezone=tz,
            )
            hint = f"روزانه {schedule.hour:02d}:{schedule.minute:02d}"
            misfire = 3600

        self.scheduler.add_job(
            _wrapped,
            trigger=trigger,
            id=self._job_id,
            replace_existing=True,
            max_instances=1,
            coalesce=True,
            misfire_grace_time=misfire,
        )
        schedule.next_hint = hint
        storage.save()
        logger.info("Scheduler reloaded: %s", hint)


_scheduler: BackupScheduler | None = None


def get_scheduler() -> BackupScheduler:
    global _scheduler
    if _scheduler is None:
        _scheduler = BackupScheduler()
    return _scheduler
