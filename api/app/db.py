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


async def grant_audited_staff_read(
    conn: AsyncConnection,
    *,
    organisation_id: UUID,
    outlet_id: UUID | None,
    action_code: str,
    object_type: str,
    object_id: str | None,
    correlation_id: str | None,
) -> None:
    """Authorize one scoped staff read and write its audit event.

    Staff-facing endpoints must call this inside the same user_transaction
    before selecting customer data. RLS only recognises the transaction-local
    grant created by the database function.
    """
    result = await conn.execute(
        """
        select authorize_staff_read(%s,%s,%s,%s,%s,%s) as allowed
        """,
        (
            organisation_id,
            outlet_id,
            action_code,
            object_type,
            object_id,
            correlation_id,
        ),
    )
    row = await result.fetchone()
    if row is None or not row["allowed"]:
        raise PermissionError("Staff read authorization was not granted")
