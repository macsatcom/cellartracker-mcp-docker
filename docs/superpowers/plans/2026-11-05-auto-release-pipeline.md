# Auto-Release Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish this project as a public GitHub repo, then add a GitHub Actions
workflow that polls npm for new `cellartracker-mcp` releases every 6 hours, and on
finding one, builds a multi-arch Docker image, publishes it to GHCR, bumps the repo's
pinned version, and cuts a GitHub Release — fully automated, no secrets beyond the
built-in `GITHUB_TOKEN`.

**Architecture:** One new workflow file (`.github/workflows/release.yml`) does the
entire detect→build→publish→commit→release sequence. Build-and-push happens *before*
the repo commit, so a failed build never leaves the repo claiming a version is
published that isn't.

**Tech Stack:** GitHub Actions (`actions/checkout`, `docker/setup-qemu-action`,
`docker/setup-buildx-action`, `docker/login-action`, `docker/build-push-action`), GitHub
CLI (`gh`), npm registry HTTP API, GitHub Container Registry (ghcr.io).

**Reference spec:** `docs/superpowers/specs/2026-11-05-auto-release-pipeline-design.md`

---

## Validation approach for this plan

Same as the previous plan in this repo: no unit-testable application logic here, so each
task substitutes real verification (YAML validation via `actionlint`, a manual
`workflow_dispatch` run, inspecting the resulting GHCR tags/commits/releases) for the
red/green cycle. The exact workflow YAML in Task 2 was already validated with
`actionlint` (clean, zero warnings) and with `python3 -c "import yaml; yaml.safe_load(...)"`
during design — this is the exact, already-validated content, not a draft.

---

### Task 1: Create the public GitHub repo and push

**Files:** none (repo-level operation only)

- [ ] **Step 1: Confirm current repo state**

```bash
cd /home/ksn/git-ksn/CellarTrackerMCPDocker
git status --short
git log --oneline -3
git remote -v
```
Expected: clean working tree, `master` as the current branch, no remote configured yet
(empty output from `git remote -v`).

- [ ] **Step 2: Create the public repo and push**

```bash
gh repo create cellartracker-mcp-docker --public --source=. --remote=origin --push
```
Expected: output confirms repo creation (`✓ Created repository <account>/cellartracker-mcp-docker on github.com`)
and a successful push of `master`.

- [ ] **Step 3: Verify**

```bash
git remote -v
gh repo view --web=false --json url,visibility,defaultBranchRef --jq '.url, .visibility, .defaultBranchRef.name'
```
Expected: `origin` remote pointing at the new repo, `visibility` = `PUBLIC`,
`defaultBranchRef.name` = `master`.

```bash
gh api repos/{owner}/cellartracker-mcp-docker/commits/master --jq '.sha' 2>&1
git rev-parse HEAD
```
Expected: both SHAs match, confirming the push landed.

- [ ] **Step 4: No commit needed**

This task only creates/pushes the repo — there's no new file to commit locally (the
push already happened in Step 2).

---

### Task 2: Add the release workflow

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create the workflows directory and write the workflow file**

```bash
mkdir -p .github/workflows
```

Write `.github/workflows/release.yml`:

