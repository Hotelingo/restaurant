from collections import defaultdict

from fastapi import APIRouter, Depends

from ..auth import AuthenticatedUser, get_current_user
from ..db import user_transaction
from ..schemas import AuthContextResponse, OrganisationContext, OutletContext

router = APIRouter(prefix="/auth", tags=["auth"])


@router.get("/context", response_model=AuthContextResponse)
async def auth_context(
    user: AuthenticatedUser = Depends(get_current_user),
) -> AuthContextResponse:
    async with user_transaction(user.id) as conn:
        memberships = await conn.execute(
            """
            select
              m.organisation_id,
              o.name as organisation_name,
              o.slug,
              m.role::text as role
            from membership m
            join organisation o on o.id = m.organisation_id
            where m.user_id = current_app_user_id()
              and m.active
            order by o.name, m.role::text
            """
        )
        membership_rows = await memberships.fetchall()

        outlets = await conn.execute(
            """
            select
              o.organisation_id,
              o.id,
              o.name,
              o.code,
              o.currency_code,
              o.timezone,
              m.role::text as role
            from outlet o
            join membership m
              on m.organisation_id = o.organisation_id
             and m.user_id = current_app_user_id()
             and m.active
            where has_outlet_access(o.organisation_id, o.id)
            order by o.name, m.role::text
            """
        )
        outlet_rows = await outlets.fetchall()

    org_roles: dict = defaultdict(set)
    org_meta: dict = {}
    outlet_meta: dict = {}
    outlet_roles: dict = defaultdict(set)

    for row in membership_rows:
        org_id = row["organisation_id"]
        org_meta[org_id] = row
        org_roles[org_id].add(row["role"])

    for row in outlet_rows:
        key = (row["organisation_id"], row["id"])
        outlet_meta[key] = row
        outlet_roles[key].add(row["role"])

    organisations: list[OrganisationContext] = []
    for org_id in sorted(org_meta, key=lambda oid: org_meta[oid]["organisation_name"].lower()):
        outlet_models = []
        keys = [key for key in outlet_meta if key[0] == org_id]
        for key in sorted(keys, key=lambda item: outlet_meta[item]["name"].lower()):
            row = outlet_meta[key]
            outlet_models.append(
                OutletContext(
                    id=row["id"],
                    name=row["name"],
                    code=row["code"],
                    currency_code=row["currency_code"].strip(),
                    timezone=row["timezone"],
                    roles=sorted(outlet_roles[key]),
                )
            )

        organisations.append(
            OrganisationContext(
                id=org_id,
                name=org_meta[org_id]["organisation_name"],
                slug=org_meta[org_id]["slug"],
                roles=sorted(org_roles[org_id]),
                outlets=outlet_models,
            )
        )

    return AuthContextResponse(user_id=user.id, organisations=organisations)
