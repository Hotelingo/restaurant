from __future__ import annotations

import asyncio
import os
from uuid import UUID

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from app.pack_artifacts import (
    PACK_RENDERER_VERSION,
    PACK_TEMPLATE_VERSION,
    artifact_sha256,
    build_pack_artifact_snapshot,
    pack_source_sha256,
    render_owner_pack_html,
)
from app.routes.reviewer_workbench import (
    _evaluate_pack_gate,
    _gate_response,
    _gate_snapshot,
    _load_pack_gate_context,
)


DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5433/neon_test",
)
MANAGER_ID = UUID("29000000-0000-0000-0000-000000000001")
REVIEWER_ID = UUID("29000000-0000-0000-0000-000000000002")


class FakeStorage:
    bucket = "uploads"

    def __init__(self) -> None:
        self.objects: dict[str, bytes] = {}

    async def put(
        self,
        *,
        key: str,
        data: bytes,
        content_type: str,
        sha256_hex: str,
    ) -> None:
        assert content_type == "text/html; charset=utf-8"
        assert artifact_sha256(data) == sha256_hex
        self.objects[key] = data



async def set_user(conn: psycopg.AsyncConnection, user_id: UUID) -> None:
    await conn.execute(
        "select set_config('app.user_id',%s,false)",
        (str(user_id),),
    )


async def latest_pack_id(conn: psycopg.AsyncConnection) -> UUID:
    result = await conn.execute(
        """
        select p.id
        from pack_version p
        join review r on r.id=p.review_id
        join outlet o on o.id=r.outlet_id
        where o.code='R1ACC'
        order by p.version_no desc,p.created_at desc,p.id desc
        limit 1
        """
    )
    row = await result.fetchone()
    if row is None:
        raise AssertionError("R1 Owner Pack was not created")
    return row["id"]


async def evaluate(conn: psycopg.AsyncConnection, pack_id: UUID):
    pack = await _load_pack_gate_context(conn, pack_id)
    if pack is None:
        raise AssertionError("R1 Owner Pack could not be loaded for RG")

    result = await _evaluate_pack_gate(
        conn,
        pack=pack,
        signer_user_id=REVIEWER_ID,
    )
    response = _gate_response(
        review_id=pack["review_id"],
        pack_id=pack_id,
        result=result,
    )

    if not response.passed:
        failures = ", ".join(item.code for item in response.failures)
        raise AssertionError(f"R1 review gate failed: {failures}")
    if len(response.outcomes) != 11:
        raise AssertionError(
            f"R1 review gate expected 11 outcomes, got {len(response.outcomes)}"
        )

    return pack, response, _gate_snapshot(response)


async def main() -> None:
    conn = await psycopg.AsyncConnection.connect(
        DATABASE_URL,
        row_factory=dict_row,
    )
    try:
        await set_user(conn, REVIEWER_ID)
        pack_id = await latest_pack_id(conn)

        artifact_snapshot = await build_pack_artifact_snapshot(conn, pack_id)
        if artifact_snapshot is None:
            raise AssertionError("R1 Owner Pack render source could not be loaded")
        source_hash = pack_source_sha256(artifact_snapshot)
        artifact = render_owner_pack_html(artifact_snapshot)
        artifact_hash = artifact_sha256(artifact)
        storage = FakeStorage()
        storage_key = (
            f"org/{artifact_snapshot['pack']['organisation_id']}"
            f"/outlet/{artifact_snapshot['pack']['outlet_id']}"
            f"/packs/{pack_id}/owner-pack-v"
            f"{artifact_snapshot['pack']['version_no']}-{source_hash[:12]}.html"
        )
        await storage.put(
            key=storage_key,
            data=artifact,
            content_type="text/html; charset=utf-8",
            sha256_hex=artifact_hash,
        )
        attach = await conn.execute(
            """
            select * from attach_pack_artifact(
              %s,%s,%s,%s,%s,%s,%s,%s,%s
            )
            """,
            (
                pack_id,
                storage.bucket,
                storage_key,
                artifact_hash,
                source_hash,
                PACK_RENDERER_VERSION,
                PACK_TEMPLATE_VERSION,
                "r1-pack-render0001",
                "r1-acceptance",
            ),
        )
        attach_row = await attach.fetchone()
        if attach_row is None or attach_row["artifact_sha256"] != artifact_hash:
            raise AssertionError("R1 Owner Pack artifact metadata was not attached")
        if storage.objects.get(storage_key) != artifact:
            raise AssertionError("R1 Owner Pack artifact bytes were not stored")
        if not artifact.startswith(b"<!doctype html>"):
            raise AssertionError("R1 Owner Pack renderer did not emit deterministic HTML")
        await conn.commit()

        pack, first_response, first_snapshot = await evaluate(conn, pack_id)

        # Step 12 first exercises request-changes history.
        result = await conn.execute(
            """
            select * from record_pack_signoff(
              %s,%s,%s,%s,%s,%s::jsonb,%s,%s
            )
            """,
            (
                pack_id,
                "changes_requested",
                "Clarify the action wording before final approval.",
                ["Management P&L", "Decision and action"],
                ["Inventory and menu modules"],
                Jsonb(first_snapshot),
                "r1-signoff-changes1",
                "r1-acceptance",
            ),
        )
        row = await result.fetchone()
        if row is None or str(row["pack_status"]) != "changes_requested":
            raise AssertionError("R1 request-changes sign-off was not recorded")
        await conn.commit()

        # Management responds by resubmitting the same immutable pack version.
        await set_user(conn, MANAGER_ID)
        result = await conn.execute(
            "select * from submit_pack_for_review(%s,%s,%s)",
            (pack_id, "r1-pack-resubmit01", "r1-acceptance"),
        )
        row = await result.fetchone()
        if row is None or str(row["pack_status"]) != "in_review":
            raise AssertionError("R1 pack could not be resubmitted after changes request")
        await conn.commit()

        # Re-evaluate from persisted authoritative state, then sign through the
        # server-only database function with the exact RG snapshot.
        await set_user(conn, REVIEWER_ID)
        pack, final_response, final_snapshot = await evaluate(conn, pack_id)

        result = await conn.execute(
            """
            select * from record_pack_signoff(
              %s,%s,%s,%s,%s,%s::jsonb,%s,%s
            )
            """,
            (
                pack_id,
                "signed",
                "Reviewed against the stated R1 Management P&L scope.",
                ["Management P&L", "Decision and action"],
                ["Inventory and menu modules"],
                Jsonb(final_snapshot),
                "r1-signoff-final001",
                "r1-acceptance",
            ),
        )
        row = await result.fetchone()
        if row is None or str(row["pack_status"]) != "signed":
            raise AssertionError("R1 final sign-off was not recorded")
        await conn.commit()

        print(
            "PASS R1 deterministic renderer stored a hashed Owner Pack; "
            "server review gate evaluated 11 conditions, preserved "
            "request-changes history, and signed the pack"
        )
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
