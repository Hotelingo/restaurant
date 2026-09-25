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

    # "required" (default): uploads need ClamAV outside local/test/ci.
    # "unscanned_testing": accept uploads without scanning, for staging/preview
    # test data only. Refused in every other environment; see malware.py.
    malware_scan_mode: str = "required"
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
        is_default_port = (
            (url.scheme == "https" and url.port == 443)
            or (url.scheme == "http" and url.port == 80)
        )
        port = f":{url.port}" if url.port and not is_default_port else ""
        return f"{url.scheme}://{url.host}{port}"

    @property
    def cors_origin_list(self) -> list[str]:
        return [item.strip() for item in self.cors_origins.split(",") if item.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
