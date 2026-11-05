# CellarTracker MCP Docker — Auto-Release Pipeline Design

## Purpose

1. Publish this project (`cellartracker-mcp-docker`) as a new **public GitHub repo**
   under the `macsatcom` account, with the current `master` pushed.
2. Add a **GitHub Actions workflow** that automatically tracks new releases of the
   upstream `cellartracker-mcp` npm package, builds a multi-arch Docker image, publishes
   it to GitHub Container Registry, and cuts a real GitHub Release — with no manual
   steps required when upstream ships a new version.

## Why polling, not a native trigger

GitHub Actions has no event for "a repo I don't own published a release." The
`slavins-co/cellartracker-mcp` repo is not under our control, so it cannot dispatch a
`repository_dispatch` into this repo, and there is no built-in cross-repo release
webhook. The only mechanism that works without upstream cooperation is **scheduled
polling**: a cron-triggered workflow step compares upstream's current published version
against what we last built, and only proceeds when it changed. This is the same
mechanism tools like Dependabot use under the hood.

**Version source of truth:** the **npm registry's `dist-tags.latest`** for
`cellartracker-mcp` (`https://registry.npmjs.org/cellartracker-mcp`), not GitHub's
Releases API. The Dockerfile installs via `npm install -g cellartracker-mcp@${VERSION}`,
so npm's published version is the literal, precise signal of "there's something new for
us to build" — GitHub Releases and npm publishes happen together in upstream's own CI,
so these are equivalent in practice, but npm is the more direct source for what we
actually consume.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ .github/workflows/release.yml                               │
│   on: schedule (every 6h, cron) + workflow_dispatch          │
│                                                               │
│  1. Query npm registry: dist-tags.latest for cellartracker-mcp│
│  2. Compare to CT_MCP_VERSION currently in Dockerfile         │
│  3. If same → exit, nothing to do (clean no-op run)           │
│  4. If different:                                             │
│     a. Build multi-arch (amd64+arm64) image via Buildx/QEMU,  │
│        with CT_MCP_VERSION build-arg overridden to the NEW    │
│        version (repo files not yet touched)                   │
│     b. Push image to                                          │
│        ghcr.io/macsatcom/cellartracker-mcp-docker,            │
│        tagged :X.Y.Z and :latest                               │
│     c. Only after a successful push: edit Dockerfile          │
│        (CT_MCP_VERSION) + docker-compose.yml (build.args +     │
│        image tag) to the new version, in the checkout          │
│     d. Commit + push to master ("chore: bump cellartracker-   │
│        mcp to vX.Y.Z")                                        │
│     e. Create a GitHub Release tagged vX.Y.Z with notes        │
│        linking to the upstream release                        │
└─────────────────────────────────────────────────────────────┘
```

**Ordering rationale:** build and publish the image *before* committing the version
bump to the repo. If the build or push fails, the workflow fails loudly and the repo's
checked-in `Dockerfile`/`docker-compose.yml` still accurately describe what's actually
published on `ghcr.io` — there is never a window where the repo claims a version is
pinned/published that isn't actually there yet.

## Key decisions

1. **Trigger:** scheduled polling, cron `0 */6 * * *` (every 6 hours), plus manual
   `workflow_dispatch` for on-demand runs.
2. **Version detection:** npm registry `dist-tags.latest`, compared via a simple regex
   extraction of the current `ARG CT_MCP_VERSION=` default from `Dockerfile`.
3. **Registry:** `ghcr.io/macsatcom/cellartracker-mcp-docker`. Uses the workflow's
   built-in `GITHUB_TOKEN` — no extra secrets. Requires `permissions: packages: write`
   in the workflow.
4. **Repo write-back:** the workflow commits the version bump using the same
   `GITHUB_TOKEN` (`permissions: contents: write`), authenticated as
   `github-actions[bot]`.
5. **Release creation:** via `gh release create` (same token, `contents: write` covers
   Releases), tag `vX.Y.Z` mirroring upstream's version exactly. Release notes link to
   the corresponding `slavins-co/cellartracker-mcp` GitHub release
   (`https://github.com/slavins-co/cellartracker-mcp/releases/tag/vX.Y.Z`) and to the
   published image tag.
6. **Multi-arch builds:** `docker/setup-qemu-action` + `docker/setup-buildx-action` +
   `docker/build-push-action`, targeting `linux/amd64,linux/arm64`.
7. **Idempotency/safety:** the version-compare step is the sole gate. A `workflow_dispatch`
   run when nothing changed upstream exits cleanly after the compare step — no commit,
   no build, no release, safe to re-run anytime.
8. **Repo name/visibility/owner:** new public GitHub repo `cellartracker-mcp-docker`
   under the `macsatcom` account, current `master` pushed as the initial history.
9. **Release tag scheme:** mirrors upstream's version exactly (`v0.5.4`, `v0.5.5`, …). A
   packaging-only fix unrelated to an upstream bump (not automated, done by hand if ever
   needed) would use a suffix like `v0.5.4-1` — out of scope for this automated
   pipeline, noted here only so the scheme has a documented escape hatch.

## Components

- **New file: `.github/workflows/release.yml`**
  - `on.schedule`: `cron: '0 */6 * * *'`
  - `on.workflow_dispatch`: `{}` (no inputs needed)
  - `permissions: contents: write, packages: write`
  - Steps: checkout → fetch npm latest version (`curl` + `jq`) → extract current pinned
    version from `Dockerfile` → compare → (if changed) QEMU/Buildx setup → build+push
    multi-arch image with the new version as build-arg → edit `Dockerfile` +
    `docker-compose.yml` → commit + push → `gh release create`.

- **GitHub repo creation** (one-time, via `gh repo create cellartracker-mcp-docker
  --public --source=. --push`): creates the repo under `macsatcom`, pushes `master`.

- **No changes to the existing `Dockerfile`/`docker-compose.yml` structure** — the
  workflow edits the same two values (`ARG CT_MCP_VERSION=` default, and the mirrored
  values in `docker-compose.yml`'s `build.args` and `image:` tag) that a human would
  edit by hand per the README's existing "Updating versions" section. This workflow
  automates exactly that manual process.

- **README update:** add a short "Pre-built images" section noting that
  `ghcr.io/macsatcom/cellartracker-mcp-docker:latest` (and versioned tags) are published
  automatically, as an alternative to `docker compose build` locally. This does not
  change the default `docker-compose.yml` behavior (still builds locally by default,
  per the existing design) — switching `docker-compose.yml` to pull a prebuilt image
  instead of building is explicitly **out of scope** for this change, to keep this
  feature focused on CI/publishing rather than also restructuring the compose file.

## Error handling

- **npm registry unreachable:** the fetch step fails the workflow run (visible as a red
  X in the Actions tab); no silent skip.
- **Build/push failure:** workflow fails before any repo commit is made — the checked-in
  pins remain accurate to the last successfully published image.
- **Commit/push race** (e.g. someone else pushed to master between checkout and this
  workflow's push): the workflow's push step fails loudly; the image is still correctly
  published on `ghcr.io` even though the repo commit didn't land, and the next scheduled
  run will detect the still-pending version-bump (since Dockerfile wasn't updated) and
  retry the whole sequence, including re-pushing the (already-current) image tags
  idempotently.
- **Release creation failure after a successful commit:** the version bump and image are
  already live; only the GitHub Release page itself would be missing. Treated as a
  non-fatal, loudly-logged warning rather than rolling back the commit, since rolling
  back a pushed commit automatically is riskier than leaving a release to be created
  manually as a fallback.

## Testing / validation plan

This is a CI pipeline, not application code, so validation is operational:

1. Create the public repo, push `master`.
2. Add the workflow file, push it.
3. Trigger `workflow_dispatch` manually once. Since the currently pinned
   `CT_MCP_VERSION` (0.5.4) should already equal npm's `dist-tags.latest` at the time of
   this work, expect a clean no-op run (compare step finds no difference, workflow exits
   successfully with no commit/build/release).
4. To prove the full bump→build→publish→release path actually fires without waiting for
   a real upstream release: temporarily edit the workflow's compare step (in a throwaway
   test branch, never merged) to treat a fake older version as "current," run it, confirm
   the entire pipeline executes correctly (image appears on `ghcr.io` with the right
   tags, commit lands, release is created) — then discard that test branch/commits and
   any test release/image tags it created.
5. Confirm the real, unmodified workflow on `master` still correctly no-ops against the
   genuine pinned version afterward.

## Out of scope

- Switching `docker-compose.yml` to pull the prebuilt image instead of building locally
  (noted above as a possible future change, not part of this work).
- Any trigger mechanism requiring write access to or cooperation from
  `slavins-co/cellartracker-mcp` (e.g. asking them to add a `repository_dispatch` call).
- Docker Hub publishing (ghcr.io only, per the answered question).
- Automated packaging-only release suffixes (`-1`, `-2`, …) — the scheme is documented
  but not automated; this pipeline only ever mirrors upstream version bumps.
