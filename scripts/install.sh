#!/usr/bin/env bash
# install-gh-runner-sweatstudio.sh
#
# Install a self-hosted GitHub Actions runner for sweatstudio75/sweatstudio
# on this machine. Idempotent. Tested Linux x64 + macOS arm64.
#
# Usage:
#   chmod +x install-gh-runner-sweatstudio.sh
#   ./install-gh-runner-sweatstudio.sh           # interactive install
#   ./install-gh-runner-sweatstudio.sh --status  # check current state
#   ./install-gh-runner-sweatstudio.sh --remove  # decommission
#
# Required:
#   - Docker installed and running (auto-fallback to bare-metal if absent)
#   - A GitHub PAT with `repo` scope OR fine-grained PAT scoped to
#     sweatstudio75/sweatstudio with `actions:write + metadata:read`
#   - Outbound HTTPS access (no inbound port needed)

set -euo pipefail

REPO="sweatstudio75/sweatstudio"
REPO_URL="https://github.com/${REPO}"
RUNNER_NAME_DEFAULT="gh-runner-$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
WORK_DIR="${HOME}/.gh-runner-sweatstudio"
ETC_DIR="/etc/gh-runner-sweatstudio"
# Rolling major tag: stays within v1.x (gets patches + minor bumps, never v2.x).
# Override at invocation time: GH_RUNNER_IMAGE_TAG=1.0.0 ./install.sh
DOCKER_IMAGE_BASE="ghcr.io/sweatstudio75/gh-runner-image:${GH_RUNNER_IMAGE_TAG:-1}-base"
DOCKER_IMAGE_CHROME="ghcr.io/sweatstudio75/gh-runner-image:${GH_RUNNER_IMAGE_TAG:-1}-chrome"
ENV_FILE="${ETC_DIR}/runner.env"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

color() { printf "\033[%sm%s\033[0m\n" "$1" "$2"; }
info()  { color "1;34" "[INFO] $*"; }
ok()    { color "1;32" "[ OK ] $*"; }
warn()  { color "1;33" "[WARN] $*"; }
fail()  { color "1;31" "[FAIL] $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

detect_os() {
  case "$(uname -s)" in
    Linux)  echo "linux"  ;;
    Darwin) echo "macos"  ;;
    *)      fail "Unsupported OS: $(uname -s). Linux or macOS only." ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "x64"   ;;
    aarch64|arm64) echo "arm64" ;;
    *)             fail "Unsupported arch: $(uname -m)." ;;
  esac
}

# -----------------------------------------------------------------------------
# Status mode
# -----------------------------------------------------------------------------

status() {
  info "Status check for runner at ${REPO}..."

  # Resolve env file location per OS
  local os env_file
  os="$(detect_os)"
  if [ "${os}" = "linux" ]; then
    env_file="${ETC_DIR}/runner.env"
  else
    env_file="${WORK_DIR}/runner.env"
  fi

  local sudo_maybe=""
  [ "${os}" = "linux" ] && sudo_maybe="sudo"

  if ! ${sudo_maybe} test -f "${env_file}"; then
    warn "No runner installed (no env file at ${env_file})."
    return
  fi

  local runner_name
  runner_name="$(${sudo_maybe} grep '^RUNNER_NAME=' "${env_file}" 2>/dev/null | cut -d= -f2)"
  info "Configured runner name: ${runner_name}"

  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^gh-runner-sweatstudio$"; then
    ok "Docker container 'gh-runner-sweatstudio' is running."
    docker logs --tail 5 gh-runner-sweatstudio 2>/dev/null || true
  else
    warn "Docker container 'gh-runner-sweatstudio' is NOT running."
  fi

  echo
  info "View status on GitHub:"
  echo "  https://github.com/${REPO}/settings/actions/runners"
}

# -----------------------------------------------------------------------------
# Remove mode
# -----------------------------------------------------------------------------

