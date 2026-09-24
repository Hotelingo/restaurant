FROM python:3.12-slim

WORKDIR /app

COPY packages /app/packages
COPY api /app/api
COPY scripts /app/scripts
COPY db /app/db

RUN python -m pip install --no-cache-dir -e /app/api

ENV PYTHONPATH=/app:/app/api
EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--app-dir", "api", "--host", "0.0.0.0", "--port", "8000"]
