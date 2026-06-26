#!/usr/bin/env bash
# gh-runner-autoupdate.sh
#
# Rolling, idle-safe auto-update of the self-hosted GitHub Actions runner image.
# Driven by gh-runner-autoupdate.timer (every 15min, jittered) on each host.
#
# Why this exists: runners are baked on a hardcoded image tag in the systemd
# ExecStart (ghcr.io/...:2-chrome). semantic-release publishes a new digest for
# that rolling-major tag on every merge, but nothing pulls it — so runners drift
# (and ship known bugs, like the IPAM corruption, for days). This polls GHCR for
# a new digest and rolls the runner onto it WITHOUT killing a running job.
#
# Design (Gemini Gate 1 reviewed):
#   - graceful: `docker stop --time` lets the GitHub runner finish its current
#     job before exiting. --rm + Restart=always => systemd relaunches on the
#     freshly-pulled image. No job is ever killed mid-flight; no API race.
#   - quorum: never stop a runner if it would leave < MIN_ONLINE idle runners
#     online across the fleet (prevents capacity-zero when every host updates
#     at once). Best-effort — needs a GitHub PAT; degrades to per-host-safe.
#   - rollback: a failed `docker pull` leaves the old image + running container
#     untouched. Idempotent: same digest => no-op.
#   - observable: ntfy on update success and on failure.
#
# Config via /etc/gh-runner-autoupdate.env (see install). Required:
#   REPO, IMAGE, RUNNER_INSTANCES (space-separated systemd instance ids)
# Optional:
#   GH_PAT (quorum check), MIN_ONLINE (default 2), NTFY_URL, NTFY_TOPIC,
#   NTFY_TOKEN, STOP_GRACE (default 600s), AGENT_NAME.

set -euo pipefail

CONF="${GH_RUNNER_AUTOUPDATE_ENV:-/etc/gh-runner-autoupdate.env}"
# shellcheck disable=SC1090
[ -f "${CONF}" ] && . "${CONF}"

REPO="${REPO:?REPO not set}"
IMAGE="${IMAGE:?IMAGE not set}"                  # e.g. ghcr.io/sweatstudio75/gh-runner-image:2-chrome
RUNNER_INSTANCES="${RUNNER_INSTANCES:?RUNNER_INSTANCES not set}"  # e.g. "1" or "1 2 3"
MIN_ONLINE="${MIN_ONLINE:-2}"
STOP_GRACE="${STOP_GRACE:-600}"
AGENT_NAME="${AGENT_NAME:-$(hostname -s)}"
SESSION="${SESSION:-gh-runner-autoupdate}"

log() { printf '%s [autoupdate] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ntfy() {
  # $1 = priority, $2 = title, $3 = markdown body
  [ -n "${NTFY_URL:-}" ] && [ -n "${NTFY_TOPIC:-}" ] || { log "ntfy not configured — skip notify: $2"; return 0; }
  local auth=()
  [ -n "${NTFY_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${NTFY_TOKEN}")
  curl -s -m 10 "${auth[@]}" "${NTFY_URL%/}/" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg t "${NTFY_TOPIC}" --arg ti "$2" \
            --arg m "$3"$'\n'"— ${AGENT_NAME} / ${SESSION}" --argjson p "$1" \
            '{topic:$t, title:$ti, message:$m, priority:$p, markdown:true}')" \
    >/dev/null 2>&1 || log "ntfy POST failed (non-fatal)"
}

# --- remote digest for the tracked tag (anonymous GHCR pull token) -----------
remote_digest() {
  # IMAGE = ghcr.io/<owner>/<name>:<tag>
  local ref="${IMAGE#ghcr.io/}"; local repo="${ref%:*}"; local tag="${ref##*:}"
  local token
  token="$(curl -s -m 10 "https://ghcr.io/token?scope=repository:${repo}:pull" | jq -r '.token // empty')"
  [ -n "${token}" ] || return 1
  curl -s -m 10 -o /dev/null -D - \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.index.v1+json" \
    "https://ghcr.io/v2/${repo}/manifests/${tag}" 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'
}