remove() {
  info "Decommissioning runner..."

  # Stop systemd service if present
  if [ -f /etc/systemd/system/gh-runner-sweatstudio.service ]; then
    info "Removing systemd service..."
    sudo systemctl disable --now gh-runner-sweatstudio.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/gh-runner-sweatstudio.service
    sudo systemctl daemon-reload
  fi

  # Stop launchd plist if present (macOS)
  local plist="${HOME}/Library/LaunchAgents/com.sweatstudio.gh-runner.plist"
  if [ -f "${plist}" ]; then
    info "Removing launchd agent..."
    launchctl unload "${plist}" 2>/dev/null || true
    rm -f "${plist}"
  fi

  # Force-remove container
  if command -v docker >/dev/null 2>&1; then
    docker rm -f gh-runner-sweatstudio 2>/dev/null || true
  fi

  # Clean workdir (build artifacts in HOME)
  if [ -d "${WORK_DIR}" ]; then
    info "Wiping ${WORK_DIR}..."
    rm -rf "${WORK_DIR}"
  fi

  # Clean /etc config dir (env file + PAT)
  if [ -d "${ETC_DIR}" ]; then
    info "Wiping ${ETC_DIR}..."
    sudo rm -rf "${ETC_DIR}"
  fi

  ok "Runner removed. Manual cleanup remaining: delete the runner entry at"
  echo "  https://github.com/${REPO}/settings/actions/runners"
}

# -----------------------------------------------------------------------------
# Install
# -----------------------------------------------------------------------------

install() {
  local os arch runner_name pat_value with_chrome
  os="$(detect_os)"
  arch="$(detect_arch)"
  info "Detected: ${os} / ${arch}"

  # 0. Prereq checks
  need_cmd curl
  need_cmd grep
  need_cmd sed

  local use_docker="false"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    use_docker="true"
    ok "Docker detected — using Docker isolated mode (recommended)."
  else
    warn "Docker not available. Falling back to bare-metal install."
    warn "Note: bare-metal runs jobs as your current user. Make sure you trust"
    warn "the contributor list of ${REPO}."
    read -rp "Continue with bare-metal? [y/N] " yn
    [ "${yn,,}" = "y" ] || fail "Aborted."
  fi

  # 1. Prompt for PAT (silent input, NEVER in args)
  echo
  info "Enter your GitHub PAT (won't echo)."
  info "Generate one at: https://github.com/settings/personal-access-tokens"
  info "Required scope: repo OR fine-grained on ${REPO} with actions:write + metadata:read"
  read -srp "PAT: " pat_value
  echo
  [ -z "${pat_value}" ] && fail "PAT cannot be empty."

  # 2. Verify PAT
  info "Verifying PAT against GitHub API..."
  local who
  who=$(curl -s -H "Authorization: Bearer ${pat_value}" -H "Accept: application/vnd.github+json" \
        https://api.github.com/user | grep -m1 '"login"' | sed 's/.*"login":[[:space:]]*"\([^"]*\)".*/\1/' || true)
  [ -z "${who}" ] && fail "PAT seems invalid. /user endpoint did not return a login."
  ok "Authenticated as: ${who}"

  # 3. Verify PAT has repo access
  local repo_check
  repo_check=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${pat_value}" \
               -H "Accept: application/vnd.github+json" \
               "https://api.github.com/repos/${REPO}")
  [ "${repo_check}" = "200" ] || fail "PAT cannot access ${REPO} (HTTP ${repo_check}). Check scope."
  ok "PAT has access to ${REPO}."

  # 4. Runner name
  echo
  read -rp "Runner name [${RUNNER_NAME_DEFAULT}]: " runner_name
  runner_name="${runner_name:-${RUNNER_NAME_DEFAULT}}"

  # 5. Chrome support? (only relevant for Docker mode)
  with_chrome="false"
  if [ "${use_docker}" = "true" ]; then
    read -rp "Use Chrome variant (ghcr.io/...:latest-chrome) for Lighthouse jobs? [y/N] " yn
    if [ "${yn,,}" = "y" ]; then
      with_chrome="true"
    fi
  fi

  mkdir -p "${WORK_DIR}"

  # 6. Setup
  if [ "${use_docker}" = "true" ]; then
    install_docker "${runner_name}" "${pat_value}" "${os}" "${arch}" "${with_chrome}"
  else
    install_baremetal "${runner_name}" "${pat_value}" "${os}" "${arch}"
  fi

  echo
  ok "Installation complete."
  echo
  info "Verify the runner is online at:"
  echo "  ${REPO_URL}/settings/actions/runners"
  echo
  info "Tail logs with:"
  if [ "${use_docker}" = "true" ]; then
    echo "  docker logs -f gh-runner-sweatstudio"
  else
    echo "  ${WORK_DIR}/_diag/Runner_*.log"
  fi
}

# -----------------------------------------------------------------------------
# Docker install
# -----------------------------------------------------------------------------

install_docker() {
  local runner_name="$1" pat_value="$2" os="$3" arch="$4" with_chrome="$5"

  # OS-specific env file location:
  # - Linux: /etc/gh-runner-sweatstudio/ (root:root 600, read by systemd)
  # - macOS: WORK_DIR (user-level, read by launchd LaunchAgent)
  if [ "${os}" = "linux" ]; then
    ENV_FILE="${ETC_DIR}/runner.env"
  else
    ENV_FILE="${WORK_DIR}/runner.env"
  fi

  # OS-specific labels
  local labels
  case "${os}/${arch}" in
    linux/x64)   labels="self-hosted,Linux,X64,sweatstudio-pc" ;;
    linux/arm64) labels="self-hosted,Linux,ARM64,sweatstudio-pc" ;;
    macos/x64)   labels="self-hosted,macOS,X64,sweatstudio-pc" ;;
    macos/arm64) labels="self-hosted,macOS,ARM64,sweatstudio-pc" ;;
  esac

  # Select pre-built image from ghcr.io (see sweatstudio75/gh-runner-image).
  local image
  if [ "${with_chrome}" = "true" ]; then
    image="${DOCKER_IMAGE_CHROME}"
  else
    image="${DOCKER_IMAGE_BASE}"
  fi
  info "Pulling ${image}..."
  docker pull "${image}"

  # Write env file (mode 600). Linux -> /etc root:root, macOS -> WORK_DIR user-level.
  info "Writing env file to ${ENV_FILE} (mode 600)..."
  if [ "${os}" = "linux" ]; then
    sudo install -d -m 700 -o root -g root "${ETC_DIR}"
    sudo tee "${ENV_FILE}" > /dev/null <<EOF
