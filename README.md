# gh-runner-image

Custom GitHub Actions self-hosted runner image for [sweatstudio75/sweatstudio](https://github.com/sweatstudio75/sweatstudio).

Built on top of [`myoung34/github-runner`](https://github.com/myoung34/docker-github-actions-runner), with **Node 20 LTS** installed cleanly from NodeSource. Fixes the Ubuntu 20.04 base shipping `nodejs` 10 without `npm`, which shadows `actions/setup-node@v4` downloads.

## Tags published

Two variants are published on every semantic-release tag (`v*.*.*`):

| Tag | Contents |
|---|---|
| `ghcr.io/sweatstudio75/gh-runner-image:1-base` | Runner + Node 20 + npm + corepack (rolling v1.x — **recommended**) |
| `ghcr.io/sweatstudio75/gh-runner-image:1-chrome` | base + Google Chrome stable (for Lighthouse / Playwright) |
| `ghcr.io/sweatstudio75/gh-runner-image:latest-base` | Follows the highest semver across all majors (may jump v2.x, v3.x…) |
| `ghcr.io/sweatstudio75/gh-runner-image:1.0-base` | Rolling minor (v1.0.x) |
| `ghcr.io/sweatstudio75/gh-runner-image:1.0.0-base` | Immutable pin |
| `ghcr.io/sweatstudio75/gh-runner-image:sha-<short>-base` | Commit-pinned |

> Note: docker tags omit the `v` prefix (`1-base`, not `v1-base`) — `docker/metadata-action` strips it from semver tags.

## Versioning

Releases are driven by [semantic-release](https://semantic-release.gitbook.io/) from Conventional Commits on `main`. Push a `feat:` commit → minor bump. Push a `fix:` commit → patch bump. Push a `feat!:` / `BREAKING CHANGE:` → major bump.

## Usage

### Install a runner on a new host (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/sweatstudio75/gh-runner-image/main/scripts/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

Optional: pin a specific image tag via `GH_RUNNER_IMAGE_TAG=1.0.0 ./install.sh` (default is `1`, the rolling v1 major).

Sub-commands: `./install.sh --status` to check, `./install.sh --remove` to decommission.

### Manual docker run

```bash
docker pull ghcr.io/sweatstudio75/gh-runner-image:1-base
docker run -d --restart=always --name gh-runner-sweatstudio \
  --env-file /etc/gh-runner-sweatstudio/runner.env \
  -v /tmp/runner-work-sweatstudio:/tmp/runner-work-sweatstudio \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --network host \
  ghcr.io/sweatstudio75/gh-runner-image:1-base
```

For jobs needing Chrome (Lighthouse, headed Playwright):

```bash
docker pull ghcr.io/sweatstudio75/gh-runner-image:1-chrome
```

## Local build

```bash
docker build -t gh-runner-image:dev -f Dockerfile .
docker build -t gh-runner-image:dev-chrome -f Dockerfile.chrome \
  --build-arg BASE_IMAGE=gh-runner-image:dev .
```

## Verification

```bash
docker run --rm ghcr.io/sweatstudio75/gh-runner-image:1-base \
  bash -c "node --version && npm --version"
# Expected: v20.x.x and 10.x.x
```
