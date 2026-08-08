#!/usr/bin/env bash
# Sourceable worktree-hygiene drill helpers. The live leg runs after the
# role-specific phase-2 block; its predicates stay here so CI can mutate the
# ref, record and log inputs without a drill host.

rehearsal_hygiene_drill() {
  if [ "${REHEARSAL_HYGIENE_DRILL:-1}" -eq 0 ]; then
    skip "hygiene: dirty worktree preservation and refusal (--no-hygiene-drill)"
    return 0
  fi

  skip "hygiene: dirty worktree preservation and refusal (fixture not yet staged)"
}
