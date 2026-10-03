# syntax=docker/dockerfile:1

# Base image pinned by digest so every build uses the exact same bytes.
# Update deliberately: docker buildx imagetools inspect python:3.14-slim
ARG PYTHON_IMAGE=python:3.14-slim@sha256:0741d101873c12ab927e6f8653feb8862b9bd58771177acb1b885b95141f91b4

# ---------- Build stage: install dependencies into a virtual environment ----------
FROM ${PYTHON_IMAGE} AS build

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
# pip is only needed to install; remove it so it is not copied into the runtime image.
RUN pip install -r requirements.txt \
 && pip uninstall -y pip


# ---------- Runtime stage: only the venv and the application code ----------
FROM ${PYTHON_IMAGE} AS runtime

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MEDIBOOK_DB=/data/medibook.db

# Apply Debian security updates, remove the base image's pip (not needed at runtime),
# then create an unprivileged user with a fixed UID and a writable directory for the database.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && python -m pip uninstall -y pip \
 && groupadd --system --gid 10001 medibook \
 && useradd --system --uid 10001 --gid medibook --no-create-home --shell /usr/sbin/nologin medibook \
 && mkdir /data \
 && chown medibook:medibook /data

# Declared volumes: on ECS Fargate the image's /data (owned by medibook) and /tmp
# are copied into the task's writable volumes, so the non-root user can write there
# while the root filesystem stays read-only.
VOLUME ["/data", "/tmp"]

WORKDIR /srv
COPY --from=build /opt/venv /opt/venv
COPY app/ ./app/

USER 10001:10001

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).status == 200 else 1)"]

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]