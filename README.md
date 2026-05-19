# gh-runner-image

Custom GitHub Actions self-hosted runner image for [sweatstudio75/sweatstudio](https://github.com/sweatstudio75/sweatstudio).

Built on top of [`myoung34/github-runner`](https://github.com/myoung34/docker-github-actions-runner), with **Node 20 LTS** installed cleanly from NodeSource. Fixes the Ubuntu 20.04 base shipping `nodejs` 10 without `npm`, which shadows `actions/setup-node@v4` downloads.

## Tags published

Two variants on every push to `main` and every `v*.*.*` tag:

| Tag | Contents |
|---|---|
| `ghcr.io/sweatstudio75/gh-runner-image:latest-base` | Runner + Node 20 + npm + corepack |
| `ghcr.io/sweatstudio75/gh-runner-image:latest-chrome` | base + Google Chrome stable (for Lighthouse / Playwright) |

Also tagged with `sha-<short>-{base,chrome}` and SemVer (`vX.Y.Z` → `:X-base`, `:X.Y-base`, `:X.Y.Z-base`).

## Usage

In `install-gh-runner-sweatstudio.sh`:

```bash
docker pull ghcr.io/sweatstudio75/gh-runner-image:latest-base
docker run -d --restart=always --name gh-runner-sweatstudio \
  --env-file /etc/gh-runner-sweatstudio/runner.env \
  -v /tmp/runner-work-sweatstudio:/tmp/runner-work-sweatstudio \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --network host \
  ghcr.io/sweatstudio75/gh-runner-image:latest-base
```

For jobs needing Chrome (Lighthouse, headed Playwright):

```bash
docker pull ghcr.io/sweatstudio75/gh-runner-image:latest-chrome
```

## Local build

```bash
docker build -t gh-runner-image:dev -f Dockerfile .
docker build -t gh-runner-image:dev-chrome -f Dockerfile.chrome \
  --build-arg BASE_IMAGE=gh-runner-image:dev .
```

## Verification

```bash
docker run --rm ghcr.io/sweatstudio75/gh-runner-image:latest-base \
  bash -c "node --version && npm --version"
# Expected: v20.x.x and 10.x.x
```
