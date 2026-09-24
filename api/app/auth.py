from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from functools import lru_cache
from uuid import UUID

import jwt
from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import PyJWKClient

from .config import Settings, get_settings

bearer = HTTPBearer(auto_error=False)
logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class AuthenticatedUser:
    id: UUID
    email: str | None
    name: str | None


@lru_cache
def _jwks_client(jwks_url: str) -> PyJWKClient:
    return PyJWKClient(jwks_url, cache_keys=True)


def _decode_token(token: str, settings: Settings) -> dict:
    signing_key = _jwks_client(str(settings.neon_auth_jwks_url)).get_signing_key_from_jwt(token)
    return jwt.decode(
        token,
        signing_key.key,
        algorithms=["EdDSA"],
        issuer=settings.auth_origin,
        audience=settings.auth_origin,
        options={"require": ["exp", "iat", "sub"]},
    )


async def get_current_user(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
    settings: Settings = Depends(get_settings),
) -> AuthenticatedUser:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required",
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        payload = await asyncio.to_thread(_decode_token, credentials.credentials, settings)
        user_id = UUID(str(payload["sub"]))
    except (KeyError, ValueError, jwt.PyJWTError) as exc:
        try:
            header = jwt.get_unverified_header(credentials.credentials)
            unverified = jwt.decode(
                credentials.credentials,
                options={
                    "verify_signature": False,
                    "verify_exp": False,
                    "verify_aud": False,
                    "verify_iss": False,
                },
                algorithms=["EdDSA"],
            )
            logger.warning(
                "Neon JWT rejected: error=%s alg=%s kid=%s iss=%s aud=%s expected=%s",
                type(exc).__name__,
                header.get("alg"),
                header.get("kid"),
                unverified.get("iss"),
                unverified.get("aud"),
                str(settings.neon_auth_base_url).rstrip("/"),
            )
        except Exception:
            logger.warning("Neon JWT rejected: error=%s; token metadata unreadable", type(exc).__name__)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired authentication token",
            headers={"WWW-Authenticate": "Bearer"},
        ) from None

    request.state.user_id = user_id
    return AuthenticatedUser(
        id=user_id,
        email=payload.get("email"),
        name=payload.get("name"),
    )
