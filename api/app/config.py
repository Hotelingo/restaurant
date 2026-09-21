from functools import lru_cache

from pydantic import AnyHttpUrl, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_env: str = Field(default="local")
    database_url: str
    neon_auth_base_url: AnyHttpUrl
    neon_auth_jwks_url: AnyHttpUrl
    cors_origins: str = "http://localhost:3000"

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