REPO_URL=${REPO_URL}
ACCESS_TOKEN=${pat_value}
RUNNER_NAME=${runner_name}
RUNNER_SCOPE=repo
LABELS=${labels}
EPHEMERAL=true
DISABLE_AUTO_UPDATE=true
RUNNER_WORKDIR=/tmp/runner-work-sweatstudio
EOF
    sudo chown root:root "${ENV_FILE}"
    sudo chmod 600 "${ENV_FILE}"
  else
    cat > "${ENV_FILE}" <<EOF
REPO_URL=${REPO_URL}
ACCESS_TOKEN=${pat_value}
RUNNER_NAME=${runner_name}
RUNNER_SCOPE=repo
LABELS=${labels}
EPHEMERAL=true
DISABLE_AUTO_UPDATE=true
RUNNER_WORKDIR=/tmp/runner-work-sweatstudio
EOF
    chmod 600 "${ENV_FILE}"
  fi

  # Stop any existing container
  docker rm -f gh-runner-sweatstudio 2>/dev/null || true

  # Setup systemd (Linux) or launchd (macOS) or just docker run (fallback)
  if [ "${os}" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
    install_systemd "${image}"
  elif [ "${os}" = "macos" ]; then
    install_launchd "${image}"
  else
    info "No init system available — running container in detached mode."
    docker run -d --restart=always --name gh-runner-sweatstudio \
      --env-file "${ENV_FILE}" \
      -v "/tmp/runner-work-sweatstudio:/tmp/runner-work-sweatstudio" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      --network host \
      "${image}"
  fi
}

install_systemd() {
  local image="$1"
  info "Installing systemd unit (sudo required)..."

  sudo tee /etc/systemd/system/gh-runner-sweatstudio.service > /dev/null <<EOF
[Unit]
Description=GitHub Actions Runner (ephemeral) for ${REPO}
Wants=network-online.target docker.service
After=network-online.target docker.service
Requires=docker.service
StartLimitIntervalSec=600
StartLimitBurst=20

[Service]
Type=simple
Restart=always
RestartSec=5s
TimeoutStopSec=60

ExecStartPre=-/usr/bin/docker rm -f gh-runner-sweatstudio
ExecStart=/usr/bin/docker run --rm \\
  --name gh-runner-sweatstudio \\
  --network host \\
  --env-file ${ENV_FILE} \\
  -v /tmp/runner-work-sweatstudio:/tmp/runner-work-sweatstudio \\
  -v /var/run/docker.sock:/var/run/docker.sock \\
  ${image}
ExecStop=-/usr/bin/docker stop -t 30 gh-runner-sweatstudio

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now gh-runner-sweatstudio.service
  sleep 4
  sudo systemctl status gh-runner-sweatstudio.service --no-pager -l | head -15 || true
}

