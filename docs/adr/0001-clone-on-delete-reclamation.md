# 0001 — Clone-on-delete: never mutate the original PV to `Delete`

Status: Accepted

## Context

Kubernetes exposes a single `persistentVolumeReclaimPolicy` per PV, and it
conflates two distinct lifecycle transitions:

- deleting the **PVC** (the workload releases the volume), and
- deleting the **PV** (an operator decides the storage should actually go away).

`Retain` keeps the backing volume on *both*; `Delete` destroys it on *both*.
There is no built-in "keep the data when the claim goes, but reclaim it when I
delete the PV" — which is exactly the behavior we want: a `Released` PV should be
an explicit tombstone you delete when, and only when, you want the storage gone.

The obvious implementation — flip a `Retain` PV to `Delete` at deletion time — is
racy and fragile: the PV is already being torn down, the provisioner may or may
not observe the policy change before the object is gone, and a half-applied
change can leak or wrongly destroy a volume.

## Decision

Never change the original PV's reclaim policy. A CSI volume is identified by
`spec.csi.volumeHandle`, and nothing requires a handle to be referenced by
exactly one PV. So when a managed (`Retain`) PV is deleted, the reaper:

1. **Clones** it into a throwaway PV — same `spec.csi` (driver, `volumeHandle`,
   secret refs), same annotations (including `provisioned-by` and the
   provisioner deletion-secret annotations), a **stale `claimRef`**, and
   `persistentVolumeReclaimPolicy: Delete`.
2. Releases the original's finalizer (see [ADR 0002](0002-finalizer-interception.md)),
   so the original — still `Retain` — is removed; its own deletion touches no
   storage.
3. The clone is born `Released` + `Delete`, so the CSI provisioner's **ordinary**
   reclaim path runs `DeleteVolume` on the shared handle → the volume is deleted
   → the clone disappears on its own.

## Consequences

- **Pro**: Reliable. The clone is a *fresh* `Delete` PV, so it gets the
  [KEP-2644](https://kubernetes.io/blog/2024/08/16/kubernetes-1-31-prevent-persistentvolume-leaks-when-deleting-out-of-order/)
  out-of-order-deletion finalizer that guarantees `DeleteVolume` runs before the
  object is removed. We reuse the provisioner's own reclaim path rather than
  reimplementing `DeleteVolume`.
- **Pro**: Decoupled. The original PV can be removed immediately; reclamation
  proceeds independently on the clone, so there is no teardown race on the
  original.
- **Pro**: Driver-agnostic. The trick is pure Kubernetes object manipulation — it
  works for any CSI driver (CephFS, RBD, …) with no driver-specific code.
- **Con**: For a brief window two PVs reference one `volumeHandle`. This is
  harmless because `DeleteVolume` is idempotent and only the clone is `Delete`,
  but it does technically violate the usual one-PV-per-handle assumption.
- **Con**: Relies on CSI provisioner behavior (the KEP-2644 finalizer; honoring
  `Delete` on a `Released` PV with a stale `claimRef`). A provisioner that
  deviates could change the outcome.
- **Con**: The reaper must be running for a managed PV deletion to reclaim
  storage (see [ADR 0002](0002-finalizer-interception.md)).
