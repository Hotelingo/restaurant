from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
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
    idempotency_key: str = Header(alias="Idempotency-Key", min_length=8, max_length=200),
    user: AuthenticatedUser = Depends(get_current_user),
) -> BootstrapResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select organisation_id, outlet_id
                from bootstrap_organisation(
                  %s, %s, %s, %s, %s, %s, %s, %s, %s
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
                    idempotency_key,
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
