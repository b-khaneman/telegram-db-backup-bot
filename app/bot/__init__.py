from __future__ import annotations

from aiogram import Dispatcher
from aiogram.fsm.storage.memory import MemoryStorage

from app.bot.handlers import router
from app.bot.middlewares import AdminOnlyMiddleware


def build_dispatcher() -> Dispatcher:
    dp = Dispatcher(storage=MemoryStorage())
    dp.message.middleware(AdminOnlyMiddleware())
    dp.callback_query.middleware(AdminOnlyMiddleware())
    dp.include_router(router)
    return dp
