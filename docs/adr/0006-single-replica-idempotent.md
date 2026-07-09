# 0006 — Single replica + idempotent reconcile instead of leader election

Status: Accepted

## Context

A controller that mutates cluster state usually needs to avoid two instances
acting at once. The heavyweight answer is leader election. But the reaper's
operations are naturally idempotent — adding a finalizer that's already present
is a no-op, and a clone is created only if one of that name doesn't already exist
(`DeleteVolume` is idempotent regardless).

## Decision

Run a single replica (`replicas: 1`) with a `Recreate` deployment strategy, and
rely on per-PV idempotent reconciliation rather than leader election. `Recreate`
ensures the old pod is gone before the new one starts, so a rollout never briefly
runs two reapers; idempotency makes even an accidental overlap harmless.

## Consequences

- **Pro**: No leader-election machinery — the simplest possible design for a
  low-frequency, idempotent workload.
- **Pro**: Even if two instances ever overlapped, the finalizer-add and
  clone-create guards keep it safe.
- **Con**: No active/standby — during a restart there is a brief window with no
  reaper. This is acceptable because the finalizer parks PV deletions until the
  reaper returns ([ADR 0002](0002-finalizer-interception.md)), so nothing is
  lost.
- **Con**: Not horizontally scalable, but the workload (a few operations per PV
  lifecycle event) never needs it.
