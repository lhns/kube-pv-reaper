# 0005 — Driver scoping via a comma-separated list (empty = all CSI)

Status: Accepted

## Context

A cluster may run several CSI drivers, and an operator often wants the reaper to
manage some but not others (e.g. `cephfs.csi.ceph.com` and `rbd.csi.ceph.com` but
nothing else). The original design took a single `driver` value; that could not
express "these two but not a third."

## Decision

Match a PV's `spec.csi.driver` against a comma-separated `DRIVER` list (rendered
by the chart from a `drivers[]` value; surrounding whitespace tolerated). An
empty list means **all** CSI PVs. The singular `driver` value is retained as a
back-compat alias, honored only when `drivers` is empty. PVs whose name starts
with the clone prefix are always skipped so the reaper never manages its own
clones.

## Consequences

- **Pro**: Precise multi-driver scoping; the common "manage everything" case still
  works with no configuration.
- **Pro**: Backward compatible — existing single-`driver` installs keep working.
- **Con**: Two overlapping knobs (`drivers` list and `driver` alias) to document
  and reason about.
- **Con**: Scoping is by driver name only; there is no label- or
  StorageClass-based selection.
