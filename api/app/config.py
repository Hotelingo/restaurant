from functools import lru_cache

from pydantic import AnyHttpUrl, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_env: str = Field(default="local")
    database_url: str
    neon_auth_base_url: AnyHttpUrl
    neon_auth_jwks_url: AnyHttpUrl
    cors_origins: str = "http://localhost:3000"

    storage_bucket: str = "uploads"
    aws_region: str | None = None
    aws_endpoint_url_s3: str | None = None
    aws_access_key_id: str | None = None
    aws_secret_access_key: str | None = None

    upload_max_bytes: int = 25 * 1024 * 1024
    upload_max_rows: int = 250_000
    upload_timeout_seconds: float = 60.0
    xlsx_max_entries: int = 2_000
    xlsx_max_uncompressed_bytes: int = 150 * 1024 * 1024
    xlsx_max_entry_bytes: int = 50 * 1024 * 1024
    xlsx_max_compression_ratio: float = 100.0

    clamav_host: str | None = None
    clamav_port: int = 3310
    clamav_timeout_seconds: float = 15.0

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    @property
    def auth_origin(self) -> str:
        url = self.neon_auth_base_url
        port = f":{url.port}" if url.port else ""
        return f"{url.scheme}://{url.host}{port}"

    @property
    def cors_origin_list(self) -> list[str]:
        return [item.strip() for item in self.cors_origins.split(",") if item.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
