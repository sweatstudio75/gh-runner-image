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

## Host Docker IPAM (required — fixes the recurring `invalid IP` CI failure)

The runner mounts the **host** Docker socket (`-v /var/run/docker.sock`) with
`--network host`. There is **no docker-in-docker** — every `docker` /
`supabase db start` a job runs hits the **host** daemon. That daemon must have a
large `default-address-pools`, otherwise leaked `supabase_network_*` networks
exhaust the default pool and the next allocation gets an empty gateway →
`could not parse extra host IP invalid IP`.

`scripts/install.sh` configures this automatically on Docker install (idempotent
merge into `/etc/docker/daemon.json`, restarts docker only if changed). The
reference config is `config/daemon.json` (512 × /24 from `10.200.0.0/16` +
`10.201.0.0/16`, no collision with the homelab `192.168.201.0/24`).

To apply on an already-installed host without re-running the full installer:

```bash
sudo jq '. + {"default-address-pools":[{"base":"10.200.0.0/16","size":24},{"base":"10.201.0.0/16","size":24}]}' \
  /etc/docker/daemon.json | sudo tee /etc/docker/daemon.json.new >/dev/null \
  && sudo mv /etc/docker/daemon.json.new /etc/docker/daemon.json \
  && sudo systemctl restart docker
docker info --format '{{json .DefaultAddressPools}}'   # must show 10.200/10.201
```

## Auto-update (idle-safe, rolling)

Runners bake a hardcoded image tag in their systemd `ExecStart`, so they don't
pick up new releases on their own. `scripts/install-autoupdate.sh` installs a
systemd timer (every 15min, jittered) that polls GHCR for a new digest of the
tracked tag and rolls the runner onto it **without killing a running job**:

- **graceful**: `docker stop --time 600` lets the GitHub runner finish its
  in-flight job before exiting; `--rm` + `Restart=always` relaunches it on the
  freshly-pulled image. No API race. A job is only ever interrupted if it runs
  **longer than the 600s grace** (raise `STOP_GRACE` in
  `/etc/gh-runner-autoupdate.env` if your jobs do). Instances are stopped
  concurrently, so wall time is one grace window, not N.
- **rolling / no capacity-zero**: per-host jitter + a fleet **quorum gate**
  (never the last idle runner standing — needs a PAT; otherwise per-host-safe).
- **rollback-safe**: a failed pull leaves the old (working) image in place.
- **observable**: ntfy on success / failure.

Install on each host (LXC 112 + each desktop), from a checkout of this repo:

```bash
sudo ./scripts/install-autoupdate.sh --instances "1"        # LXC 112 (one runner: id 1)
sudo ./scripts/install-autoupdate.sh --instances "1 2 3 4"  # a desktop running 4 runners
```

`--instances` is the list of systemd template ids (`github-runner@<id>.service` →
container `github-runner-<id>`, the template shipped at
`systemd/github-runner@.service`). The auto-updater targets the `github-runner-<id>`
container name — it does **not** manage the legacy single-runner
`gh-runner-sweatstudio` container from `install.sh`; the deployed fleet uses the
template. The installer prompts silently for the GitHub
PAT (quorum check) and ntfy token. Run one tick on demand with
`sudo /usr/local/bin/gh-runner-autoupdate.sh`; remove with
`sudo ./scripts/install-autoupdate.sh --remove`.
