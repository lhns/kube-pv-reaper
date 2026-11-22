# 0010 — Signed releases; dev builds from every branch

Status: Accepted. Supersedes the dev-build versioning in [0007](0007-distribution-image-and-chart.md).

## Context

The release workflow moves to the build and release shape shared with the sibling operators
(`kube-vnet`, `kube-oci-composer`, `kube-ha-surge`, `kube-traefik-reflector`). Releases were not
signed. The repository, image and chart are public, so keyless signing leaks nothing. Nothing
verifies dev builds.

## Decision

- A `vX.Y.Z` tag signs the image digest and the chart digest with cosign keyless (GitHub OIDC) and
  attests an SPDX image SBOM. `id-token: write` is granted to the `release` job only.
- Every push to a non-Dependabot branch publishes a dev build, not only `main`: image
  `0.0.0-dev.g<sha7>`, `sha-<sha7>` and the branch name; chart `0.0.0-dev.g<sha7>` (was
  `0.0.0-sha-<short>`). The `g` keeps an all-digit sha with a leading zero valid semver.
- Dev builds are not signed; their SBOM is still generated, so that step stays exercised.

## Consequences

- **Pro**: Releases are verifiable against the workflow identity, with no key to store or rotate.
- **Pro**: Any branch is installable for testing, the same way as in the sibling repos.
- **Con**: Dev builds cannot be verified, and pinned `0.0.0-sha-*` dev charts are not produced any more.
