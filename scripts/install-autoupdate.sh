#!/usr/bin/env bash
# install-autoupdate.sh
#
# Install the runner image auto-update timer on THIS host. Idempotent.
# Run once per host (LXC 112 + each desktop). Linux + systemd only.
#
# Usage:
#   sudo ./install-autoupdate.sh \
#     --instances "1" \
#     [--image ghcr.io/sweatstudio75/gh-runner-image:2-chrome] \
#     [--repo sweatstudio75/sweatstudio] \
#     [--min-online 2]
#   sudo ./install-autoupdate.sh --remove
#   ./install-autoupdate.sh --run        # run one tick now (dry of timer)
#
# Secrets (GH_PAT for the quorum check, NTFY_TOKEN) are prompted silently and
# written to /etc/gh-runner-autoupdate.env (root:root 600) — never passed as args.
# GH_PAT is optional: without it the quorum gate is skipped (per-host graceful
# stop still protects in-flight jobs; only the cross-fleet capacity-zero guard
# is disabled). Reuse the same fine-grained PAT (metadata:read) the runner uses.

set -euo pipefail

REPO_DEFAULT="sweatstudio75/sweatstudio"
IMAGE_DEFAULT="ghcr.io/sweatstudio75/gh-runner-image:2-chrome"
ENV_FILE="/etc/gh-runner-autoupdate.env"
SCRIPT_DST="/usr/local/bin/gh-runner-autoupdate.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # repo root (scripts/ -> ..)

color() { printf "\033[%sm%s\033[0m\n" "$1" "$2"; }
info()  { color "1;34" "[INFO] $*"; }
ok()    { color "1;32" "[ OK ] $*"; }
warn()  { color "1;33" "[WARN] $*"; }
fail()  { color "1;31" "[FAIL] $*" >&2; exit 1; }

remove() {
  info "Removing auto-update timer..."
  sudo systemctl disable --now gh-runner-autoupdate.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/gh-runner-autoupdate.timer \
             /etc/systemd/system/gh-runner-autoupdate.service \
             "${SCRIPT_DST}" "${ENV_FILE}"
  sudo systemctl daemon-reload
  ok "Auto-update removed."
}

run_once() {
  [ -f "${ENV_FILE}" ] || fail "Not installed (${ENV_FILE} missing)."
  sudo GH_RUNNER_AUTOUPDATE_ENV="${ENV_FILE}" "${SCRIPT_DST}"
}

install() {
  local instances="" image="${IMAGE_DEFAULT}" repo="${REPO_DEFAULT}" min_online="2"
  while [ $# -gt 0 ]; do
    case "$1" in
      --instances)  instances="$2"; shift 2 ;;
      --image)      image="$2";     shift 2 ;;
      --repo)       repo="$2";      shift 2 ;;
      --min-online) min_online="$2"; shift 2 ;;
      *) fail "Unknown arg: $1" ;;
    esac
  done
  [ -n "${instances}" ] || fail "--instances required (e.g. --instances \"1\" or \"1 2 3\")."
  command -v jq >/dev/null 2>&1 || fail "jq required (apt-get install -y jq)."
  command -v docker >/dev/null 2>&1 || fail "docker required."

  info "Installing auto-update for instances [${instances}] tracking ${image}"

  # Secrets (silent).
  local gh_pat ntfy_token
  read -srp "GitHub PAT for fleet quorum check (Enter to skip): " gh_pat; echo
  read -srp "ntfy Bearer token (Enter to skip notifications): " ntfy_token; echo

  sudo install -m 755 "${HERE}/scripts/gh-runner-autoupdate.sh" "${SCRIPT_DST}"
  sudo install -m 644 "${HERE}/systemd/gh-runner-autoupdate.service" /etc/systemd/system/gh-runner-autoupdate.service
  sudo install -m 644 "${HERE}/systemd/gh-runner-autoupdate.timer"   /etc/systemd/system/gh-runner-autoupdate.timer

  info "Writing ${ENV_FILE} (root:root 600)..."
  sudo tee "${ENV_FILE}" >/dev/null <<EOF
REPO=${repo}
IMAGE=${image}
RUNNER_INSTANCES=${instances}
MIN_ONLINE=${min_online}
STOP_GRACE=600
GH_PAT=${gh_pat}
NTFY_URL=https://ntfy.jnsfr.com
NTFY_TOPIC=homelab
NTFY_TOKEN=${ntfy_token}
AGENT_NAME=$(hostname -s)
SESSION=gh-runner-autoupdate
EOF
  sudo chmod 600 "${ENV_FILE}"

  sudo systemctl daemon-reload
  sudo systemctl enable --now gh-runner-autoupdate.timer
  ok "Timer enabled."
  systemctl list-timers gh-runner-autoupdate.timer --no-pager 2>/dev/null || true
  echo
  info "Run one tick now to verify: sudo ${SCRIPT_DST}"
}

case "${1:-install}" in
  --remove|remove) remove ;;
  --run|run)       run_once ;;
  -h|--help|help)  head -24 "$0" | grep -E "^#" ;;
  install)         shift || true; install "$@" ;;
  --instances|--image|--repo|--min-online) install "$@" ;;
  *) fail "Unknown command: $1" ;;
esac
