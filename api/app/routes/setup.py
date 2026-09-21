from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Request, status
from psycopg.errors import UniqueViolation

from ..auth import AuthenticatedUser, get_current_user
from ..db import user_transaction
from ..schemas import BootstrapRequest, BootstrapResponse

router = APIRouter(prefix="/setup", tags=["setup"])


@router.post(
    "/bootstrap",
    response_model=BootstrapResponse,
    status_code=status.HTTP_201_CREATED,
)
async def bootstrap(
    payload: BootstrapRequest,
    request: Request,
    user: AuthenticatedUser = Depends(get_current_user),
) -> BootstrapResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    try:
        async with user_transaction(user.id) as conn:
            existing = await conn.execute(
                """
                select count(*)::int as count
                from membership
                where user_id = current_app_user_id()
                  and active
                """
            )
            existing_row = await existing.fetchone()
            if existing_row and existing_row["count"] > 0:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="User already has an active organisation membership",
                )

            result = await conn.execute(
                """
                select organisation_id, outlet_id
                from bootstrap_organisation(
                  %s, %s, %s, %s, %s, %s, %s, %s
                )
                """,
                (
                    payload.organisation_name,
                    payload.organisation_slug,
                    payload.outlet_name,
                    payload.outlet_code or "",
                    payload.currency_code,
                    payload.timezone,
                    payload.fiscal_year_start_month,
                    correlation_id,
                ),
            )
            row = await result.fetchone()
    except UniqueViolation as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Organisation slug or outlet code already exists",
        ) from exc

    if row is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Bootstrap did not return an organisation",
        )

    return BootstrapResponse(
        organisation_id=row["organisation_id"],
        outlet_id=row["outlet_id"],
    )
