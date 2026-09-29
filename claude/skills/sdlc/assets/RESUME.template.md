# RESUME — technical bootstrap for `<project name>`

> **Language**: write this file's content in the project's `output_language`
> (`SDLC_PM/sdlc-config.json`). Keep headings, field markers and IDs in
> English so the tooling can parse them.

> **Purpose**: get whoever picks up the project to **a working dev
> environment in under 10 minutes**. Read it second (after `HANDOFF.md`).
>
> Update it on every structural change: new dependency, new sub-project, new
> critical command, key file moved.

---

## Identity

- **Project** : `<name>`
- **Tier** : `<minimal | standard | full | exhaustive>`
- **Last updated** : `<YYYY-MM-DD>` by `<author>`

---

## In 30 seconds

`<2-3 sentences: what the project does, its main user, and the visible
deliverable. No history. No vision. Only what is.>`

---

## Machine prerequisites

| Component | Minimum version | How to check | How to install |
|---|---|---|---|
| `<e.g. Python>` | `3.12` | `python --version` | `<link>` |
| `<e.g. Node>` | `20.x` | `node --version` | `<link>` |
| `<e.g. PowerShell 7>` | `7.4+` | `$PSVersionTable.PSVersion` | `<link>` |
| `<e.g. git>` | `2.40+` | `git --version` | `<link>` |

---

## Project layout

```
<root>/
├── <folder1>/          ← <one-line role>
├── <folder2>/          ← <...>
├── SDLC_PM/           ← SDLC phases + checkpoints (tier ≥ standard)
│   ├── sdlc-config.json
│   ├── v<X.Y.Z>/
│   │   ├── 0_context.md
│   │   ├── 1_elicitation.md
│   │   ├── 2_architecture.md   (tier ≥ full)
│   │   ├── 3_conception.md     (tier ≥ standard)
│   │   └── 4_tests.md          (tier ≥ full)
│   ├── HANDOFF.md       ← state + next actions
│   └── RESUME.md        ← this file
└── <key-file>        ← <role>
```

> Update this section whenever a key folder is added, removed or moved.

---

## Step-by-step setup

```bash
# 1. Clone / pull
<command>

# 2. Virtual environment or containers
<command>

# 3. Dependencies
<command>

# 4. Local configuration (env variables, secrets)
<command or template file to copy>

# 5. Check: the test suite passes
<test command>
```

If a step fails, see **Known pitfalls** in `HANDOFF.md`.

---

## Useful commands

| Action | Command | Notes |
|---|---|---|
| Run locally | `<...>` | `<...>` |
| Run the tests | `<...>` | Target coverage `<X>` % |
| Lint / format | `<...>` | `<...>` |
| Benchmark / eval | `<...>` | `<...>` |
| Build / package | `<...>` | `<...>` |
| Deploy (if applicable) | `<...>` | `<...>` |

---

## Secrets & credentials (referenced, never written down)

> Never put a secret in clear text in this file, because it is shared with
> whoever picks up the project. Point to the secret manager (DPAPI, 1Password,
> local .env, vault) and give the **logical name**, not the value.

| Secret | Where it is stored | How to get it if missing |
|---|---|---|
| `<e.g. PROVIDER_API_KEY>` | `<Windows DPAPI / .env / Azure Key Vault>` | `<provider console + link>` |
| `<e.g. M365_TENANT_ID>` | `<...>` | `<...>` |

---

## Logs & artifacts to know

- **Current logs** : `<path>`
- **SDLC intermediate output** : `SDLC_PM/STATE.md`
- **Resumption checkpoint** : `SDLC_PM/SDLC_CHECKPOINT.md`
- **Reports** : `<folder>`

---

## Further reading (if tier ≥ standard)

- `0_context.md` — state of the world, constraints, dated assumptions
- `1_elicitation.md` — business requirements (E###)
- `2_architecture.md` — architecture decisions (A### + ADR) — tier `full`+
- `3_conception.md` — task breakdown (P### + waves)
- `4_tests.md` — coverage (T###) — tier `full`+
- `references/` (SDLC skill) — structural rules
