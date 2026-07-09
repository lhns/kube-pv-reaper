# 0007 — Distribution: multi-arch image + Helm chart to GHCR, CHANGELOG-driven releases

Status: Accepted

## Context

The tool is consumed as a container image and deployed with Helm (directly or via
Flux). It needs to run on both amd64 and arm64 nodes, and consumers need a
predictable versioning scheme distinguishing bleeding-edge `main` builds from
stable releases.

## Decision

GitHub Actions builds a multi-arch (amd64/arm64) image and packages the Helm
chart, both published to GHCR under `ghcr.io/lhns/…`. Versioning:

- Push to `main` → dev build: image `:sha-<short>`, chart `0.0.0-sha-<short>`.
- Tag `vX.Y.Z` → release: image `:X.Y.Z` + `:latest`, chart `X.Y.Z`, plus a
  GitHub Release whose notes are extracted from the matching `CHANGELOG.md`
  section.

## Consequences

- **Pro**: Runs on mixed-arch clusters; every `main` commit is installable for
  testing without cutting a release.
- **Pro**: Release notes have a single source of truth (`CHANGELOG.md`), so they
  can't drift from the tag.
- **Con**: `CHANGELOG.md` must be kept current or release notes are thin — the
  release job depends on the per-version section existing.
- **Con**: GHCR-only distribution; no other registry or a classic Helm HTTP repo.
