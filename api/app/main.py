from __future__ import annotations

from contextlib import asynccontextmanager
from uuid import uuid4

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware

from .config import get_settings
from .db import close_pool, open_pool
from .routes.auth_context import router as auth_context_router
from .routes.controls import router as controls_router
from .routes.health import router as health_router
from .routes.imports import router as imports_router
from .routes.members import router as members_router
from .routes.setup import router as setup_router
from .routes.setup_detail import router as setup_detail_router


@asynccontextmanager
async def lifespan(_: FastAPI):
    await open_pool()
    try:
        yield
    finally:
        await close_pool()


settings = get_settings()

app = FastAPI(
    title="Restaurant Performance Review API",
    version="0.4.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=[
        "Authorization",
        "Content-Type",
        "Idempotency-Key",
        "X-Correlation-ID",
    ],
)


@app.middleware("http")
async def correlation_id_middleware(request: Request, call_next):
    correlation_id = request.headers.get("X-Correlation-ID") or str(uuid4())
    request.state.correlation_id = correlation_id
    response = await call_next(request)
    response.headers["X-Correlation-ID"] = correlation_id
    return response


app.include_router(health_router)
app.include_router(imports_router)
app.include_router(members_router)
app.include_router(auth_context_router)
app.include_router(controls_router)
app.include_router(setup_router)
app.include_router(setup_detail_router)
