# 0008 — Automate finalizer cleanup on uninstall via a pre-delete hook

Status: Accepted

## Context

The finalizer that makes reclaim-on-delete work
([ADR 0002](0002-finalizer-interception.md)) has a downside: uninstalling the
reaper without first removing it leaves every managed PV wedged in `Terminating`,
because nothing is left to process the finalizer. The original mitigation was a
documented manual strip loop the operator had to remember to run *before*
uninstalling — easy to forget, and the mistake surfaces only later, when a PV
won't delete.

A Helm `pre-delete` hook can run that cleanup automatically. But hooks cut both
ways: a `pre-delete` hook that *fails* aborts the uninstall. A naive
implementation would turn "forgot to clean up" into "can't uninstall at all" —
strictly worse than the manual approach.

## Decision

Ship a `pre-delete` Helm hook (a Job, toggled by `cleanupHook.enabled`, default
on) that runs the reaper's own image as `reaper.sh strip-finalizers`, reusing the
release ServiceAccount/RBAC — which are still present during `pre-delete`, before
Helm tears down the release's normal resources.

Not blocking the uninstall is the primary design constraint, enforced by four
independent layers:

1. `strip-finalizers` is best-effort and ends in an unconditional `exit 0` — a
   failed patch or unreachable API only logs.
2. The container wraps it in `timeout N … || true; exit 0`, bounding a hung API
   call and forcing a zero exit regardless.
3. `backoffLimit: 0` (no retries to widen the window) with an
   `activeDeadlineSeconds` backstop for the "pod can't schedule/pull" case.
4. `helm.sh/hook-delete-policy` cleans the Job up; `cleanupHook.enabled: false`
   disables it entirely, and Flux's `spec.uninstall.disableHooks` is the
   documented escape hatch.

If any layer's precondition fails, the outcome degrades to exactly the pre-hook
behavior (finalizers remain; the manual strip loop is still documented) — never
worse.

## Consequences

- **Pro**: The common uninstall path is clean with no operator ritual — PVs don't
  get stuck `Terminating`.
- **Pro**: Reuses the existing image, ServiceAccount, and RBAC — no extra
  `kubectl` image and no hook-scoped permissions, because the normal RBAC
  outlives the hook (`pre-delete` runs before those resources are deleted).
- **Pro**: Bounded and non-blocking by construction; the worst case equals the
  old manual-cleanup baseline.
- **Con**: Depends on Helm/Flux hook semantics; a consumer applying raw manifests
  instead of the chart gets no automation.
- **Con**: In the pathological "hook pod can't be scheduled" case,
  `activeDeadlineSeconds` still imposes a bounded wait before the uninstall
  proceeds; the escape hatch is `disableHooks`.
- **Con**: One more moving part in the chart to keep rendered and linted in CI.