```yaml
name: Track upstream release and publish image

on:
  schedule:
    - cron: '0 */6 * * *'
  workflow_dispatch: {}

concurrency:
  group: release
  cancel-in-progress: false

permissions:
  contents: write
  packages: write

jobs:
  check-and-release:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v7.0.1

      - name: Get latest cellartracker-mcp version from npm
        id: upstream
        run: |
          VERSION=$(curl -s https://registry.npmjs.org/cellartracker-mcp/latest | jq -r '.version')
          if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
            echo "Failed to fetch latest version from npm registry" >&2
            exit 1
          fi
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"

      - name: Get currently pinned version
        id: current
        run: |
          CURRENT=$(grep -oP '^ARG CT_MCP_VERSION=\K.*' Dockerfile)
          echo "version=$CURRENT" >> "$GITHUB_OUTPUT"

      - name: Compare versions
        id: compare
        run: |
          if [ "${{ steps.upstream.outputs.version }}" = "${{ steps.current.outputs.version }}" ]; then
            echo "changed=false" >> "$GITHUB_OUTPUT"
            echo "Up to date: cellartracker-mcp ${{ steps.current.outputs.version }} is still the latest."
          else
            echo "changed=true" >> "$GITHUB_OUTPUT"
            echo "New version detected: ${{ steps.current.outputs.version }} -> ${{ steps.upstream.outputs.version }}"
          fi

      - name: Compute lowercase image repository
        if: steps.compare.outputs.changed == 'true'
        id: image
        run: |
          OWNER_LC=$(echo "${{ github.repository_owner }}" | tr '[:upper:]' '[:lower:]')
          echo "repo=ghcr.io/${OWNER_LC}/cellartracker-mcp-docker" >> "$GITHUB_OUTPUT"

      - name: Set up QEMU
        if: steps.compare.outputs.changed == 'true'
        uses: docker/setup-qemu-action@v4.4.0

      - name: Set up Docker Buildx
        if: steps.compare.outputs.changed == 'true'
        uses: docker/setup-buildx-action@v4.4.1

      - name: Log in to GitHub Container Registry
        if: steps.compare.outputs.changed == 'true'
        uses: docker/login-action@v4.8.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push multi-arch image
        if: steps.compare.outputs.changed == 'true'
        uses: docker/build-push-action@v7.4.0
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          build-args: |
            CT_MCP_VERSION=${{ steps.upstream.outputs.version }}
          tags: |
            ${{ steps.image.outputs.repo }}:${{ steps.upstream.outputs.version }}
            ${{ steps.image.outputs.repo }}:latest

      - name: Bump pinned version in repo
        if: steps.compare.outputs.changed == 'true'
        run: |
          NEW_VERSION="${{ steps.upstream.outputs.version }}"
          sed -i "s/^ARG CT_MCP_VERSION=.*/ARG CT_MCP_VERSION=${NEW_VERSION}/" Dockerfile
          sed -i "s/CT_MCP_VERSION: \"[0-9.]*\"/CT_MCP_VERSION: \"${NEW_VERSION}\"/" docker-compose.yml
          sed -i "s/image: cellartracker-mcp-docker:[0-9.]*/image: cellartracker-mcp-docker:${NEW_VERSION}/" docker-compose.yml

      - name: Commit and push version bump
        if: steps.compare.outputs.changed == 'true'
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add Dockerfile docker-compose.yml
          git commit -m "chore: bump cellartracker-mcp to v${{ steps.upstream.outputs.version }}"
          git push origin HEAD:${{ github.ref_name }}

      - name: Create GitHub Release
        if: steps.compare.outputs.changed == 'true'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          VERSION="${{ steps.upstream.outputs.version }}"
          gh release create "v${VERSION}" \
            --title "v${VERSION}" \
            --notes "Tracks [cellartracker-mcp v${VERSION}](https://github.com/slavins-co/cellartracker-mcp/releases/tag/v${VERSION}). Image: \`${{ steps.image.outputs.repo }}:${VERSION}\`."
```

- [ ] **Step 2: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml')); print('VALID YAML')"
```
Expected: `VALID YAML`, no exception.

- [ ] **Step 3: Lint with actionlint**

```bash
docker run --rm -v "$(pwd)/.github/workflows:/repo" -w /repo rhysd/actionlint:latest release.yml
echo "exit code: $?"
```
Expected: no output (no warnings/errors), `exit code: 0`.

- [ ] **Step 4: Commit and push**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add workflow to auto-publish Docker image on new cellartracker-mcp releases"
git push
```

- [ ] **Step 5: Run it once manually and confirm a clean no-op**

