# Build
ARG PYTHON_BUILD_IMAGE=python:3.12.14-trixie@sha256:ffe26975518e90491ad275249ee202584dd8dccbe82b3ff93420a34d2a1db986
ARG PYTHON_RUNTIME_IMAGE=python:3.12.14-slim-trixie@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9

FROM ${PYTHON_BUILD_IMAGE} AS build
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /build

# Copy requirements and install
COPY requirements-runtime.txt requirements-container.txt ./
RUN python -m venv --without-pip /opt/venv \
    && python -m pip --python /opt/venv/bin/python install \
        --no-cache-dir -r requirements-container.txt \
    && python -m pip --python /opt/venv/bin/python check

# Install the application wheel
COPY pyproject.toml README.md ./
COPY app/ ./app/
RUN python -m pip wheel --no-cache-dir --no-deps --wheel-dir /wheels . \
    && python -m pip --python /opt/venv/bin/python install \
        --no-cache-dir --no-deps /wheels/*.whl \
    && python -m pip --python /opt/venv/bin/python check

FROM ${PYTHON_RUNTIME_IMAGE} AS runtime
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Creating user without root
RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --no-create-home \
        --home-dir /nonexistent --shell /usr/sbin/nologin app
WORKDIR /srv/app

# Keep installed code owned by root
COPY --from=build /opt/venv /opt/venv
USER 10001:10001

EXPOSE 5000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import json, urllib.request; r = urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=2); assert r.status == 200 and json.load(r) == {'status': 'ok'}"]

CMD ["gunicorn", "--bind=0.0.0.0:5000", "--workers=2", "--worker-class=gthread", "--threads=2", "--timeout=30", "--graceful-timeout=30", "--worker-tmp-dir=/tmp", "--access-logfile=-", "--error-logfile=-", "app:create_app()"]