install_launchd() {
  local image="$1"
  info "Installing launchd plist..."

  local plist="${HOME}/Library/LaunchAgents/com.sweatstudio.gh-runner.plist"
  local docker_bin
  docker_bin="$(command -v docker || echo /usr/local/bin/docker)"
  mkdir -p "${HOME}/Library/LaunchAgents"

  cat > "${plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.sweatstudio.gh-runner</string>
  <key>ProgramArguments</key>
  <array>
    <string>${docker_bin}</string>
    <string>run</string><string>--rm</string>
    <string>--name</string><string>gh-runner-sweatstudio</string>
    <string>--env-file</string><string>${ENV_FILE}</string>
    <string>-v</string><string>/tmp/runner-work-sweatstudio:/tmp/runner-work-sweatstudio</string>
    <string>-v</string><string>/var/run/docker.sock:/var/run/docker.sock</string>
    <string>${image}</string>
  </array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${WORK_DIR}/runner.log</string>
  <key>StandardErrorPath</key><string>${WORK_DIR}/runner.err</string>
</dict>
</plist>
EOF

  launchctl unload "${plist}" 2>/dev/null || true
  launchctl load "${plist}"
  sleep 4
  launchctl list | grep com.sweatstudio || warn "launchctl list did not show the agent."
}

# -----------------------------------------------------------------------------
# Bare-metal install
# -----------------------------------------------------------------------------

install_baremetal() {
  local runner_name="$1" pat_value="$2" os="$3" arch="$4"

  local pkg_os
  case "${os}" in
    linux) pkg_os="linux" ;;
    macos) pkg_os="osx"   ;;
  esac
  local pkg_arch="${arch}"

  info "Fetching latest runner version..."
  local runner_version
  runner_version=$(curl -s https://api.github.com/repos/actions/runner/releases/latest \
                   | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')
  [ -z "${runner_version}" ] && fail "Could not detect latest runner version."
  ok "Latest runner version: ${runner_version}"

  mkdir -p "${WORK_DIR}"
  cd "${WORK_DIR}"

  if [ ! -f "config.sh" ]; then
    local url="https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-${pkg_os}-${pkg_arch}-${runner_version}.tar.gz"
    info "Downloading ${url}..."
    curl -fsSL -o runner.tar.gz "${url}"
    tar xzf runner.tar.gz
    rm runner.tar.gz
  fi

  info "Getting registration token..."
  local reg_token
  reg_token=$(curl -s -X POST -H "Authorization: Bearer ${pat_value}" \
              -H "Accept: application/vnd.github+json" \
              "https://api.github.com/repos/${REPO}/actions/runners/registration-token" \
              | grep '"token"' | sed 's/.*"token":[[:space:]]*"\([^"]*\)".*/\1/')
  [ -z "${reg_token}" ] && fail "Could not get registration token."

  local labels
  case "${os}/${arch}" in
    linux/x64)   labels="self-hosted,Linux,X64,sweatstudio-pc" ;;
    linux/arm64) labels="self-hosted,Linux,ARM64,sweatstudio-pc" ;;
    macos/x64)   labels="self-hosted,macOS,X64,sweatstudio-pc" ;;
    macos/arm64) labels="self-hosted,macOS,ARM64,sweatstudio-pc" ;;
  esac

  info "Configuring runner..."
  ./config.sh --url "${REPO_URL}" --token "${reg_token}" \
              --name "${runner_name}" --labels "${labels}" \
              --ephemeral --unattended --replace

  if [ "${os}" = "linux" ]; then
    info "Installing service (sudo)..."
    sudo ./svc.sh install "$(whoami)"
    sudo ./svc.sh start
    sudo ./svc.sh status
  else
    info "Starting runner manually in screen/tmux is recommended on macOS bare-metal."
    info "Run: cd ${WORK_DIR} && ./run.sh"
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

case "${1:-install}" in
  install)
    install
    ;;
  --status|status)
    status
    ;;
  --remove|remove|--uninstall|uninstall|--decommission|decommission)
    remove
    ;;
  -h|--help|help)
    head -30 "$0" | grep -E "^#"
    ;;
  *)
    fail "Unknown command: $1. Use install | status | remove"
    ;;
esac
