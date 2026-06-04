# syntax=docker/dockerfile:1

FROM debian:bookworm-slim AS build

ARG ZIG_VERSION=0.16.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    curl \
    xz-utils \
    ca-certificates \
    gzip \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL \
    "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt \
 && ln -s /opt/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /src

COPY build.zig .
COPY build.zig.zon .
COPY src ./src

COPY references.json.gz .
COPY normalization.json .
COPY mcc_risk.json .

#
# gera o modelo
#
RUN gzip -dc references.json.gz > references.json \
 && zig build prepare -- references.json 16 \
 && rm references.json

#
# gera binário principal
#
RUN zig build --release=fast

#
# runtime
#
FROM debian:bookworm-slim

WORKDIR /app

COPY --from=build /src/zig-out/bin/rinhavec /app/server
COPY --from=build /src/rinha.vec /app/rinha.vec
COPY --from=build /src/normalization.json /app/normalization.json
COPY --from=build /src/mcc_risk.json /app/mcc_risk.json

EXPOSE 8080

ENTRYPOINT ["/app/server"]
