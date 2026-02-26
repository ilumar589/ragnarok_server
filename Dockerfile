# ─────────────────────────────────────────────────────
# Ragnarok HTTP Server — Docker Build + Benchmark Image
# ─────────────────────────────────────────────────────
#
# Multi-stage build:
#   Stage 1 (builder)  — downloads Odin, compiles the server
#   Stage 2 (runtime)  — slim image with server binary + wrk
#
# Build:
#   docker build -t ragnarok .
#
# Run server:
#   docker run -p 8080:8080 ragnarok
#
# Run wrk benchmarks (generates HTML report):
#   docker run --rm -v "${PWD}/reports:/app/reports" ragnarok /app/scripts/wrk-bench.sh
#

# ── Stage 1: Build ──────────────────────────────────
FROM ubuntu:22.04 AS builder

ARG ODIN_RELEASE=dev-2026-02
ARG ODIN_URL=https://github.com/odin-lang/Odin/releases/download/${ODIN_RELEASE}/odin-linux-amd64-${ODIN_RELEASE}.tar.gz

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl clang-14 llvm-14 \
    && ln -s /usr/bin/clang-14 /usr/bin/clang \
    && ln -s /usr/bin/llvm-config-14 /usr/bin/llvm-config \
    && rm -rf /var/lib/apt/lists/*

# Download pre-built Odin compiler
WORKDIR /opt
RUN curl -fSL "${ODIN_URL}" -o odin.tar.gz \
    && tar xzf odin.tar.gz \
    && rm odin.tar.gz \
    && ls -d */ \
    && mv $(ls -d */ | head -1) odin \
    && chmod +x /opt/odin/odin
ENV PATH="/opt/odin:${PATH}"

# Copy source and build
WORKDIR /app
COPY ragnarok.odin  ./
COPY ragnarok_http/  ./ragnarok_http/
COPY static/         ./static/

RUN odin build . -o:speed -out:ragnarok

# ── Stage 2: Runtime ────────────────────────────────
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        wrk curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy compiled binary + assets + scripts
COPY --from=builder /app/ragnarok  ./ragnarok
COPY --from=builder /app/static/   ./static/
COPY scripts/                      ./scripts/

RUN chmod +x ./scripts/*.sh \
    && mkdir -p /app/reports

EXPOSE 8080

CMD ["./ragnarok"]
