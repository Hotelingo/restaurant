# Calculation worker image. Build from the repository root:
#   docker build -f workers/Dockerfile -t restaurant-worker .
# DATABASE_URL must be the restaurant_worker login (migration 0041), never the owner.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

WORKDIR /app

COPY workers/requirements.txt /app/workers/requirements.txt
RUN python -m pip install --no-cache-dir -r workers/requirements.txt

COPY packages /app/packages
COPY workers /app/workers

RUN useradd --create-home --uid 10001 worker
USER worker

CMD ["python", "-m", "workers.pl_worker"]