local_digest() {
  # Repo digest currently pinned to IMAGE locally, if any.
  docker image inspect "${IMAGE}" --format '{{join .RepoDigests "\n"}}' 2>/dev/null \
    | awk -F'@' '{print $2}' | head -1
}

# --- fleet idle quorum (best-effort; needs GH_PAT) ---------------------------
idle_online_count() {
  [ -n "${GH_PAT:-}" ] || { echo "-1"; return 0; }   # unknown -> caller treats as "skip quorum gate"
  curl -s -m 10 -H "Authorization: Bearer ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/actions/runners?per_page=100" 2>/dev/null \
    | jq '[.runners[]? | select(.status=="online" and .busy==false)] | length' 2>/dev/null \
    || echo "-1"
}

main() {
  command -v jq >/dev/null 2>&1 || { log "jq required"; exit 1; }
  command -v docker >/dev/null 2>&1 || { log "docker required"; exit 1; }

  local rd ld
  rd="$(remote_digest || true)"
  [ -n "${rd}" ] || { log "could not resolve remote digest for ${IMAGE} — skip tick"; exit 0; }
  ld="$(local_digest || true)"

  if [ "${rd}" = "${ld}" ]; then
    log "up to date (${rd}) — no-op"
    exit 0
  fi
  log "new image available: local=${ld:-none} remote=${rd}"

  # Pull the new image. Failure => keep old image + running container. Rollback-safe.
  if ! docker pull --quiet "${IMAGE}" >/dev/null 2>&1; then
    log "docker pull failed — staying on ${ld:-current}"
    ntfy 4 "Runner update FAILED ($(hostname -s))" "\`docker pull ${IMAGE}\` failed. Runner stays on old image (functional). Will retry next tick."
    exit 1
  fi
  local newld; newld="$(local_digest || true)"
  log "pulled ${newld}"

  # Quorum gate: don't be the last idle runner standing.
  local idle; idle="$(idle_online_count)"
  if [ "${idle}" != "-1" ] && [ "${idle}" -lt "${MIN_ONLINE}" ]; then
    log "fleet idle-online=${idle} < MIN_ONLINE=${MIN_ONLINE} — deferring restart to keep CI capacity"
    exit 0
  fi

  # Roll each local instance. `docker stop --time` is graceful: the GitHub runner
  # finishes any in-flight job before SIGKILL, then --rm + Restart=always brings
  # it back on the just-pulled image. No job is killed.
  local n cname
  for n in ${RUNNER_INSTANCES}; do
    cname="github-runner-${n}"
    if docker ps --format '{{.Names}}' | grep -qx "${cname}"; then
      log "graceful stop ${cname} (grace=${STOP_GRACE}s, finishes in-flight job)..."
      docker stop --time "${STOP_GRACE}" "${cname}" >/dev/null 2>&1 || log "stop ${cname} returned non-zero (container may have already exited)"
    else
      log "${cname} not running (between jobs) — systemd will pick up new image on next launch"
    fi
  done

  # systemd (Restart=always) relaunches the container on the new image. Give it a beat.
  sleep 5
  docker image prune -f >/dev/null 2>&1 || true   # reclaim the now-dangling old digest

  ntfy 3 "Runner updated ($(hostname -s))" "Image \`${IMAGE}\` rolled.
Old: \`${ld:-none}\`
New: \`${newld}\`
Instances: ${RUNNER_INSTANCES}"
  log "update complete: ${ld:-none} -> ${newld}"
}

# Single-flight: never overlap ticks.
exec 9>/var/lock/gh-runner-autoupdate.lock 2>/dev/null || exec 9>/tmp/gh-runner-autoupdate.lock
flock -n 9 || { log "another tick holds the lock — exit"; exit 0; }

main "$@"
