# 0004 — Graceful shutdown as PID 1 (trap + backgrounded watch + `wait`)

Status: Accepted

## Context

The container's entrypoint is the shell script, so the shell runs as PID 1. A
shell has no default signal disposition for SIGTERM, and a plain foreground
`while … | while read` watch loop does not return on SIGTERM. The result: on
every drain, rollout, or `docker stop`, the pod ignored the graceful-termination
SIGTERM and hung the full termination grace period until SIGKILL — slow and
ungraceful on every deploy.

## Decision

Install `trap 'exit 0' TERM INT`, and run the watch loop **backgrounded**
(`{ … } &`) followed by `wait`. `wait` is interruptible by a trapped signal, so
SIGTERM fires the trap promptly; PID 1 exiting tears down the orphaned
`kubectl`/`jq` children. A CI test (`test.yml`) builds the image and asserts that
`docker stop` returns quickly against a blocking fake `kubectl`, so the behavior
can't silently regress.

## Consequences

- **Pro**: Fast, graceful shutdown on rollouts and drains instead of a SIGKILL
  after the grace period.
- **Pro**: Regression-guarded by a CI test that measures stop latency.
- **Con**: The backgrounding + `wait` structure is non-obvious; a future refactor
  that foregrounds the loop would silently reintroduce the hang. The code
  comments call this out.
