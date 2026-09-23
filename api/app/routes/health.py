from fastapi import APIRouter
from fastapi.responses import JSONResponse

from ..db import ping

router = APIRouter(tags=["health"])


@router.get("/health")
async def health() -> dict[str, str]:
    """Liveness: the process is up. Deliberately does not touch the database, so a
    brief database outage does not make the host restart a healthy API."""
    return {"status": "ok"}


@router.get("/health/ready")
async def ready() -> JSONResponse:
    """Readiness: the API can reach the database, answered within a few seconds."""
    if await ping():
        return JSONResponse({"status": "ok", "database": "ok"})
    return JSONResponse({"status": "unavailable", "database": "unreachable"}, status_code=503)
