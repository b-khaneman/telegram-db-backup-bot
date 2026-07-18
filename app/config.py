from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Annotated, List

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    bot_token: str = Field(..., alias="BOT_TOKEN")
    # NoDecode: keep raw CSV string so pydantic-settings doesn't try JSON-parsing "111,222"
    admin_ids: Annotated[List[int], NoDecode] = Field(default_factory=list, alias="ADMIN_IDS")
    backup_chat_id: int | None = Field(default=None, alias="BACKUP_CHAT_ID")

    web_host: str = Field(default="0.0.0.0", alias="WEB_HOST")
    web_port: int = Field(default=8080, alias="WEB_PORT")
    web_secret: str = Field(default="change-me", alias="WEB_SECRET")
    panel_password: str = Field(default="admin123", alias="PANEL_PASSWORD")

    # Webhook (if PUBLIC_BASE_URL or WEBHOOK_URL set → webhook mode)
    public_base_url: str = Field(default="", alias="PUBLIC_BASE_URL")
    webhook_url: str = Field(default="", alias="WEBHOOK_URL")
    webhook_path: str = Field(default="/telegram/webhook", alias="WEBHOOK_PATH")
    webhook_secret: str = Field(default="", alias="WEBHOOK_SECRET")

    data_dir: Path = Field(default=Path("./data"), alias="DATA_DIR")
    backup_dir: Path = Field(default=Path("./data/backups"), alias="BACKUP_DIR")
    keep_local_backups: int = Field(default=5, alias="KEEP_LOCAL_BACKUPS")
    timezone: str = Field(default="Asia/Tehran", alias="TIMEZONE")

    @field_validator("admin_ids", mode="before")
    @classmethod
    def parse_admin_ids(cls, value: object) -> List[int]:
        if value is None or value == "":
            return []
        if isinstance(value, list):
            return [int(x) for x in value]
        return [int(x.strip()) for x in str(value).split(",") if x.strip()]

    @field_validator("backup_chat_id", mode="before")
    @classmethod
    def parse_chat_id(cls, value: object) -> int | None:
        if value is None or value == "":
            return None
        return int(value)

    def ensure_dirs(self) -> None:
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.backup_dir.mkdir(parents=True, exist_ok=True)

    def resolved_webhook_url(self) -> str | None:
        if self.webhook_url.strip():
            return self.webhook_url.strip()
        base = self.public_base_url.strip().rstrip("/")
        if not base:
            return None
        path = self.webhook_path if self.webhook_path.startswith("/") else f"/{self.webhook_path}"
        return f"{base}{path}"

    def use_webhook(self) -> bool:
        return bool(self.resolved_webhook_url())


@lru_cache
def get_settings() -> Settings:
    settings = Settings()  # type: ignore[call-arg]
    settings.ensure_dirs()
    return settings
