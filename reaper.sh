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

  if [ -n "$delts" ]; then
    # original PV is being deleted -> hand reclamation to a Delete clone
    [ "$hasfin" = yes ] || return 0
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
    # steady state -> ensure Retain PVs carry our finalizer so we can intercept
    if [ "$policy" = "Retain" ] && [ "$hasfin" = "no" ]; then
      add_finalizer "$name" \
        && log "$name: added finalizer" || log "$name: WARN finalizer add failed after retries"
    fi
  fi
}

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
