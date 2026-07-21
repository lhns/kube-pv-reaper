# 0009 — Manage only dynamically-provisioned volumes (skip static PVs)

Status: Accepted

## Context

The reaper reclaims a volume by cloning its PV into a throwaway `Delete` PV so the
CSI external-provisioner runs `DeleteVolume` on the shared `volumeHandle` (ADR
0001). That only works for volumes the provisioner **created**.

A *static* (pre-provisioned) PV is different: an admin authored it to expose
storage that already exists — a CephFS subtree, an existing RBD image, an NFS
export — and its `volumeHandle` is an admin-chosen identifier, not a
provisioner-owned ID. Cloning such a PV to `Delete` makes the provisioner attempt
`DeleteVolume` on that handle, which either **fails** (e.g. ceph-csi rejects it
with `failed to decode CSI identifier, string underflow`, leaving the clone stuck
`Released` and emitting recurring `VolumeFailedDelete` warnings) or, for a driver
that *could* parse it, **destroys shared data** the PV was only borrowing. Neither
is acceptable, and the reaper adding its finalizer to static PVs also means their
own deletion can wedge on the doomed clone.

Originally the reaper managed every CSI PV with `reclaimPolicy: Retain`, making no
distinction — so static PVs were swept in.

## Decision

Manage a PV **only if it was dynamically provisioned**, detected by the standard
`pv.kubernetes.io/provisioned-by` annotation the external-provisioner stamps on
every volume it creates. Static / pre-provisioned PVs never carry it and are
skipped entirely:

- **Steady state**: only add the finalizer to a dynamically-provisioned `Retain`
  PV. If a static PV is found carrying the finalizer (e.g. added by a pre-0.1.5
  build), **strip it** so the PV self-heals.
- **On delete**: a static PV that still has the finalizer is released **without**
  cloning — its native `Retain` delete then touches no backend storage.

`provisioned-by` is chosen over driver-specific markers (e.g. ceph-csi's
`volumeAttributes.staticVolume: "true"`) because the reaper is driver-agnostic:
the annotation is the one universal signal, and it exactly matches the set of
volumes the provisioner's own `DeleteVolume` can act on — the same mechanism the
reclaim depends on.

## Consequences

- **Pro**: The reaper never issues a doomed or destructive `DeleteVolume` for a
  static volume; the `string underflow` reclaim loop and its `VolumeFailedDelete`
  warnings cannot occur.
- **Pro**: Driver-agnostic — no per-driver static-volume heuristics.
- **Pro**: Self-healing — stray finalizers left on static PVs by older builds are
  removed automatically.
- **Con**: An operator who deliberately wants the reaper to reclaim a *static*
  volume's backend cannot; that is intentional — it is not the provisioner's
  volume to delete.
- **Con**: Relies on the provisioner having set `provisioned-by`; a dynamically
  provisioned PV with that annotation manually stripped would be treated as
  static (an unrealistic edge case).
