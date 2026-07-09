# Architecture Decision Records

Each ADR captures a single decision: the context, what was decided, and the
consequences. ADRs are immutable once accepted — if a decision is reversed, a new
ADR supersedes the old one.

These were reconstructed from the project's commit history and the shipped code;
they record the *why* behind decisions the [README](../../README.md) only
describes operationally.

## Index

1. [0001 — Clone-on-delete: never mutate the original PV to `Delete`](0001-clone-on-delete-reclamation.md)
2. [0002 — Intercept PV deletion with a finalizer](0002-finalizer-interception.md)
3. [0003 — POSIX shell + `kubectl`/`jq` watch loop, not a client-go controller](0003-shell-kubectl-watch-loop.md)
4. [0004 — Graceful shutdown as PID 1 (trap + backgrounded watch + `wait`)](0004-pid1-signal-handling.md)
5. [0005 — Driver scoping via a comma-separated list (empty = all CSI)](0005-driver-scoping-list.md)
6. [0006 — Single replica + idempotent reconcile instead of leader election](0006-single-replica-idempotent.md)
7. [0007 — Distribution: multi-arch image + Helm chart to GHCR, CHANGELOG-driven releases](0007-distribution-image-and-chart.md)
