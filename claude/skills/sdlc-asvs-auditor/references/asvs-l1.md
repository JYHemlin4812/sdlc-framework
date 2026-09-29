# ASVS L1 — Level 1 checklist (basic)

**Default** level in SDLC. Targets frequent, serious mistakes that a regex can
easily detect in source code.

## Scanned patterns

### ASVS-1.1 — Hardcoded password

**Regex**: `(?i)(password|passwd|pwd)\s*=\s*['"][^'"]{4,}['"]`

**Severity**: high

**Why**: a password hardcoded in source ends up in git history and build
artifacts, and leaks at the first permission mistake. Use an environment
variable, a secret manager, or an uncommitted `.env` file.

**Fix**:

```python
# ❌
DB_PASSWORD = "admin123"

# ✅
import os
DB_PASSWORD = os.environ["DB_PASSWORD"]  # fails loudly if missing
```

### ASVS-1.2 — API key or secret in source

**Regex**: `(?i)(api[_-]?key|secret|token|bearer)\s*=\s*['"][A-Za-z0-9_\-]{16,}['"]`

**Severity**: high

**Why**: same as ASVS-1.1, generalized to API keys, tokens and other secrets. A
compromised API key can generate large costs or expose data.

**Fix**: environment variable, vault, secret manager.

### ASVS-1.3 — Weak hash MD5/SHA1

**Regex**: `\b(md5|sha1)\s*\(`

**Severity**: high

**Why**: MD5 and SHA1 are cryptographically broken. Acceptable **only** for
non-security uses (file checksums, non-sensitive fingerprints). Never for
passwords or signatures.

**Fix**:

```python
# ❌ For passwords
import hashlib
hashlib.md5(password.encode()).hexdigest()

# ✅
import bcrypt
bcrypt.hashpw(password.encode(), bcrypt.gensalt())
# or argon2-cffi for new projects
```

### ASVS-1.4 — Use of eval/exec

**Regex**: `\b(eval|exec)\s*\(`

**Severity**: high

**Why**: `eval`/`exec` run arbitrary code. If the input comes from an untrusted
source, that is remote code execution (RCE).

**Fix**: remove it. To parse JSON, use `json.loads`. To evaluate simple math
expressions, use `ast.literal_eval` or `simpleeval`.

### ASVS-1.5 — SQL string concatenation

**Regex**: `(SELECT|INSERT|UPDATE|DELETE)\s.*['"]?\s*\+\s*[a-zA-Z_]`

**Severity**: high

**Why**: SQL injection is one of the most common and destructive
vulnerabilities.

**Fix**:

```python
# ❌
query = "SELECT * FROM users WHERE id = " + user_id

# ✅ — parameters
cursor.execute("SELECT * FROM users WHERE id = ?", (user_id,))

# ✅ — ORM
session.query(User).filter(User.id == user_id).first()
```

## Common false positives

### "password" in a docstring

```python
def hash_password(password: str) -> str:
    """Hash a password using bcrypt."""
    ...
```

The regex can match `password = ` when the docstring contains `password=`. If it
is a genuine false positive, document it in `2_5_discussion.md`, add an
`asvs-ignore` marker on the line, or remove the pattern.

### "secret" in explanatory comments

```python
# Do not hardcode a secret here  <- also matches
SECRET = os.environ["SECRET"]
```

The `=` after `SECRET` matches the pattern. Acceptable — a human can dismiss the
finding.

## When to move to L2

Once the L1 findings are fixed or documented as exceptions and you are ready
for less obvious patterns. L2 is recommended as soon as the project:

- handles user data;
- exposes a public API;
- touches money or transactions.

## L1 limits

L1 does **not** cover:

- vulnerable dependencies (use `npm audit`, `pip-audit`, `cargo audit`);
- network misconfigurations (firewalls, security groups);
- leaks through errors (an exception that dumps the config);
- timing attacks (non-constant-time string comparisons).

This is intentional: L1 targets the "catastrophic but detectable in
30 seconds".
