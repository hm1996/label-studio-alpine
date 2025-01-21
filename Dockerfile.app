# syntax=docker/dockerfile:1
ARG PYTHON_VERSION=3.11
ARG POETRY_VERSION=1.8.4
ARG VERSION_OVERRIDE
ARG BRANCH_OVERRIDE

FROM python:${PYTHON_VERSION}-alpine3.21 AS venv-builder
ARG POETRY_VERSION

RUN --mount=type=cache,target="/var/cache/apk",sharing=locked \
    set -eux; \
    apk update; \
    apk add python3 py-pip git; \
    pip install --no-cache-dir --upgrade pip

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=off \
    PIP_DISABLE_PIP_VERSION_CHECK=on \
    PIP_DEFAULT_TIMEOUT=100 \
    PIP_CACHE_DIR="/.cache" \
    POETRY_CACHE_DIR="/.poetry-cache" \
    POETRY_HOME="/opt/poetry" \
    POETRY_VIRTUALENVS_IN_PROJECT=true \
    PATH="/opt/poetry/bin:$PATH"

ADD https://install.python-poetry.org /tmp/install-poetry.py
RUN python /tmp/install-poetry.py

WORKDIR /label-studio

ENV VENV_PATH="/label-studio/.venv"
ENV PATH="$VENV_PATH/bin:$PATH"

## Starting from this line all packages will be installed in $VENV_PATH

# Copy dependency files
COPY pyproject.toml poetry.lock README.md ./

# Install dependencies without dev packages
RUN --mount=type=cache,target=$POETRY_CACHE_DIR,sharing=locked \
    poetry lock --no-update; \
    poetry check --lock && poetry install --no-root --without test --extras uwsgi

# Install LS
COPY label_studio label_studio
RUN --mount=type=cache,target=$POETRY_CACHE_DIR,sharing=locked \
    # `--extras uwsgi` is mandatory here due to poetry bug: https://github.com/python-poetry/poetry/issues/7302
    poetry install --only-root --extras uwsgi && \
    pip install -U jinja2; \
    python3 label_studio/manage.py collectstatic --no-input

################################ Stage: py-version-generator
FROM venv-builder AS py-version-generator
ARG VERSION_OVERRIDE
ARG BRANCH_OVERRIDE

RUN git config --global --add safe.directory /label-studio

# Create version_.py and ls-version_.py
RUN --mount=type=bind,source=.git,target=./.git \
    VERSION_OVERRIDE=${VERSION_OVERRIDE} BRANCH_OVERRIDE=${BRANCH_OVERRIDE} poetry run python label_studio/core/version.py

################################### Stage: prod
FROM python:${PYTHON_VERSION}-alpine3.21 AS production

ENV LS_DIR=/label-studio \
    HOME=/label-studio \
    LABEL_STUDIO_BASE_DATA_DIR=/label-studio/data \
    OPT_DIR=/opt/heartex/instance-data/etc \
    PATH="/label-studio/.venv/bin:$PATH" \
    DJANGO_SETTINGS_MODULE=core.settings.label_studio \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR $LS_DIR

# install prerequisites for app
# Install basic dependencies
RUN --mount=type=cache,target="/var/cache/apk",sharing=locked \
    set -eux; \
    pip3 install -U setuptools; \
    apk update; \
    apk upgrade; \
    apk add --no-cache gnupg curl bash

# Directory setup and permissions
RUN set -eux; \
    mkdir -p $LS_DIR $LABEL_STUDIO_BASE_DATA_DIR $OPT_DIR && \
    chown -R 1001:0 $LS_DIR $LABEL_STUDIO_BASE_DATA_DIR $OPT_DIR

# Copy essential files for installing Label Studio and its dependencies
COPY --chown=1001:0 pyproject.toml .
COPY --chown=1001:0 poetry.lock .
COPY --chown=1001:0 README.md .
COPY --chown=1001:0 LICENSE LICENSE
COPY --chown=1001:0 licenses licenses
COPY --chown=1001:0 deploy deploy

# Copy files from build stages
COPY --chown=1001:0 --from=venv-builder               $LS_DIR                                           $LS_DIR
COPY --chown=1001:0 --from=py-version-generator       $LS_DIR/label_studio/core/version_.py             $LS_DIR/label_studio/core/version_.py

USER 1001

EXPOSE 8080

ENTRYPOINT ["./deploy/docker-entrypoint.sh"]
CMD ["label-studio"]