## [2.1.0](https://github.com/sweatstudio75/gh-runner-image/compare/v2.0.0...v2.1.0) (2026-06-29)

### Features

* **ci:** idle-safe rolling auto-update for the runner image ([7827a0f](https://github.com/sweatstudio75/gh-runner-image/commit/7827a0ff19a65fc28eb79c9e2b962005581f49c2))

### Bug Fixes

* **docker:** configure host daemon default-address-pools to stop IPAM exhaustion ([e576b70](https://github.com/sweatstudio75/gh-runner-image/commit/e576b701ca8ce04cb35b3ecc03ca61cd95a5d894))

## [2.0.0](https://github.com/sweatstudio75/gh-runner-image/compare/v1.3.0...v2.0.0) (2026-06-22)

### ⚠ BREAKING CHANGES

* The baked Node runtime is now Node 24 LTS, not Node 20.
Any job that pinned to `actions/setup-node@v4 with node-version: 20` will
override the baked runtime ; jobs that rely on the system Node (no
`setup-node` step) now get Node 24. v1.x tags remain available for
rollback (no removal — just no longer the recommended series).

Refs: phase 64 RUNNER-01

### Features

* bump baseline Node 20 → Node 24 LTS ([2a086f5](https://github.com/sweatstudio75/gh-runner-image/commit/2a086f567f56eda7f14bddea686fd21a7b98a278)), closes [#241](https://github.com/sweatstudio75/gh-runner-image/issues/241) [#242](https://github.com/sweatstudio75/gh-runner-image/issues/242)

## [1.3.0](https://github.com/sweatstudio75/gh-runner-image/compare/v1.2.0...v1.3.0) (2026-05-21)

### Features

* bake CI toolchain (Python 3.12, Deno, Supabase CLI, psql) ([a12d166](https://github.com/sweatstudio75/gh-runner-image/commit/a12d166d694cfb389db37b3dcc6f347f5fb66340))

## [1.2.0](https://github.com/sweatstudio75/gh-runner-image/compare/v1.1.0...v1.2.0) (2026-05-21)

### Features

* bake Playwright browsers into the chrome image ([1d3be00](https://github.com/sweatstudio75/gh-runner-image/commit/1d3be00dbf8944a708f964e1bf0be4ef1c25fc10))

## [1.1.0](https://github.com/sweatstudio75/gh-runner-image/compare/v1.0.0...v1.1.0) (2026-05-19)

### Features

* add scripts/install.sh + curl-install for new hosts ([487e53e](https://github.com/sweatstudio75/gh-runner-image/commit/487e53e29736675ffaeae262f836eacd3248e61a))

## 1.0.0 (2026-05-19)

### Features

* tag-triggered builds with semantic-release versioning ([02cbfd4](https://github.com/sweatstudio75/gh-runner-image/commit/02cbfd449d951014f6ee7491bb13a1368bea9942))

# Changelog

All notable changes to this project will be documented automatically by [semantic-release](https://github.com/semantic-release/semantic-release).
