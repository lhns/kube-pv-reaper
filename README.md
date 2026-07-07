# kube-pv-reaper

A tiny controller that gives **CSI PersistentVolumes a split reclaim behavior**
Kubernetes does not offer natively:

| Action | Result |
| --- | --- |
| `kubectl delete pvc …` | PV stays (`Released`), **backing volume kept** — data survives. |
| `kubectl delete pv …`  | PV removed **and the backing volume is reclaimed**. |

Native Kubernetes has a single `reclaimPolicy` switch that treats both
transitions the same: `Retain` keeps data on both, `Delete` destroys it on both.
kube-pv-reaper adds the missing middle — *keep on PVC-delete, reclaim on
PV-delete* — so a `Released` PV becomes an explicit tombstone you delete when you
actually want the storage gone.

Works with **any CSI driver** (CephFS, RBD, etc.) — the trick is generic.

## How it works (clone-on-delete)

The original PV is **never** changed to `Delete`. A CSI volume is identified by
`spec.csi.volumeHandle`, and nothing requires a handle to be referenced by only
one PV. So when a managed (`Retain`) PV is deleted, the reaper:

1. **Clones** it into a throwaway PV — same `spec.csi` (driver + volumeHandle +
   secret refs), same annotations (incl. `provisioned-by` and
   `provisioner-deletion-secret-*`), a **stale `claimRef`**, and
   `reclaimPolicy: Delete`.
2. Releases its finalizer, so the original PV (still `Retain`) is removed —
   its own deletion touches nothing.
3. The clone is born `Released`+`Delete`, so the CSI provisioner's **normal**
   reclaim runs `DeleteVolume` on the shared handle → the volume is deleted →
   the clone disappears.

It's reliable because the clone is a *fresh* `Delete` PV (it gets the
[KEP-2644](https://kubernetes.io/blog/2024/08/16/kubernetes-1-31-prevent-persistentvolume-leaks-when-deleting-out-of-order/)
finalizer that guarantees `DeleteVolume` runs before the object is removed), and
decoupled from the original so there's no race. `DeleteVolume` is idempotent, so
the brief window where two PVs share one handle is harmless. It's event-driven
(a `kubectl get pv --watch` stream, no polling), and finalizer edits re-read and
retry so a PV can never get stuck `Terminating`.

## Install

```sh
helm install pv-reaper oci://ghcr.io/lhns/charts/kube-pv-reaper \
  --namespace pv-reaper --create-namespace \
  --version <version> \
  --set driver=cephfs.csi.ceph.com
```

Or with Flux — an `OCIRepository` + `HelmRelease` pointing at
`oci://ghcr.io/lhns/charts/kube-pv-reaper`.

## Required configuration — which reclaimPolicy goes where

| Where | Must be | Why |
| --- | --- | --- |
| Your StorageClass | `reclaimPolicy: Retain` | New PVs are born with the SC's policy; `Retain` is what keeps data on PVC-delete. |
| Every managed PV | `Retain` — never change it | The original stays `Retain` for life; the reaper never flips it. The only `Delete` object is the short-lived clone. |

**Do not set the StorageClass to `Delete`** — that reclaims on PVC-delete, which
is the behavior this tool exists to avoid.

## Configuration (Helm values)

| Value | Default | Description |
| --- | --- | --- |
| `driver` | `""` | CSI driver to manage. Empty = **all** CSI PVs. Set to e.g. `cephfs.csi.ceph.com` to scope. |
| `finalizer` | `pv-reaper.lhns.de/reclaim-on-delete` | Finalizer placed on managed `Retain` PVs. |
| `clonePrefix` | `reclaim-` | Name prefix for reclaim clones. |
| `image.repository` / `image.tag` | `ghcr.io/lhns/kube-pv-reaper` / chart appVersion | Container image. |

## Caveats

- **The reaper must be running to delete a managed PV.** It uses a finalizer, so
  `kubectl delete pv` on a managed PV hangs in `Terminating` until the reaper
  processes it. If it's down, deletions wait — data is never lost.
- **Before uninstalling**, strip the finalizer from managed PVs or they become
  un-deletable:
  ```sh
  for pv in $(kubectl get pv -o json | jq -r '.items[] | select(.metadata.finalizers[]? == "pv-reaper.lhns.de/reclaim-on-delete") | .metadata.name'); do
    kubectl patch pv "$pv" --type merge -p '{"metadata":{"finalizers":null}}'
  done
  ```

## Releases

- Push to `main` → dev build: image `:sha-<short>`, chart `0.0.0-sha-<short>`.
- Tag `vX.Y.Z` → release: image `:X.Y.Z` + `:latest`, chart `X.Y.Z`.

## License

[Apache-2.0](LICENSE)
