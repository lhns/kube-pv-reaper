#!/bin/sh
# kube-pv-reaper (clone-on-delete).
#
# Gives CSI PersistentVolumes a split reclaim behavior Kubernetes does not offer
# natively:
#   * delete a PVC   -> the PV stays (Released) and the backing volume is KEPT
#                       (works because the StorageClass / PV is reclaimPolicy Retain)
#   * delete a PV    -> the backing volume is RECLAIMED
#
# The original PV is NEVER changed to Delete. When a managed (Retain) PV is
# deleted, we CLONE it into a throwaway PV with the same spec.csi.volumeHandle
# but reclaimPolicy Delete and a stale claimRef. That clone is born
# Released+Delete, so the CSI provisioner's normal reclaim runs DeleteVolume on
# the shared handle -> the volume is deleted, then the clone disappears.
# Reliable because the clone is a fresh Delete PV (gets the KEP-2644 finalizer);
# decoupled, so the original can go away immediately. Event-driven via a watch.
#
# Config (env):
#   DRIVER        CSI driver(s) to manage, comma-separated; empty = all (default: "")
#   FINALIZER     finalizer placed on managed Retain PVs
#                 (default: pv-reaper.lhns.de/reclaim-on-delete)
#   CLONE_PREFIX  name prefix for reclaim clones                 (default: reclaim-)
set -u
FINALIZER="${FINALIZER:-pv-reaper.lhns.de/reclaim-on-delete}"
DRIVER="$(printf '%s' "${DRIVER:-}" | tr -d '[:space:]')"  # comma list; tolerate "a, b"
CLONE_PREFIX="${CLONE_PREFIX:-reclaim-}"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) kube-pv-reaper: $*"; }

# Exit promptly on SIGTERM/SIGINT. As PID 1 a shell has no default signal
# disposition, so without this it would ignore SIGTERM and hang until SIGKILL on
# every drain/rollout. The watch loop below is backgrounded + `wait`ed so the
# signal actually interrupts (a plain foreground loop wouldn't).
trap 'exit 0' TERM INT

# Finalizer edits re-read the live object and retry, so a stale watch object or
# a concurrent change can never leave a PV stuck Terminating.
add_finalizer() { # $1=pv
  n="$1"; i=0
  while [ "$i" -lt 6 ]; do
    cur=$(kubectl get pv "$n" -o json 2>/dev/null) || return 0
    printf '%s' "$cur" | jq -e --arg f "$FINALIZER" 'any((.metadata.finalizers // [])[]; . == $f)' >/dev/null 2>&1 && return 0
    nf=$(printf '%s' "$cur" | jq -c --arg f "$FINALIZER" '((.metadata.finalizers // []) + [$f]) | unique')
    kubectl patch pv "$n" --type merge -p "{\"metadata\":{\"finalizers\":$nf}}" >/dev/null 2>&1 && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}
remove_finalizer() { # $1=pv
  n="$1"; i=0
  while [ "$i" -lt 6 ]; do
    cur=$(kubectl get pv "$n" -o json 2>/dev/null) || return 0
    printf '%s' "$cur" | jq -e --arg f "$FINALIZER" 'any((.metadata.finalizers // [])[]; . == $f)' >/dev/null 2>&1 || return 0
    nf=$(printf '%s' "$cur" | jq -c --arg f "$FINALIZER" '[ (.metadata.finalizers // [])[] | select(. != $f) ]')
    kubectl patch pv "$n" --type merge -p "{\"metadata\":{\"finalizers\":$nf}}" >/dev/null 2>&1 && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}

# True if the PV was dynamically provisioned by a CSI driver. The external
# provisioner stamps `pv.kubernetes.io/provisioned-by` on every volume it
# creates; static / pre-provisioned PVs never carry it. This is the one signal
# that decides whether a volume is ours to reclaim (see the note in reconcile).
is_dynamic() { # $1=pv json
  printf '%s' "$1" \
    | jq -e '((.metadata.annotations // {})["pv.kubernetes.io/provisioned-by"] // "") != ""' \
      >/dev/null 2>&1
}

