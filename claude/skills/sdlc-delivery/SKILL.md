---
name: sdlc-delivery
description: |
  SDLC sub-skill: verifiable delivery, run before sdlc-finish. Inspects the
  project's real scripts, manifests, CI and environment, then records CI
  commands, secrets by name, migrations, deployment order, health signals,
  rollback, evidence and residual risks — in SDLC_PM/v<X>/5_delivery.md at tier
  full and above, inline in the PR body below. Never deploys, publishes or
  merges on its own invocation. Adapted from the BPSE `se-delivery` practice
  (see `sdlc/SOURCES.md`).

  Triggers: delivery, release preparation, CI pipeline, GitHub Actions,
  migration, rollback, deployment order, health check, PR description, before
  /sdlc:finish. Also triggers on (FR): livraison, préparation de release,
  pipeline CI, migration, retour arrière, description de PR.
---

# sdlc-delivery — Verifiable delivery (v4.0)

## SDLC integration

- **When to use:** after `/sdlc:gate` passes on the last wave, before
  `sdlc-finish`. `sdlc-finish` requires it (see its step 0), even when it is
  invoked directly.
- **Deliverable:** at tier `full` and above, `SDLC_PM/v<X>/5_delivery.md`, created
  from `~/.claude/skills/sdlc/assets/5_delivery.template.md` when absent. Below
  `full`, the same points go into the PR body only (no new file).
- **Verified by the gate:** no (indicative). The AQ Gate does not read
  `5_delivery.md`. Its proof is the commands and results quoted in it.
- **Authorization:** this skill prepares the delivery. It never triggers a
  deployment, a publication or a merge on its own invocation: those follow the
  user's real authorization for the task, recorded in the **Delivery authorized
  by** field.

## Method

1. **Inspect** the scripts, manifests, lockfiles, CI files and environment that
   exist. Use the project's own commands; never assume npm, Docker or a host.
2. **CI**: when CI is part of the request, use the platform already in place.
   Plan a reproducible install, lint/typing/build if they exist, unit tests,
   integration tests with isolated services, and critical end-to-end tests by
   risk. The full required suite runs before merge. Never delete a flaky test or
   ignore a failure to get green; separate diagnosing the flakiness from fixing
   it.
3. **Secrets**: injected by the environment; document their names and uses,
   never their values. Examples are fictitious. Tests send no real message to
   customers and write nothing to production.
4. **Migrations and deployment**: state the migrations, version compatibility,
   deployment order, health signals and rollback when the delivery involves
   them. An irreversible migration needs an explicit recovery strategy.
5. **Evidence**: run the full suite and `check_sdlc.py --phase release`; quote
   the decisive lines (see `sdlc-verify`). A project with no `SDLC_PM/` (tier
   `none`) has no gate to run: record the AQ Gate as not applicable and create no
   `SDLC_PM/`. List every check **not run** with its reason. Record
   `git rev-parse HEAD` as **Prepared at commit**, on a working tree whose only
   uncommitted changes are the routine tracking files that `sdlc-finish` step 0
   exempts (`HANDOFF.md`, `RESUME.md`, `STATE.md`, `STOW.md`, `SDLC_CHECKPOINT.md`,
   `5_delivery.md`). The config and the E/A/P/T documents are gate inputs: commit
   them first, like the code, so the evidence describes a real commit and
   `sdlc-finish` judges freshness on the same boundary. `sdlc-finish` refreshes
   the document when anything else has changed since. On a refresh, re-check
   migrations, CI, deployment and rollback against the diff since that commit,
   not only the evidence table.
6. **PR body**: problem and final behavior, then evidence and residual risks
   (the draft at the end of `5_delivery.md`). `sdlc-finish` uses it.

## Honesty rules

- Never present a control that is not configured as an active protection;
  branch protection is distinct from the CI file.
- A local green run does not prove the remote CI: when remote verification is
  part of the request, observe its result and quote it.
- Keep `README` and `RESUME.md` aligned with the final code; no fictitious
  command or link in a delivered README. At tier `full` and above, when the
  project has no README, write one from
  `~/.claude/skills/sdlc/assets/README.template.md`, keeping only the sections
  that apply. `RESUME.md` keeps its own setup steps either way.

## Output

A short report: what changes, the real verification (commands and results), the
limits, and the next action the user has to authorize.
