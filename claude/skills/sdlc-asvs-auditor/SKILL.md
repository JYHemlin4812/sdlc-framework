---
name: sdlc-asvs-auditor
description: |
  SDLC sub-skill: configurable OWASP ASVS security audit (L1/L2/L3).
  Scans source code for security anti-patterns, loads the checklist that
  matches `asvs_level` in `sdlc-config.json`, and returns a structured report
  (file, line, severity).

  Triggers: OWASP ASVS, security audit, security gate, SDLC security, /sdlc:security,
  vulnerability scan, hardcoded secrets, SQL injection, weak crypto.
  Also triggers on (FR): audit sécurité, sécurité SDLC, scan vulnérabilités.
---

# sdlc-asvs-auditor — OWASP ASVS audit

Part of the SDLC bundle (installable via `scripts/install.ps1` or `scripts/install.sh`).
Runs a **configurable** security scan based on the OWASP Application Security
Verification Standard (ASVS) checklists. Three cumulative levels (L1/L2/L3).

## When to invoke

- On `/sdlc:security` — on-demand scan.
- During `/sdlc:gate` when `asvs_level >= 1` in the config — blocks progress
  while undocumented high-severity findings remain.
- Ad hoc: before a risky commit or a release.

## Tools

- `scripts/asvs_scanner.py` — regex-based Python scanner.
- `scripts/asvs_patterns.json` — pattern catalog per level (editable per project).
- `references/asvs-l1.md`, `asvs-l2.md`, `asvs-l3.md` — detailed checklists and advice.

## Levels

### L1 — Basic (default)

Use for: MVPs, prototypes, internal projects without sensitive data.

Covers frequent, serious mistakes: plaintext secrets, weak hashes (MD5/SHA1),
`eval`/`exec`, SQL string concatenation.

See `references/asvs-l1.md`.

### L2 — Recommended

Use for: projects handling user data, exposed APIs, e-commerce.

Covers L1 plus overly broad permissions, HTTP without TLS, missing CSRF,
disabled TLS verification.

See `references/asvs-l2.md`.

### L3 — High security

Use for: healthcare, finance, highly sensitive data, regulatory constraints
(HIPAA, PCI-DSS).

Covers L2 plus custom crypto (AES ECB), unsafe deserialization (pickle),
`shell=True`, `os.system`.

See `references/asvs-l3.md`.

## Usage

### Via slash command

```
/sdlc:security
```

Reads `asvs_level` from `sdlc-config.json` and runs the scan.

### Via CLI

```powershell
$env:PYTHONUTF8 = "1"

# L1 scan of the current project
python skills/sdlc-asvs-auditor/scripts/asvs_scanner.py --level 1 --root .

# L2 scan of a subdirectory
python skills/sdlc-asvs-auditor/scripts/asvs_scanner.py --level 2 --root ./api

# JSON output for CI/CD
python skills/sdlc-asvs-auditor/scripts/asvs_scanner.py --level 3 --root . --json
```

### Exit codes

- `0`: no high-severity finding.
- `1`: high-severity findings present (blocks the AQ Gate when run via `/sdlc:gate`).
- `2`: scan error (root not found, etc.).

## Finding format

```
[HIGH] ASVS-1.1 Hardcoded password — src/db.py:42
    > password = "admin123"  # would not survive an audit
[MEDIUM] ASVS-2.2 HTTP without TLS — config/api.yml:7
    > endpoint: http://internal.example.com/data
```

JSON:

```json
{
  "level": 2,
  "root": "C:\\dev\\myproject",
  "files_scanned": 47,
  "high_severity_count": 1,
  "findings": [
    {
      "pattern_id": "ASVS-1.1",
      "name": "Hardcoded password",
      "severity": "high",
      "file": "src/db.py",
      "line": 42,
      "snippet": "password = \"admin123\"  # would not survive..."
    }
  ]
}
```

## Handling a finding

Three options:

1. **Fix it** (default): change the code to remove the anti-pattern and describe
   the fix in the commit message.
2. **Document an exception**: if the finding is a false positive or acceptable in
   context, add a note in `4_tests.md` (section T100) or `2_5_discussion.md`
   explaining why, so an auditor can see the decision. Reviewing these
   exceptions is manual.
3. **Lower the ASVS level**: if many findings are irrelevant, the chosen level
   may be too strict for the project. Lower `asvs_level` in `sdlc-config.json`
   after discussing it with the user.

To silence one reviewed line, add an `asvs-ignore` marker on that line (like
`# nosec` / `# noqa`) with a short justification; the suppression stays visible
in the source.

## Customizing patterns

`scripts/asvs_patterns.json` can be edited to:

- add a project-specific pattern (e.g. to detect a particular internal API);
- disable a pattern (remove it from the list);
- change target extensions (e.g. add `.kt` for Kotlin).

Custom patterns follow this schema:

```json
{
  "id": "PROJ-1",
  "name": "Short description",
  "regex": "Python re-compatible regex",
  "severity": "high|medium|low",
  "extensions": [".py", ".js"]
}
```

Test each regex against a few samples: an overly permissive regex floods the
report with false positives and erodes trust in the tool.

## Known limitations

- **Static regex scan**: no semantic analysis. `password = compute_hash()` is
  flagged as "hardcoded password" because the regex matches, although it is not.
- **No data-flow analysis**: a SQL injection that goes through three
  intermediate functions is not detected.
- **False negatives** on deliberately obfuscated code.
- **No integration** with `cargo audit`, `npm audit`, `pip-audit` — run those
  tools separately.

For high-risk projects (L3), complement with SAST (Semgrep, SonarQube), DAST and
a human audit.

## Recommended workflow

1. Enable ASVS L1 from the start (`asvs_level: 1`).
2. Run `/sdlc:security` after each major development wave.
3. Before release, raise to L2 and fix the non-trivial findings.
4. For sensitive projects, raise to L3 before production.
5. Document exceptions in `2_5_discussion.md`.

## Further reading

- `references/asvs-l1.md` — level 1 checklist
- `references/asvs-l2.md` — level 2 checklist
- `references/asvs-l3.md` — level 3 checklist
- Official OWASP ASVS: https://owasp.org/www-project-application-security-verification-standard/
