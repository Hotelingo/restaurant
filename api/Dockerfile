# API image. Build from the repository root:
#   docker build -f api/Dockerfile -t restaurant-api .
# It also carries the migration runner, so a host's pre-deploy step can run
#   python scripts/migrate.py --target preview up
# with MIGRATION_DATABASE_URL set to the schema owner's direct connection.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app:/app/api \
    PORT=8000

WORKDIR /app

COPY api/pyproject.toml /app/api/pyproject.toml
COPY api/app /app/api/app
RUN python -m pip install --no-cache-dir /app/api

COPY packages /app/packages
COPY scripts /app/scripts
COPY db/migrations /app/db/migrations

RUN useradd --create-home --uid 10001 app
USER app

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python -c "import os,urllib.request; urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"PORT\",\"8000\")}/health', timeout=4)"

# Proxy headers: TLS terminates at the host's load balancer.
CMD ["sh", "-c", "exec uvicorn app.main:app --app-dir /app/api --host 0.0.0.0 --port ${PORT} --proxy-headers --forwarded-allow-ips='*'"]
