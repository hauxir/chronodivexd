# syntax=docker/dockerfile:1

# ── Build stage ────────────────────────────────────────────────────────────
# Pinned Elixir/OTP/Debian so the build is reproducible. exqlite (ecto_sqlite3)
# compiles its bundled SQLite from source, hence build-essential below.
ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.1.2
ARG DEBIAN_VERSION=bookworm-20241016-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y build-essential git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Fetch deps first so the layer caches when only app code changes.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/runtime.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib

RUN mix compile
RUN mix release

# ── Runtime stage ──────────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# SQLite database lives on a writable volume by default.
ENV DATABASE_PATH=/data/chronodivexd.db
RUN mkdir -p /data && chown nobody /data
VOLUME /data

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/chronodivexd ./
COPY --chown=nobody:root rel/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

USER nobody

ENV PORT=4000
EXPOSE 4000

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["start"]