```bash
gh workflow run release.yml --ref master
sleep 10
gh run list --workflow=release.yml --limit 1
```
Note the run ID from the output, then:
```bash
gh run watch <run-id> --exit-status
```
Expected: the run succeeds (`exit-status` 0). Then inspect the logs to confirm it took
the no-op path (since the repo's pinned `0.5.4` should already match npm's current
`dist-tags.latest` at this point):
```bash
gh run view <run-id> --log | grep -A2 "Compare versions"
```
Expected: log line `Up to date: cellartracker-mcp 0.5.4 is still the latest.` and no
build/commit/release steps executed (they're skipped by the `if:` condition — confirm
by checking the run doesn't show a new commit):
```bash
git log --oneline -3
```
Expected: no new commit appeared (HEAD is still your Step 4 commit).

---

### Task 3: Document pre-built images in the README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a "Pre-built images" section**

Insert this new section immediately after the "## Setup" section (before "## Registering in Open WebUI"):

```markdown
## Pre-built images

Instead of `docker compose build`, you can skip building locally and pull a pre-built,
automatically-updated image from GitHub Container Registry:

```
ghcr.io/macsatcom/cellartracker-mcp-docker:latest
ghcr.io/macsatcom/cellartracker-mcp-docker:0.5.4   # or any specific cellartracker-mcp version
```

These are built and published automatically by
[`.github/workflows/release.yml`](.github/workflows/release.yml) whenever a new
`cellartracker-mcp` version is published to npm (checked every 6 hours), for both
`linux/amd64` and `linux/arm64`. `docker-compose.yml` in this repo still builds locally
by default; to use a pre-built image instead, replace the service's `build:` block with
`image: ghcr.io/macsatcom/cellartracker-mcp-docker:latest`.
```

- [ ] **Step 2: Verify placement and rendering**

```bash
grep -n "^## " README.md
```
Expected order includes (not necessarily contiguous, but in this relative order):
`## Setup`, `## Pre-built images`, `## Registering in Open WebUI`, `## Networking note`,
`## Data persistence`, `## Updating versions`, `## Security`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document pre-built GHCR images"
git push
```

---

### Task 4: End-to-end validation of the full bump→build→publish→release path

**Files:** none (verification only, uses a throwaway branch that gets deleted)

- [ ] **Step 1: Create a throwaway branch with an artificially old pinned version**

```bash
git checkout -b test/release-pipeline-dry-run
sed -i "s/^ARG CT_MCP_VERSION=.*/ARG CT_MCP_VERSION=0.0.1/" Dockerfile
git add Dockerfile
git commit -m "test: fake an old pinned version to exercise the release pipeline"
git push -u origin test/release-pipeline-dry-run
```
`0.0.1` is a sentinel value that cannot collide with any real `cellartracker-mcp`
release (the real package is already at `0.5.x`), used only to force the workflow's
compare step to detect "a change."

- [ ] **Step 2: Manually dispatch the workflow against this branch**

```bash
gh workflow run release.yml --ref test/release-pipeline-dry-run
sleep 10
gh run list --workflow=release.yml --limit 1
```
Note the run ID, then:
```bash
gh run watch <run-id> --exit-status
```
Expected: the run succeeds end-to-end (exit status 0).

- [ ] **Step 3: Verify every stage actually fired**

```bash
gh run view <run-id> --log | grep -A2 "Compare versions"
```
Expected: `New version detected: 0.0.1 -> 0.5.4` (or whatever npm's current latest is at
test time).

```bash
docker manifest inspect ghcr.io/macsatcom/cellartracker-mcp-docker:0.5.4 | python3 -c "import sys,json; d=json.load(sys.stdin); print([m['platform'] for m in d['manifests']])"
```
Expected: output includes both `{'architecture': 'amd64', 'os': 'linux'}` and
`{'architecture': 'arm64', 'os': 'linux'}`.

```bash
git fetch origin test/release-pipeline-dry-run
git log --oneline origin/test/release-pipeline-dry-run -3
```
Expected: a new top commit `chore: bump cellartracker-mcp to v0.5.4` (or current npm
latest) on top of your Step 1 test commit, pushed by `github-actions[bot]`.

```bash
gh release view v0.5.4 --json tagName,name,body
```
Expected: a release exists with `tagName` `v0.5.4`, referencing the upstream release and
the GHCR image tag in its body.

- [ ] **Step 4: Clean up all test artifacts**

```bash
gh release delete v0.5.4 --cleanup-tag --yes
git checkout master
git branch -D test/release-pipeline-dry-run
git push origin --delete test/release-pipeline-dry-run
```
Expected: the release, its git tag, and the local+remote test branch are all gone.

NOTE: leave the `ghcr.io/macsatcom/cellartracker-mcp-docker:0.5.4` and `:latest` image
tags in place — they are genuinely correct (0.5.4 really is the current upstream
version), not test pollution, so there's nothing to revert there.

- [ ] **Step 5: Confirm master is untouched**

```bash
git status --short
git log --oneline -3
```
Expected: clean working tree, `master`'s HEAD is still your Task 3 Step 3 commit (no
version bump landed on `master`, since the test ran against the throwaway branch only).

- [ ] **Step 6: No commit needed**

This task is pure verification plus cleanup of artifacts already deleted in Step 4 —
nothing new to commit to `master`.
