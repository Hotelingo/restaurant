from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request, status
from psycopg.errors import (
    CheckViolation,
    InsufficientPrivilege,
    InvalidParameterValue,
    UniqueViolation,
)

from ..auth import AuthenticatedUser, get_current_user
from ..db import anonymous_transaction, user_transaction
from ..member_schemas import (
    InvitationCreateRequest,
    InvitationCreateResponse,
    InvitationDecisionResponse,
    InvitationPreviewResponse,
    InvitationRow,
    MemberRow,
    MembersResponse,
    MembershipActiveRequest,
    MembershipActiveResponse,
    OrganisationOutletRow,
)

router = APIRouter(tags=["members"])


def _token_hash(raw_token: str) -> str:
    return hashlib.sha256(raw_token.encode("utf-8")).hexdigest()


@router.get(
    "/organisations/{organisation_id}/members",
    response_model=MembersResponse,
)
async def list_members(
    organisation_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> MembersResponse:
    async with user_transaction(user.id) as conn:
        organisation_result = await conn.execute(
            """
            select id,name
            from organisation
            where id=%s and has_full_admin_access(id)
            """,
            (organisation_id,),
        )
        organisation = await organisation_result.fetchone()
        if organisation is None:
            raise HTTPException(status_code=404, detail="Resource is not available")

        outlet_result = await conn.execute(
            """
            select id,name,code
            from outlet
            where organisation_id=%s and active
            order by name,id
            """,
            (organisation_id,),
        )
        outlets = [
            OrganisationOutletRow(**row)
            for row in await outlet_result.fetchall()
        ]

        member_result = await conn.execute(
            """
            select
              m.id as membership_id,
              m.user_id,
              ident.display_name,
              ident.email,
              m.role::text as role,
              m.outlet_scope_mode::text as scope_mode,
              coalesce(
                array_agg(mo.outlet_id order by o.name)
                  filter (where mo.outlet_id is not null),
                array[]::uuid[]
              ) as outlet_ids,
              coalesce(
                array_agg(o.name order by o.name)
                  filter (where o.id is not null),
                array[]::text[]
              ) as outlet_names,
              m.active
            from membership m
            left join lateral lookup_user_identity(m.organisation_id,m.user_id)
              ident on true
            left join membership_outlet mo on mo.membership_id=m.id
            left join outlet o on o.id=mo.outlet_id
            where m.organisation_id=%s
            group by
              m.id,m.user_id,ident.display_name,ident.email,
              m.role,m.outlet_scope_mode,m.active
            order by coalesce(ident.display_name,ident.email,m.user_id::text),m.role::text
            """,
            (organisation_id,),
        )
        members = [MemberRow(**row) for row in await member_result.fetchall()]

        invitation_result = await conn.execute(
            """
            select
              i.id as invitation_id,
              i.email,
              i.role::text as role,
              i.outlet_scope_mode::text as scope_mode,
              coalesce(
                array_agg(io.outlet_id order by o.name)
                  filter (where io.outlet_id is not null),
                array[]::uuid[]
              ) as outlet_ids,
              coalesce(
                array_agg(o.name order by o.name)
                  filter (where o.id is not null),
                array[]::text[]
              ) as outlet_names,
              case
                when i.status::text='pending' and i.expires_at <= now() then 'expired'
                else i.status::text
              end as status,
              i.expires_at,
              i.created_at
            from member_invitation i
            left join member_invitation_outlet io on io.invitation_id=i.id
            left join outlet o on o.id=io.outlet_id
            where i.organisation_id=%s
            group by
              i.id,i.email,i.role,i.outlet_scope_mode,
              i.status,i.expires_at,i.created_at
            order by i.created_at desc
            limit 100
            """,
            (organisation_id,),
        )
        invitations = [
            InvitationRow(**row)
            for row in await invitation_result.fetchall()
        ]

    return MembersResponse(
        organisation_id=organisation_id,
        organisation_name=organisation["name"],
        outlets=outlets,
        members=members,
        invitations=invitations,
    )


@router.post(
    "/organisations/{organisation_id}/invitations",
    response_model=InvitationCreateResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_invitation(
    organisation_id: UUID,
    payload: InvitationCreateRequest,
    request: Request,
    user: AuthenticatedUser = Depends(get_current_user),
) -> InvitationCreateResponse:
    raw_token = secrets.token_urlsafe(32)
    token_hash = _token_hash(raw_token)
    expires_at = datetime.now(timezone.utc) + timedelta(hours=payload.expires_in_hours)

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select invitation_id
                from create_member_invitation(
                  %s,%s,%s,%s,%s,%s,%s,%s
                )
                """,
                (
                    organisation_id,
                    str(payload.email),
                    payload.role,
                    payload.scope_mode,
                    payload.outlet_ids,
                    token_hash,
                    expires_at,
                    getattr(request.state, "correlation_id", None),
                ),
            )
            row = await result.fetchone()
    except InsufficientPrivilege as exc:
        raise HTTPException(status_code=404, detail="Resource is not available") from exc
    except (InvalidParameterValue, CheckViolation) as exc:
        raise HTTPException(
            status_code=422,
            detail=str(exc).splitlines()[0],
        ) from exc
    except UniqueViolation as exc:
        raise HTTPException(
            status_code=409,
            detail="A matching pending invitation already exists.",
        ) from exc

    if row is None:
        raise HTTPException(status_code=500, detail="Invitation was not created")

    return InvitationCreateResponse(
        invitation_id=row["invitation_id"],
        token=raw_token,
        accept_path=f"/auth/invite?token={raw_token}",
        expires_at=expires_at,
    )


@router.get(
    "/invitations/{token}/preview",
    response_model=InvitationPreviewResponse,
)
async def preview_invitation(token: str) -> InvitationPreviewResponse:
    async with anonymous_transaction() as conn:
        result = await conn.execute(
            """
            select
              invitation_id,organisation_name,role,scope_mode,
              outlet_names,inviter_name,expires_at,effective_status
            from preview_member_invitation(%s)
            """,
            (_token_hash(token),),
        )
        row = await result.fetchone()

    if row is None:
        raise HTTPException(status_code=404, detail="Invitation is not available")

    return InvitationPreviewResponse(
        invitation_id=row["invitation_id"],
        organisation_name=row["organisation_name"],
        role=row["role"],
        scope_mode=row["scope_mode"],
        outlet_names=row["outlet_names"],
        inviter_name=row["inviter_name"],
        expires_at=row["expires_at"],
        status=row["effective_status"],
    )


@router.post(
    "/invitations/{token}/accept",
    response_model=InvitationDecisionResponse,
)
async def accept_invitation(
    token: str,
    request: Request,
    user: AuthenticatedUser = Depends(get_current_user),
) -> InvitationDecisionResponse:
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select organisation_id,membership_id
                from accept_member_invitation(%s,%s)
                """,
                (
                    _token_hash(token),
                    getattr(request.state, "correlation_id", None),
                ),
            )
            row = await result.fetchone()
    except InsufficientPrivilege as exc:
        raise HTTPException(status_code=404, detail="Invitation is not available") from exc
    except InvalidParameterValue as exc:
        raise HTTPException(status_code=410, detail="Invitation is no longer available") from exc

    if row is None:
        raise HTTPException(status_code=410, detail="Invitation is no longer available")
    return InvitationDecisionResponse(**row)


@router.post(
    "/invitations/{token}/decline",
    response_model=InvitationDecisionResponse,
)
async def decline_invitation(
    token: str,
    request: Request,
    user: AuthenticatedUser = Depends(get_current_user),
) -> InvitationDecisionResponse:
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select invitation_id
                from decline_member_invitation(%s,%s)
                """,
                (
                    _token_hash(token),
                    getattr(request.state, "correlation_id", None),
                ),
            )
            row = await result.fetchone()
    except (InsufficientPrivilege, InvalidParameterValue) as exc:
        raise HTTPException(status_code=404, detail="Invitation is not available") from exc

    if row is None:
        raise HTTPException(status_code=404, detail="Invitation is not available")
    return InvitationDecisionResponse(invitation_id=row["invitation_id"])


@router.patch(
    "/organisations/{organisation_id}/members/{membership_id}",
    response_model=MembershipActiveResponse,
)
async def set_member_active(
    organisation_id: UUID,
    membership_id: UUID,
    payload: MembershipActiveRequest,
    request: Request,
    user: AuthenticatedUser = Depends(get_current_user),
) -> MembershipActiveResponse:
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select membership_id,active
                from set_membership_active(%s,%s,%s,%s)
                """,
                (
                    organisation_id,
                    membership_id,
                    payload.active,
                    getattr(request.state, "correlation_id", None),
                ),
            )
            row = await result.fetchone()
    except InsufficientPrivilege as exc:
        raise HTTPException(status_code=404, detail="Resource is not available") from exc
    except CheckViolation as exc:
        raise HTTPException(
            status_code=409,
            detail=str(exc).splitlines()[0],
        ) from exc
    except InvalidParameterValue as exc:
        raise HTTPException(status_code=404, detail="Resource is not available") from exc

    if row is None:
        raise HTTPException(status_code=404, detail="Resource is not available")
    return MembershipActiveResponse(**row)
