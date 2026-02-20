# ============================================================
# Stage 1: Clone + Build
# ============================================================
FROM node:22-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Accepts a branch (develop, mcp-prod) or a Penpot release tag (2.13.3, 2.14.0-RC1)
ARG PENPOT_VERSION=develop

WORKDIR /build

# Sparse-checkout only mcp/ (~1.2 MB instead of the full repo)
RUN git clone --depth 1 --filter=blob:none --sparse \
    --branch "${PENPOT_VERSION}" \
    https://github.com/penpot/penpot.git . \
    && git sparse-checkout set mcp

WORKDIR /build/mcp

# pnpm version is pinned via packageManager in package.json
RUN corepack enable && corepack install

# Install all workspace deps (common + server + plugin)
RUN pnpm install

# Build common (TypeScript types) then server (esbuild bundle + static/data)
RUN pnpm --filter "mcp-common" run build \
    && pnpm --filter "mcp-server" run build

# Assemble a flat production dist:
#   /dist/package.json  – server deps only, workspace ref stripped
#   /dist/dist/         – bundled JS + static + data
RUN mkdir -p /dist \
    && cp -r packages/server/dist /dist/dist \
    && jq --arg pm "$(jq -r '.packageManager' package.json)" \
       'del(.dependencies["penpot-mcp"]) | del(.devDependencies) | .packageManager = $pm | .pnpm.onlyBuiltDependencies = ["sharp"]' \
       packages/server/package.json > /dist/package.json


# ============================================================
# Stage 2: Runtime
# ============================================================
FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    dumb-init \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1001 penpot && useradd -u 1001 -g penpot -m penpot

WORKDIR /app

# Copy flat dist from builder
COPY --from=builder /dist/package.json .
COPY --from=builder /dist/dist ./dist

COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# Install production deps only (sharp gets platform-specific binaries here)
RUN corepack enable && pnpm install --prod

# Server resolves data/ and static/ relative to process.cwd()
RUN ln -s /app/dist/data /app/data \
    && ln -s /app/dist/static /app/static

# Logs directory writable by non-root user
RUN mkdir -p /app/logs && chown penpot:penpot /app/logs

# ── Environment defaults ──────────────────────────────────────
ENV PENPOT_MCP_SERVER_LISTEN_ADDRESS=0.0.0.0
ENV PENPOT_MCP_SERVER_PORT=4401
ENV PENPOT_MCP_WEBSOCKET_PORT=4402
ENV PENPOT_MCP_REPL_PORT=4403
ENV PENPOT_MCP_LOG_LEVEL=info
ENV PENPOT_MCP_LOG_DIR=/app/logs
ENV PENPOT_MCP_REMOTE_MODE=false

EXPOSE 4401 4402 4403

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:'+(process.env.PENPOT_MCP_SERVER_PORT||4401)+'/').then(()=>process.exit(0)).catch(()=>process.exit(1))"

USER penpot

ENTRYPOINT ["dumb-init", "--", "/app/entrypoint.sh"]
