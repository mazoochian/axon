FROM elixir:1.18-otp-27 AS builder

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY apps/axon_crypto/mix.exs apps/axon_crypto/
COPY apps/axon_core/mix.exs apps/axon_core/
COPY apps/axon_room/mix.exs apps/axon_room/
COPY apps/axon_sync/mix.exs apps/axon_sync/
COPY apps/axon_federation/mix.exs apps/axon_federation/
COPY apps/axon_media/mix.exs apps/axon_media/
COPY apps/axon_push/mix.exs apps/axon_push/
COPY apps/axon_web/mix.exs apps/axon_web/

ENV MIX_ENV=prod
RUN mix deps.get --only prod

COPY config/ config/
COPY apps/ apps/

RUN mix deps.compile && mix compile && mix release axon

# ---- runtime image ----
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    postgresql \
    libssl3 \
    libncurses6 \
    locales \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

COPY --from=builder /app/_build/prod/rel/axon /axon
COPY complement/start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8008

CMD ["/start.sh"]
