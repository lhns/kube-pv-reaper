# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.2] - 2026-07-08
### Fixed
- Chart: the fullname template now honors `fullnameOverride`/`nameOverride` and
  de-dupes when the release name already contains the chart name, matching the
  standard Helm convention. Previously it blindly produced
  `<release>-kube-pv-reaper` (e.g. the stuttering `pv-reaper-kube-pv-reaper`);
  set `fullnameOverride: pv-reaper` for a clean `pv-reaper`.

## [0.1.1] - 2026-07-08
### Fixed
- Handle `SIGTERM`/`SIGINT` promptly. The watch loop now runs as a backgrounded
  job with `wait` plus a `trap`, so the container no longer ignores `SIGTERM`
  and hang until `SIGKILL` on every drain/rollout (a plain foreground loop as
  PID 1 has no default signal disposition).

### Added
- CI test (`test.yml`) that builds the image and asserts prompt `SIGTERM`
  handling using a blocking fake `kubectl` (reproduces the stuck-in-watch case).

## [0.1.0] - 2026-07-07
### Added
- Initial release. Clone-on-delete reclaimer for CSI PersistentVolumes: deleting
  a PVC keeps the volume (reclaimPolicy `Retain`), deleting the PV reclaims it by
  cloning the PV into a disposable `Delete`-policy PV that shares the
  `volumeHandle`, so reclamation is race-free and decoupled from the original.
- Event-driven (`kubectl get pv --watch`), no polling; finalizer edits re-read
  and retry so a PV can't get stuck `Terminating`.
- Configurable `driver` (empty = all CSI drivers), `finalizer`, `clonePrefix`.
- Multi-arch (amd64/arm64) image and Helm chart published to GHCR.
