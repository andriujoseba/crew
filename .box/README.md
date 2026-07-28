# crew in a box — bootstrap runbook

This repo needs only bash, git, gh, jq, flock and timeout (all present on
a stock Debian box); shellcheck is optional but used by CI.

- Working ON the repo (development): run `shared/test/run.sh` (must end
  `failed 0`) and shellcheck as in `.github/workflows/shared-ci.yml`.
  Nothing here needs credentials or a box host.
- Spawned to REHEARSE the duty engine on this box: follow
  `shared/docs/rehearsal.md` — phase 1 is deliberately pre-auth; do not
  ask for or wait on credentials to start it.
- `cli/crew` needs a box HOST — it does not run inside a box (except
  `crew profiles` and `--dry-run` paths).
- Hire and upgrade ship `shared/` plus `VERSION` from that host. A box does
  not clone crew or need repository access; `~/duty` is its only live engine.
