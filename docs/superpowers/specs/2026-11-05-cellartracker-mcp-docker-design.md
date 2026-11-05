# CellarTracker MCP Docker — Design

## Purpose

Package [slavins-co/cellartracker-mcp](https://github.com/slavins-co/cellartracker-mcp) — a
stdio-only MCP server exposing CellarTracker wine-cellar data as 11 tools — as a Docker
container runnable via `docker-compose`, reachable from **Open WebUI** running locally.

## Why not run the server directly

cellartracker-mcp speaks MCP's JSON-RPC-over-stdio protocol only
(`StdioServerTransport`, confirmed in `src/index.ts`). It has no built-in HTTP/SSE
transport. Open WebUI's "Tool Servers" feature consumes OpenAPI/REST endpoints, not raw
MCP stdio. A bridge is required.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│ docker-compose service: cellartracker-mcp            │
│                                                       │
│  ┌─────────────────────────────────────────────┐    │
│  │ mcpo (OpenAPI HTTP server, port 8000)        │    │
│  │   spawns & proxies stdio to:                 │    │
│  │   └─ cellartracker-mcp (Node, stdio MCP)     │    │
│  │        reads CT_USERNAME/CT_PASSWORD (env)   │    │
│  │        caches CSV exports → /data/cache      │    │
│  └─────────────────────────────────────────────┘    │
└──────────────────┬────────────────────────────────────┘
                    │ HTTP (OpenAPI), Bearer API key
                    ▼
            Open WebUI  (Tool Servers → add this URL)
```

One container runs [`mcpo`](https://github.com/open-webui/mcpo) (the official Open WebUI
MCP-to-OpenAPI bridge), which spawns `cellartracker-mcp` as a child process over stdio and
exposes an auto-generated OpenAPI/REST surface over HTTP. Open WebUI is pointed at this
HTTP endpoint from its own Settings → Tools → Tool Servers UI; no Open WebUI code changes
are needed.

## Decisions made during brainstorming

1. **Bridge:** `mcpo` (not a raw MCP SSE bridge) — it's the officially documented, Open
   WebUI–maintained way to add an MCP server as a Tool Server, with auto-generated
   OpenAPI docs and built-in API-key auth.
2. **Credentials:** supplied via `env_file: .env` (gitignored), not shell-exported
   variables — simpler, standard docker-compose convention.
3. **Dockerfile base:** `FROM ghcr.io/open-webui/mcpo:main` (already bundles Python + uv +
   Node 22/npm specifically to run Node-based MCP servers) plus one added layer:
   `npm install -g cellartracker-mcp@<pinned-version>`. Rejected alternatives:
   - Building Python+Node from scratch ourselves — duplicates maintenance the mcpo image
     already does.
   - Building cellartracker-mcp from source via git clone + `tsc` — more reproducible in
     theory, but upstream's own `.mcp.json`/README document and recommend the pinned-npm
     version pattern (`cellartracker-mcp@0.5.4`); a TypeScript build pipeline adds
     complexity without a clear benefit here.

## Components

- **`Dockerfile`**
  - `FROM ghcr.io/open-webui/mcpo:main`
  - `ARG CT_MCP_VERSION=0.5.4`
  - `RUN npm install -g cellartracker-mcp@${CT_MCP_VERSION}` (pinned at build time — no
    network fetch at container startup, avoids the "npx local-resolution footgun" the
    upstream README warns about)
  - Creates and switches to a non-root user
  - `ENV CT_CACHE_DIR=/data/cache`
  - `ENTRYPOINT`/`CMD` runs:
    `mcpo --host 0.0.0.0 --port 8000 --api-key "$MCPO_API_KEY" -- cellartracker-mcp`

- **`docker-compose.yml`**
  - One service (`cellartracker-mcp`)
  - `build: .`
  - `env_file: .env`
  - Port mapping: `${PORT:-8000}:8000`, bound to `127.0.0.1` by default (Open WebUI
    assumed to run on the same host; documented how to change this if Open WebUI runs in
    a separate compose project/network)
  - Named volume mounted at `/data/cache` for the CellarTracker CSV export cache
    (survives container recreation; server auto-refreshes every 24h rather than
    re-pulling on every restart)
  - `restart: unless-stopped`
  - Healthcheck against `/openapi.json`

- **`.env.example`** — template listing `CT_USERNAME`, `CT_PASSWORD`, `MCPO_API_KEY`,
  `PORT`.

- **`.gitignore`** — ignores `.env`.

- **`README.md`** — build/run instructions and exact steps to register the tool server
  in Open WebUI (URL + API key).

## Configuration & secrets

- `CT_USERNAME` / `CT_PASSWORD` passed through as container env vars. cellartracker-mcp's
  own credential resolution checks env vars first (see `src/config.ts`), so no
  `setup-credentials` tool call or on-disk `.env` inside the container is needed.
- `MCPO_API_KEY` passed to mcpo's `--api-key` flag, enforced as a Bearer token on every
  HTTP call. If left blank in `.env`, mcpo runs without auth; the README calls this out
  explicitly as acceptable only on a trusted local network.
- `CT_CACHE_DIR=/data/cache` set in the image so the CSV export cache lands on the
  mounted named volume.

## Security

- Non-root container user, since the account credentials grant full (read-capable)
  access to the user's CellarTracker account.
- `.env` git-ignored; `.env.example` committed as the template.
- Port bound to `127.0.0.1` by default; README documents how to widen this if Open WebUI
  is not on the same host.

## Testing / validation plan

This is infrastructure, not application code, so validation is operational:

1. `docker compose build` succeeds.
2. `docker compose up -d` starts cleanly.
3. `docker compose logs` shows mcpo's startup banner and
   `cellartracker-mcp: server running on stdio`.
4. `curl http://localhost:8000/openapi.json` (with the API key header if set) returns a
   valid OpenAPI schema listing all 11 tools.
5. `curl http://localhost:8000/docs` renders Swagger UI.
6. Restarting the container and confirming the cache volume persists (`docker compose
   down && docker compose up -d`, cache dir still populated, no immediate CSV re-fetch
   forced).

## Out of scope

- Modifying or forking the upstream cellartracker-mcp source.
- Exposing this over the public internet / TLS termination (local-only use case per the
  stated goal).
- Multi-tenant / multi-account support (single `.env` = single CellarTracker account per
  container, matching upstream's own single-account design).
