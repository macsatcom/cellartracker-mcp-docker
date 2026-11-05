# Base image: Open WebUI's official MCP-to-OpenAPI bridge. Already bundles
# Python 3.12 + uv + Node 22/npm specifically so it can run Node-based MCP
# servers like cellartracker-mcp.
#
# Pinned to the immutable git-sha tag (not the floating "main" tag) for
# reproducible builds. To update: find the new HEAD commit of
# https://github.com/open-webui/mcpo and use its short sha, e.g.
# `ghcr.io/open-webui/mcpo:git-<short-sha>`.
FROM ghcr.io/open-webui/mcpo:git-788ff92

# Pin cellartracker-mcp at build time. This means:
#  - no network fetch at container startup (unlike `npx -y cellartracker-mcp`)
#  - reproducible builds
#  - avoids the "npx local-resolution footgun" the upstream README warns
#    about (npx resolving to a stale local checkout instead of the registry)
ARG CT_MCP_VERSION=0.5.4
RUN npm install -g cellartracker-mcp@${CT_MCP_VERSION} && npm cache clean --force

# Non-root user: this container holds real CellarTracker account credentials
# (CellarTracker has no scoped/read-only API tokens — see upstream README's
# Security & Credentials section).
RUN useradd --create-home --uid 1000 --shell /bin/bash appuser

# cellartracker-mcp caches its CSV exports here (overridable via CT_CACHE_DIR,
# see src/config.ts upstream). Mounted as a named volume in docker-compose.yml
# so the cache survives container recreation.
ENV CT_CACHE_DIR=/data/cache
RUN mkdir -p /data/cache && chown -R appuser:appuser /data/cache /app

USER appuser

EXPOSE 8000

# The base image sets ENTRYPOINT ["mcpo"]; override it to a shell form so
# $MCPO_API_KEY expands from the container's environment at runtime (exec-form
# CMD/ENTRYPOINT arrays do not perform shell variable substitution). `exec`
# keeps mcpo as PID 1 so it receives signals directly (clean shutdown).
ENTRYPOINT []
CMD ["sh", "-c", "exec mcpo --host 0.0.0.0 --port 8000 --api-key \"$MCPO_API_KEY\" -- cellartracker-mcp"]
