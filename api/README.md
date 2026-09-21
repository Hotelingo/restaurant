# Restaurant Performance Review API

FastAPI is the server-authoritative application layer.

## Current Slice 1 endpoints

- `GET /health`
- `GET /auth/context`
- `POST /setup/bootstrap`

The API verifies Neon Auth JWTs using the branch JWKS endpoint. It then opens a transaction using
the non-owner `restaurant_app` PostgreSQL role and sets `app.user_id` from the verified JWT
subject. PostgreSQL RLS resolves tenant access from that transaction-local identity.

## Local development

```bash
cd api
python -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
```

Copy `.env.example` to `.env` and supply the feature-branch values. Use the **pooled**
`restaurant_app` connection for normal API traffic.

```bash
uvicorn app.main:app --reload
pytest
```

Never connect application traffic as `neondb_owner`. Direct/unpooled owner access is reserved for
migrations and controlled administration.
