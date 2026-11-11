# 5 — Delivery

> **Language**: write this file's content in the project's `output_language`
> (`SDLC_PM/sdlc-config.json`). Keep headings, field markers and IDs in
> English so the tooling can parse them.

> SDLC phase 5, tier `full` and above. Written by the `sdlc-delivery` sub-skill
> before `sdlc-finish`. Records how the version reaches its users and how to
> undo it. Not verified by the AQ Gate (indicative): its proof is the commands
> and results quoted below.

---

## Metadata

- **Project** : `<name>`
- **Version** : `v1.0.0`
- **Date** : `<YYYY-MM-DD>`
- **Prepared at commit** : `<output of git rev-parse HEAD when the evidence below was produced>`
- **Delivery authorized by** : `<the user, and what exactly: merge, release, deploy — or none yet>`

---

## Continuous integration

- **Platform** : `<existing CI platform, or none>`
- **Commands run by CI** : `<the repository's real install, lint/type/build, unit, integration commands>`
- **Full suite required before merge** : `<yes / no, and where it is enforced>`
- **Branch protection** : `<configured / not configured>` (a CI file is not branch protection)
- **Remote CI result** : `<run link and status, or "not observed">`

---

## Secrets and configuration

| Name | Used by | Injected by |
|---|---|---|
| `<SECRET_NAME>` | `<component>` | `<environment / secret store>` |

Names only, never values. Examples are fictitious. Tests send no real message to customers and
write nothing to production.

---

## Data and migrations

- **Migrations** : `<none, or list>`
- **Reversible** : `<yes / no>` — if no, the recovery strategy: `<backup, forward fix...>`
- **Version compatibility** : `<old and new code against the migrated schema>`

---

## Deployment

- **Order** : `<steps in order, or "not applicable">`
- **Health signals** : `<what shows the new version works: endpoint, metric, log>`
- **Rollback** : `<exact steps and their limits>`

---

## Evidence

| Check | Command | Result |
|---|---|---|
| Full test suite | `<command>` | `<decisive line, exit code>` |
| AQ Gate (release) | `check_sdlc.py --phase release` | `<result>` |

**Not run** : `<check not run and why — a missing tool is "not run", never a pass>`

---

## Residual risks

- `<risk, impact, mitigation>`

---

## Pull request body (draft)

```markdown
## Problem
<what was wrong or missing>

## Behavior
<final behavior, linked E### / P###>

## Evidence
<commands run and results, from the Evidence table>

## Risks and rollback
<residual risks, rollback steps, checks not run>
```
