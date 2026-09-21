from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from uuid import UUID

from psycopg import AsyncConnection
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from .config import get_settings

_pool: AsyncConnectionPool | None = None


async def open_pool() -> None:
    global _pool
    if _pool is not None:
        return

    settings = get_settings()
    _pool = AsyncConnectionPool(
        conninfo=settings.database_url,
        min_size=1,
        max_size=10,
        open=False,
        kwargs={"row_factory": dict_row},
    )
    await _pool.open(wait=True)


async def close_pool() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


@asynccontextmanager
async def user_transaction(user_id: UUID) -> AsyncIterator[AsyncConnection]:
    if _pool is None:
        raise RuntimeError("Database pool has not been opened")

    async with _pool.connection() as conn:
        async with conn.transaction():
            await conn.execute(
                "select set_config('app.user_id', %s, true)",
                (str(user_id),),
            )
            yield conn


@asynccontextmanager
async def anonymous_transaction() -> AsyncIterator[AsyncConnection]:
    if _pool is None:
        raise RuntimeError("Database pool has not been opened")

    async with _pool.connection() as conn:
        async with conn.transaction():
            # Deliberately do not set app.user_id. Only narrowly scoped
            # SECURITY DEFINER functions intended for public preview may be used here.
            yield conn
