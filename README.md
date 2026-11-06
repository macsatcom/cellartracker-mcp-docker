# CellarTracker MCP — Docker

Runs [cellartracker-mcp](https://github.com/slavins-co/cellartracker-mcp) (a stdio MCP
server for your CellarTracker wine cellar) behind
[`mcpo`](https://github.com/open-webui/mcpo), exposing it as an OpenAPI/REST HTTP API
that [Open WebUI](https://docs.openwebui.com/features/extensibility/plugin/tools/openapi-servers/open-webui) can register
as a Tool Server.

## Why a bridge?

cellartracker-mcp only speaks MCP's JSON-RPC-over-stdio protocol — it has no built-in
HTTP transport. `mcpo` spawns it as a child process and exposes its 11 tools as a REST
API with auto-generated OpenAPI docs instead.

## Setup

1. Copy the env template and fill it in:

   ```bash
   cp .env.example .env
   ```

   - `CT_USERNAME` / `CT_PASSWORD` — your CellarTracker.com login. CellarTracker has no
     scoped or read-only API tokens; this server only performs read operations, but it
     authenticates with your full account. Use a unique password you don't reuse
     elsewhere.
   - `MCPO_API_KEY` — a bearer token Open WebUI must send on every request. Generate one
     with `openssl rand -hex 32`. Leave blank only if you fully trust everything on your
     local network.
   - `PORT` — host port to publish (container always listens on 8000 internally).

2. Start it:

   ```bash
   docker compose up -d
   ```

   This pulls the pre-built image from GitHub Container Registry (see
   [Pre-built images](#pre-built-images) below) — no local build required.

3. Confirm it's healthy:

   ```bash
   docker compose ps
   docker compose logs -f cellartracker-mcp
   ```

   You should see `cellartracker-mcp: server running on stdio` and
   `Uvicorn running on http://0.0.0.0:8000`.

4. Sanity-check the API:

   ```bash
   curl -H "Authorization: Bearer $(grep MCPO_API_KEY .env | cut -d= -f2-)" \
     http://localhost:8000/openapi.json
   ```

   Or open `http://localhost:8000/docs` in a browser for interactive Swagger docs.

## Pre-built images

`docker-compose.yml` pulls `ghcr.io/macsatcom/cellartracker-mcp-docker:latest` by
default — a pre-built, multi-arch (`linux/amd64` + `linux/arm64`) image published
automatically by [`.github/workflows/release.yml`](.github/workflows/release.yml)
whenever a new `cellartracker-mcp` version is published to npm (checked every 6 hours).
There's nothing to build locally; `docker compose up -d` just pulls and runs it.

To pick up a version newer than what you last pulled:

```bash
docker compose pull
docker compose up -d
```

Specific version tags are also published, e.g.
`ghcr.io/macsatcom/cellartracker-mcp-docker:0.5.4`, if you want to pin to one instead of
always tracking `:latest`.

If you'd rather build from source yourself instead of pulling, replace
`docker-compose.yml`'s `image:` line with:
```yaml
    build:
      context: .
      args:
        CT_MCP_VERSION: "0.5.4"   # or any cellartracker-mcp version
```
then run `docker compose up -d --build`.

## Registering in Open WebUI

Open WebUI distinguishes **User Tool Servers** (personal, connected directly from your
browser) from **Global Tool Servers** (admin-managed, shared with other users, called
from the Open WebUI backend). For a single-user local setup, User Tool Servers are
simpler and avoid a container-networking gotcha described below — use that unless you
need to share this tool with other Open WebUI users.

**Option A — User Tool Server (recommended for solo/local use):**

1. In Open WebUI: **Settings → Integrations** (only visible once an admin enables
   *Direct Integrations* under **Settings → Admin → Integrations → User Connections** —
   this is off by default, so as the admin you'll likely need to turn it on yourself the
   first time. The per-user *Direct Tool Servers* permission, needed for anyone who
   isn't an admin, is also off by default.).
2. Click **➕** in the **Tools** section.
3. **URL:** `http://localhost:8000` — this is resolved directly by your browser, so it
   works as long as you access Open WebUI itself at `http://localhost:...` too (see the
   Networking note below if you access Open WebUI from a different machine/IP).
4. **Auth:** Bearer, with the value of `MCPO_API_KEY` from your `.env`.
5. Save. The tool becomes available immediately in your own chats.

**Option B — Global Tool Server (shared across all users):**

1. In Open WebUI: **Settings → Admin → Integrations**, **Tools** section, click **➕**.
2. **URL:** the address the *Open WebUI backend* can reach — if Open WebUI's backend
   runs in its own container, `localhost` means that container's localhost, not this
   host, so use `http://host.docker.internal:8000` instead (or this host's real IP; see
   the Networking note).
3. **Auth:** Bearer, with the value of `MCPO_API_KEY` from your `.env`.
4. Save. Global tools are **hidden by default** in chat — click the **Integrations**
   button in the message input area and manually toggle this tool on per chat before
   it's usable.

Either way, once connected, Open WebUI reads `/openapi.json` and lists all 11
CellarTracker tools automatically.

## Networking note

Where "localhost" resolves to depends on which registration option you used above:

- **User Tool Server:** the request comes from your own browser. `http://localhost:8000`
  works as long as you also open Open WebUI itself at `http://localhost:...`. If you
  access Open WebUI from another device (e.g. `http://10.0.0.5:3000`), replace
  `localhost` with this host's actual IP, and change the port binding below to publish
  on all interfaces.
- **Global Tool Server:** the request comes from the Open WebUI *backend*. If that
  backend itself runs in a container, its `localhost` is not this host — use
  `http://host.docker.internal:8000` (Docker Desktop) or this host's real LAN IP.

By default `docker-compose.yml` binds this container's port to all interfaces (i.e.
reachable from other devices on your LAN, not just this host) — needed for the common
case where Open WebUI runs on a different machine or in a separate container. This does
mean anyone on your local network can reach the API, so keep `MCPO_API_KEY` set in
`.env` unless you fully trust everyone on it. If you only ever access this from the same
host Open WebUI runs on, you can tighten the port mapping in `docker-compose.yml` from
`"${PORT:-8000}:8000"` back to `"127.0.0.1:${PORT:-8000}:8000"` instead. Alternatively,
attach both services to a shared Docker network and have Open WebUI reach this service
by its container/service name (`http://cellartracker-mcp:8000`) — this avoids
publishing a host port at all.

## Data persistence

CellarTracker CSV exports are cached on the named volume `cellartracker-cache`
(`/data/cache` inside the container) and auto-refresh every 24 hours. The cache survives
`docker compose down` / `up` and container recreation. To force a full data refresh
immediately, call the `refresh-data` tool (via Open WebUI, or
`curl -X POST -H "Authorization: Bearer $MCPO_API_KEY" http://localhost:8000/refresh-data`),
or wipe the volume with Compose's own `-v` flag (this targets the correct volume
regardless of what directory you cloned this repo into):

```bash
docker compose down -v
docker compose up -d
```

## Updating versions

- **cellartracker-mcp:** nothing to do manually — the release workflow republishes
  `:latest` automatically whenever upstream ships a new version. Run
  `docker compose pull && docker compose up -d` whenever you want to pick up the newest
  published image (see [Pre-built images](#pre-built-images)). If you switched to
  building locally instead, bump the `CT_MCP_VERSION` build arg in `docker-compose.yml`
  and run `docker compose up -d --build`.
- **mcpo base image:** only relevant if you're building locally. Update the `FROM` line
  in `Dockerfile` to a newer `ghcr.io/open-webui/mcpo:git-<short-sha>` tag (find the
  latest commit at https://github.com/open-webui/mcpo), then rebuild.

## Security

- Credentials live only in your local, gitignored `.env` file.
- The container runs as a non-root user.
- The port is published on all network interfaces by default (see
  [Networking note](#networking-note)) — reachable by anything on your LAN, not just
  this host.
- This server authenticates to CellarTracker with your real account password (no scoped
  tokens exist). Use a unique password for CellarTracker and keep `MCPO_API_KEY` set
  unless you fully trust your local network.
