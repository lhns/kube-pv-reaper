# 0002 — Intercept PV deletion with a finalizer

Status: Accepted

## Context

The clone-on-delete mechanism ([ADR 0001](0001-clone-on-delete-reclamation.md))
has to act *at the moment a managed PV is deleted*, before the PV object is gone
— otherwise the `spec.csi` details needed to build the clone vanish and the
volume leaks silently. A plain watch is not enough: the reaper could miss the
deletion (down, restarting, lagging) and the PV would be removed with its backing
volume orphaned forever.

## Decision

Place a finalizer (`pv-reaper.lhns.de/reclaim-on-delete`, configurable) on every
managed `Retain` PV in steady state. Kubernetes then blocks the PV's actual
removal while the finalizer is present, so a `kubectl delete pv` sets
`deletionTimestamp` and parks the object in `Terminating` until the reaper builds
the clone and removes the finalizer. Finalizer add/remove operations re-read the
live object and retry, so a stale watch object or a concurrent edit can never
wedge a PV.

## Consequences

- **Pro**: The deletion is *guaranteed* to be intercepted — reclamation cannot be
  missed, even across reaper restarts. The PV waits for the reaper rather than
  racing it.
- **Pro**: Data-safe by construction: if the reaper is down, deletions block
  (`Terminating`) rather than losing the volume.
- **Con**: A managed PV cannot be deleted while the reaper is down — it hangs in
  `Terminating` until the reaper comes back.
- **Con**: Uninstalling the reaper without first stripping the finalizer leaves
  managed PVs un-deletable. This is why the README documents a strip loop, and
  why a Helm `pre-delete` hook is a natural future automation.
- **Con**: The finalizer key is part of the tool's public contract — renaming it
  strands finalizers under the old key on existing PVs.
