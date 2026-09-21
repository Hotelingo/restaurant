FROM python:3.12-slim

WORKDIR /app

COPY packages /app/packages
COPY workers /app/workers

RUN python -m pip install --no-cache-dir -r workers/requirements.txt

ENV PYTHONPATH=/app
CMD ["python", "-m", "workers.pl_worker"]
