# 0003 — POSIX shell + `kubectl`/`jq` watch loop, not a client-go controller

Status: Accepted

## Context

The entire behavior is: watch PVs, and for each one either add a finalizer
(steady state) or create a clone and drop the finalizer (on deletion). That is a
handful of `get`/`patch`/`create` calls plus some JSON reshaping — no CRDs, no
complex reconciliation graph, no typed API of its own.

A full Go + controller-runtime controller (as used in the sibling kube-vnet
project) would bring a build toolchain, a module graph, and a typed client to
bear on a problem that is essentially "watch a stream and run a few kubectl
commands."

## Decision

Implement the reaper as a single POSIX `sh` script driving `kubectl` and `jq`,
shipped in an `alpine` image with just those two tools plus `ca-certificates`.
PVs are consumed from `kubectl get pv --watch --output-watch-events=true -o json`
(which emits every existing PV as `ADDED` first, then streams changes), unwrapped
with `jq`, and reconciled one at a time. In-cluster auth is the mounted
ServiceAccount token that `kubectl` picks up automatically; the container runs as
`65534:65534` and writes nothing locally.

## Consequences

- **Pro**: Tiny and transparent — the whole controller is one auditable script;
  no compiler, no dependency graph, no generated code.
- **Pro**: Uses the same API-server contract client-go would, via kubectl, with
  automatic in-cluster config.
- **Con**: No typed client or informer cache; watch reconnect, retries, and
  idempotency are hand-rolled in shell.
- **Con**: The image depends on pinned `kubectl` + `jq`; a kubectl output-format
  change could bite. Shell-as-PID-1 has signal-handling sharp edges (see
  [ADR 0004](0004-pid1-signal-handling.md)).
- **Con**: Less ergonomic to extend than Go if the scope ever grows beyond "a few
  calls per PV."