reconcile() {
  pv="$1"
  d=$(printf '%s' "$pv" | jq -r '.spec.csi.driver // ""')
  [ -n "$d" ] || return 0                              # not a CSI PV
  if [ -n "$DRIVER" ]; then                            # scoped to a driver (comma list)?
    case ",$DRIVER," in *",$d,"*) : ;; *) return 0 ;; esac
  fi
  name=$(printf '%s' "$pv" | jq -r '.metadata.name')
  case "$name" in "${CLONE_PREFIX}"*) return 0 ;; esac # never manage our own clones
  policy=$(printf '%s' "$pv" | jq -r '.spec.persistentVolumeReclaimPolicy')
  delts=$(printf '%s' "$pv" | jq -r '.metadata.deletionTimestamp // ""')
  if printf '%s' "$pv" | jq -e --arg f "$FINALIZER" 'any((.metadata.finalizers // [])[]; . == $f)' >/dev/null 2>&1; then
    hasfin=yes
  else
    hasfin=no
  fi
  # Only dynamically-provisioned volumes are ours to reclaim. A static /
  # pre-provisioned PV points at backend storage the admin created out-of-band
  # (an existing CephFS subtree, RBD image, NFS export, ...); its volumeHandle is
  # not a provisioner-owned ID, so a Delete clone's DeleteVolume would fail (e.g.
  # ceph-csi "string underflow") or, worse, destroy shared data. Skip them —
  # consistent with the reclaim itself, which leans on the provisioner's own
  # DeleteVolume (only meaningful for volumes it provisioned).
  if is_dynamic "$pv"; then dyn=yes; else dyn=no; fi

  if [ -n "$delts" ]; then
    # original PV is being deleted
    [ "$hasfin" = yes ] || return 0
    if [ "$dyn" = no ]; then
      # static PV carrying our finalizer (e.g. added by an older build) -> just
      # release it; the native Retain delete then touches no backend storage.
      remove_finalizer "$name" \
        && log "$name: static/pre-provisioned; released finalizer without reclaim" \
        || log "$name: WARN finalizer removal failed after retries"
      return 0
    fi
    # dynamic -> hand reclamation to a Delete clone
    clone="${CLONE_PREFIX}${name}"
    if kubectl get pv "$clone" >/dev/null 2>&1; then
      log "$name: reclaim clone $clone already present"
    else
      body=$(printf '%s' "$pv" | jq --arg p "$CLONE_PREFIX" '{
        apiVersion: "v1", kind: "PersistentVolume",
        metadata: { name: ($p + .metadata.name), annotations: (.metadata.annotations // {}) },
        spec: {
          csi: .spec.csi,
          claimRef: (.spec.claimRef | {apiVersion, kind, namespace, name, uid}),
          storageClassName: .spec.storageClassName,
          capacity: .spec.capacity,
          accessModes: .spec.accessModes,
          volumeMode: .spec.volumeMode,
          persistentVolumeReclaimPolicy: "Delete"
        }
      }')
      if printf '%s' "$body" | kubectl create -f - >/dev/null 2>&1; then
        log "$name: created reclaim clone $clone (Delete) -> volume will be reclaimed"
      else
        log "$name: WARN clone create failed; keeping finalizer, will retry"
        return 0
      fi
    fi
    if remove_finalizer "$name"; then
      log "$name: released finalizer (original removed; clone reclaims volume)"
    else
      log "$name: WARN finalizer removal failed after retries"
    fi
  else
    # steady state
    if [ "$dyn" = no ]; then
      # never manage static PVs; strip a stray finalizer an older build may have
      # added so their eventual delete is native and can't wedge on a bad clone.
      if [ "$hasfin" = yes ]; then
        remove_finalizer "$name" \
          && log "$name: static/pre-provisioned; removed stray finalizer" \
          || log "$name: WARN finalizer removal failed after retries"
      fi
      return 0
    fi
    # dynamic -> ensure Retain PVs carry our finalizer so we can intercept delete
    if [ "$policy" = "Retain" ] && [ "$hasfin" = "no" ]; then
      add_finalizer "$name" \
        && log "$name: added finalizer" || log "$name: WARN finalizer add failed after retries"
    fi
  fi
}

# One-shot cleanup mode, invoked by the Helm pre-delete hook as
# `reaper.sh strip-finalizers`. Removes our finalizer from every managed PV so
# that uninstalling the reaper can't leave PVs wedged in Terminating. It is
# strictly best-effort and ALWAYS exits 0 — a pre-delete hook that fails would
# block `helm uninstall`, so this must never return non-zero, even when the API
# is unreachable or a patch keeps failing.
if [ "${1:-}" = "strip-finalizers" ]; then
  log "strip-finalizers: removing $FINALIZER from managed PVs (best-effort)"
  names=$(kubectl get pv -o json 2>/dev/null \
    | jq -r --arg f "$FINALIZER" '.items[] | select(any((.metadata.finalizers // [])[]; . == $f)) | .metadata.name' 2>/dev/null) || names=""
  for n in $names; do
    remove_finalizer "$n" && log "strip-finalizers: stripped $n" \
      || log "strip-finalizers: WARN could not strip $n (continuing)"
  done
  log "strip-finalizers: done"
  exit 0
fi

# Tests source this file with REAPER_SOURCE_ONLY=1 to exercise reconcile()/helpers
# against fabricated PV JSON without starting the watch loop below.
[ "${REAPER_SOURCE_ONLY:-}" = "1" ] && return 0 2>/dev/null || true

log "started (clone-on-delete, watch-based); driver='${DRIVER:-<all CSI>}' finalizer=$FINALIZER"
# Backgrounded + wait so SIGTERM interrupts `wait` and the trap fires; PID 1
# exiting tears down the orphaned kubectl/jq children.
{
  while true; do
    # --watch emits every existing PV first (as ADDED) then streams changes;
    # --output-watch-events wraps each as {type,object}. No polling interval.
    kubectl get pv --watch --output-watch-events=true -o json 2>/dev/null \
      | jq -c '.object' 2>/dev/null \
      | while IFS= read -r pv; do reconcile "$pv"; done
    log "watch stream ended; reconnecting in 2s"
    sleep 2
  done
} &
wait
