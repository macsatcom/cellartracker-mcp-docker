# CellarTracker MCP Docker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package `slavins-co/cellartracker-mcp` (a stdio-only MCP server) as a Docker
container, runnable via `docker-compose`, reachable from Open WebUI as an OpenAPI Tool
Server.

**Architecture:** One container runs [`mcpo`](https://github.com/open-webui/mcpo) (Open
WebUI's official MCP-to-OpenAPI bridge), which spawns `cellartracker-mcp` as a stdio
child process and exposes an auto-generated OpenAPI/REST API over HTTP on port 8000.
CellarTracker credentials and the mcpo API key are supplied via `.env` /
`env_file:` in docker-compose. The CSV export cache persists on a named volume.

**Tech Stack:** Docker, docker-compose, `ghcr.io/open-webui/mcpo` base image (Python 3.12
+ Node 22), `cellartracker-mcp` npm package (pinned `0.5.4`).

**Reference spec:** `docs/superpowers/specs/2026-11-05-cellartracker-mcp-docker-design.md`

---

## Validation approach for this plan

This project is infrastructure config, not application logic — there's no unit-testable
function to TDD. Each task below substitutes real verification commands (docker build,
container run, curl against the live HTTP API) for the red/green test cycle. Every
command and its expected output in this plan was run and confirmed during design
(base image `ghcr.io/open-webui/mcpo:git-788ff92`, `cellartracker-mcp@0.5.4` installs
cleanly, `/openapi.json` returns the 11 tools without requiring the API key, `curl` is
present in the base image for the healthcheck).

---

### Task 1: Project scaffolding — `.gitignore` and `.env.example`

**Files:**
- Create: `.gitignore`
- Create: `.env.example`

- [ ] **Step 1: Create `.gitignore`**

```
.env
```

- [ ] **Step 2: Create `.env.example`**

```
# CellarTracker credentials (same as your cellartracker.com web login)
CT_USERNAME=your_username
CT_PASSWORD=your_password

# Bearer token Open WebUI must send to reach this server's HTTP API.
# Leave blank to disable auth (only safe on a fully trusted local network).
MCPO_API_KEY=change-me-to-a-long-random-string

# Host port to publish the OpenAPI server on (container always listens on 8000)
PORT=8000
```

- [ ] **Step 3: Verify**

```bash
cat .gitignore .env.example
```
Expected: both files print their exact contents above, no typos.

- [ ] **Step 4: Commit**

```bash
git add .gitignore .env.example
git commit -m "chore: add .gitignore and .env.example"
```

---

### Task 2: Dockerfile

**Files:**
- Create: `Dockerfile`

- [ ] **Step 1: Write `Dockerfile`**

```dockerfile
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
RUN npm install -g cellartracker-mcp@${CT_MCP_VERSION}

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
```

- [ ] **Step 2: Build the image**

```bash
docker build -t cellartracker-mcp-docker .
```
Expected: build completes successfully, last line `naming to docker.io/library/cellartracker-mcp-docker done` (or similar "exporting to image" success output). No errors.

- [ ] **Step 3: Smoke-test the image directly (no compose yet)**

```bash
docker run -d --rm --name ct-mcp-verify -p 18000:8000 \
  -e CT_USERNAME=dummyuser -e CT_PASSWORD=dummypass \
  -e MCPO_API_KEY=testkey \
  cellartracker-mcp-docker
sleep 3
docker logs ct-mcp-verify
```
Expected log output includes:
```
cellartracker-mcp: server running on stdio
INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)
```

```bash
curl -s http://localhost:18000/openapi.json | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['paths']), 'paths')"
docker stop ct-mcp-verify
```
Expected: `11 paths`.

- [ ] **Step 4: Commit**

```bash
git add Dockerfile
git commit -m "feat: add Dockerfile bridging cellartracker-mcp via mcpo"
```

---

### Task 3: docker-compose.yml

**Files:**
- Create: `docker-compose.yml`

- [ ] **Step 1: Write `docker-compose.yml`**

```yaml
services:
  cellartracker-mcp:
    build:
      context: .
      args:
        CT_MCP_VERSION: "0.5.4"
    image: cellartracker-mcp-docker:0.5.4
    env_file:
      - .env
    ports:
      # Bound to 127.0.0.1 by default: this assumes Open WebUI runs on the
      # same host. If Open WebUI runs elsewhere (another host, or a separate
      # compose project on the same Docker network), change this to
      # "${PORT:-8000}:8000" to bind all interfaces, or attach both services
      # to a shared Docker network instead of publishing a host port at all.
      - "127.0.0.1:${PORT:-8000}:8000"
    volumes:
      - cellartracker-cache:/data/cache
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/openapi.json"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  cellartracker-cache:
```

- [ ] **Step 2: Verify the compose file parses**

```bash
docker compose config --quiet && echo OK
```
Expected: `OK` with no errors.

- [ ] **Step 3: Create a real `.env` for local testing (not committed)**

```bash
cp .env.example .env
```
Edit `.env` and fill in real `CT_USERNAME` / `CT_PASSWORD`, and set `MCPO_API_KEY` to a
random string (e.g. `openssl rand -hex 32`).

- [ ] **Step 4: Build and start via compose**

```bash
docker compose build
docker compose up -d
docker compose ps
```
Expected: `docker compose ps` shows the `cellartracker-mcp` service as `running` (and,
after ~10s, `healthy` once the healthcheck's `start_period` elapses).

- [ ] **Step 5: Verify logs and the live HTTP API**

```bash
docker compose logs cellartracker-mcp
```
Expected to include `cellartracker-mcp: server running on stdio` and
`Uvicorn running on http://0.0.0.0:8000`.

```bash
source .env
curl -s -H "Authorization: Bearer $MCPO_API_KEY" http://localhost:${PORT:-8000}/openapi.json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(sorted(d['paths'].keys()))"
```
Expected: a list of all 11 tool paths, e.g. `['/bottle-details', '/cellar-stats',
'/clear-user-data', ...]` (exact names depend on the installed version; there should be
11 total).

- [ ] **Step 6: Verify cache persistence across a restart**

```bash
curl -s -H "Authorization: Bearer $MCPO_API_KEY" -X POST \
  http://localhost:${PORT:-8000}/cellar-stats -H "Content-Type: application/json" -d '{}' \
  -o /dev/null -w "%{http_code}\n"
docker compose restart cellartracker-mcp
sleep 3
docker exec $(docker compose ps -q cellartracker-mcp) ls -la /data/cache
```
Expected: the `cellar-stats` call returns `200` (if your real credentials in `.env` are
valid) or `500` with a CellarTracker auth error in the logs (if you used placeholder
credentials) — either way it proves the tool call reaches cellartracker-mcp. After
restart, `/data/cache` still lists the CSV files it cached before the restart (nonempty
`ls` output), proving the named volume persisted them.

- [ ] **Step 7: Tear down the manual test**

```bash
docker compose down
```

- [ ] **Step 8: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add docker-compose.yml for cellartracker-mcp"
```

---

### Task 4: README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# CellarTracker MCP — Docker

Runs [cellartracker-mcp](https://github.com/slavins-co/cellartracker-mcp) (a stdio MCP
server for your CellarTracker wine cellar) behind
[`mcpo`](https://github.com/open-webui/mcpo), exposing it as an OpenAPI/REST HTTP API
that [Open WebUI](https://docs.openwebui.com/openapi-servers/open-webui/) can register
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

2. Build and start:

   ```bash
   docker compose up -d --build
   ```

3. Confirm it's healthy:

   ```bash
   docker compose ps
   docker compose logs -f cellartracker-mcp
   ```

   You should see `cellartracker-mcp: server running on stdio` and
   `Uvicorn running on http://0.0.0.0:8000`.

4. Sanity-check the API:

   ```bash
   curl -H "Authorization: Bearer $(grep MCPO_API_KEY .env | cut -d= -f2)" \
     http://localhost:8000/openapi.json
   ```

   Or open `http://localhost:8000/docs` in a browser for interactive Swagger docs.

## Registering in Open WebUI

In Open WebUI: **Settings → Admin Settings → Tools → Tool Servers → Add a Tool Server**.

- **URL:** `http://localhost:8000` (or `http://<this-host>:8000` if Open WebUI runs on a
  different machine — see the networking note below)
- **Auth:** Bearer, with the value of `MCPO_API_KEY` from your `.env`

Open WebUI will fetch `/openapi.json` and list all 11 CellarTracker tools automatically.

## Networking note

By default `docker-compose.yml` binds the port to `127.0.0.1` only — i.e. reachable from
the same machine but not the rest of your local network. If Open WebUI runs:

- **On the same host** (as a local process, or another container published to
  `localhost`) — no changes needed.
- **On a different host** — change the port mapping in `docker-compose.yml` from
  `"127.0.0.1:${PORT:-8000}:8000"` to `"${PORT:-8000}:8000"` to bind all interfaces, and
  point Open WebUI at `http://<this-host-ip>:8000`.
- **In the same docker-compose project / a shared Docker network as Open WebUI** —
  instead of publishing a host port, attach both services to a common network and have
  Open WebUI reach this service by its container/service name
  (`http://cellartracker-mcp:8000`).

## Data persistence

CellarTracker CSV exports are cached on the named volume `cellartracker-cache`
(`/data/cache` inside the container) and auto-refresh every 24 hours. The cache survives
`docker compose down` / `up` and container recreation. To force a full data refresh
immediately, call the `refresh-data` tool (via Open WebUI, or
`curl -X POST .../refresh-data`), or wipe the volume:

```bash
docker compose down
docker volume rm cellartracker-mcp-docker_cellartracker-cache
docker compose up -d
```

## Updating versions

- **cellartracker-mcp:** bump the `CT_MCP_VERSION` build arg in `docker-compose.yml`
  (and optionally pin a specific release per the upstream README's recommendation), then
  `docker compose up -d --build`.
- **mcpo base image:** update the `FROM` line in `Dockerfile` to a newer
  `ghcr.io/open-webui/mcpo:git-<short-sha>` tag (find the latest commit at
  https://github.com/open-webui/mcpo), then rebuild.

## Security

- Credentials live only in your local, gitignored `.env` file.
- The container runs as a non-root user.
- This server authenticates to CellarTracker with your real account password (no scoped
  tokens exist). Use a unique password for CellarTracker and keep `MCPO_API_KEY` set
  unless you fully trust your local network.
```

- [ ] **Step 2: Verify**

```bash
cat README.md | head -5
```
Expected: renders the title `# CellarTracker MCP — Docker` with no markdown syntax
errors visible.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add README with setup and Open WebUI integration instructions"
```

---

### Task 5: End-to-end validation

**Files:** none (verification only)

- [ ] **Step 1: Full clean rebuild from scratch**

```bash
docker compose down -v --remove-orphans 2>/dev/null
docker compose build --no-cache
docker compose up -d
```
Expected: builds and starts with no errors.

- [ ] **Step 2: Wait for healthy status**

```bash
for i in $(seq 1 15); do
  status=$(docker compose ps --format json | python3 -c "import sys,json; print(json.loads(sys.stdin.readline())['Health'])" 2>/dev/null)
  echo "status: $status"
  [ "$status" = "healthy" ] && break
  sleep 2
done
```
Expected: eventually prints `status: healthy`.

- [ ] **Step 3: Verify all 11 tools are listed**

```bash
source .env
curl -s -H "Authorization: Bearer $MCPO_API_KEY" http://localhost:${PORT:-8000}/openapi.json \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
paths = sorted(d['paths'].keys())
print(len(paths), 'tools:')
for p in paths: print(' ', p)
"
```
Expected: `11 tools:` followed by paths matching the upstream tool list (`search-cellar`,
`drinking-recommendations`, `cellar-stats`, `purchase-history`, `recent-deliveries`,
`incoming-orders`, `get-wishlist`, `consumption-history`, `tasting-notes`,
`bottle-details`, `refresh-data`).

- [ ] **Step 4: Verify Swagger docs render**

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:${PORT:-8000}/docs
```
Expected: `200`.

- [ ] **Step 5: Verify restart preserves the cache volume**

```bash
docker compose restart cellartracker-mcp
sleep 5
docker compose ps
```
Expected: service returns to `running`/`healthy` without errors after restart.

- [ ] **Step 6: Clean up test containers (keep the volume)**

```bash
docker compose down
```

- [ ] **Step 7: Final commit (only if any fixes were needed above)**

If Steps 1–6 required any file changes to pass, commit them now with a message
describing the fix, e.g.:

```bash
git add -A
git commit -m "fix: <describe what the end-to-end validation caught>"
```

If no changes were needed, skip this step — nothing to commit.
