FROM bitnami/python:latest AS builder

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_NO_DEV=1

RUN tdnf install -y tzdata && tdnf clean all

COPY --from=ghcr.io/astral-sh/uv:0.10.0 /uv /uvx /usr/local/bin/

COPY . .
RUN uv sync --locked --no-dev
RUN /app/.venv/bin/python manage.py collectstatic --noinput

FROM bitnami/python:latest

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:${PATH}"

RUN tdnf install -y tzdata && tdnf clean all

COPY --from=builder /app /app
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && \
    chown -R 1001:0 /app /entrypoint.sh

USER 1001

ENTRYPOINT ["/entrypoint.sh"]
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/metrics', timeout=3).read()" || exit 1
CMD ["gunicorn", "config.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3", "--worker-tmp-dir", "/tmp"]
