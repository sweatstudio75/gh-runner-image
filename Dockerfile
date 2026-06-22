# syntax=docker/dockerfile:1.7

FROM myoung34/github-runner:latest

# Purge legacy Node from the Ubuntu base. Ubuntu 20.04 ships nodejs 10 without
# npm; this combo shadows actions/setup-node@v4 and leaves jobs with
# "npm: command not found".
RUN set -eux; \
    apt-get update -qq; \
    apt-get purge -y --auto-remove nodejs npm libnode-dev libnode72 2>/dev/null || true; \
    rm -rf /var/lib/apt/lists/*

# Install Node 24 LTS from NodeSource. Ships node + npm + corepack in /usr/bin.
# Phase 64 v1.8 bump : Node 20 → Node 24 LTS (Active LTS from 2025-10).
# Unlocks the Dependabot artifact PR train (download-artifact v8 + upload-artifact v7
# both require Node 20 minimum on the runner ; v6 was the last to run on Node 16,
# v7/v8 require Node 20+ ; bumping straight to Node 24 LTS aligns the homelab
# runner with the latest Active LTS instead of trailing one major behind).
RUN set -eux; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends curl ca-certificates gnupg; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*; \
    node --version; \
    npm --version; \
    corepack --version

# Sanity: the upstream entrypoint must still be in place.
RUN test -x /entrypoint.sh
