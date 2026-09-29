# ASVS L2 — Level 2 checklist (recommended)

Includes L1 plus additional patterns. Use it as soon as a project handles user
data, exposes an API, or involves transactions.

## L2 patterns (in addition to L1)

### ASVS-2.1 — World-writable permission (chmod 777)

**Regex**: `chmod\s+(0o)?777\b`

**Severity**: medium

**Why**: `chmod 777` (read/write/execute for everyone) is almost always a bug.
On a shared server it is an open door.

**Fix**:

```python
# ❌
os.chmod(path, 0o777)

# ✅ — minimum needed
os.chmod(path, 0o644)  # rw-r--r-- (file)
os.chmod(dir_path, 0o755)  # rwxr-xr-x (directory)
```

### ASVS-2.2 — HTTP without TLS

**Regex**: `http://(?!localhost|127\.0\.0\.1)`

**Severity**: medium

**Why**: all non-localhost network traffic should use HTTPS. A
man-in-the-middle attack is trivial on public Wi-Fi.

**Fix**:

```python
# ❌
response = requests.get("http://api.example.com/data")

# ✅
response = requests.get("https://api.example.com/data")
```

If the remote API does not offer HTTPS: escalate to the provider, or put it
behind a local TLS proxy.

### ASVS-2.3 — Flask POST without CSRF

**Regex**: `@app\.route.*methods=\[.*POST.*\](?!.*csrf)`

**Severity**: medium

**Why**: without a CSRF token, a malicious site can make an authenticated user
perform unintended actions.

**Fix**: use Flask-WTF, Flask-SeaSurf, or an equivalent:

```python
from flask_wtf.csrf import CSRFProtect
csrf = CSRFProtect(app)
```

### ASVS-2.4 — Disabled SSL verification

**Regex**: `verify\s*=\s*False|rejectUnauthorized\s*:\s*false`

**Severity**: medium

**Why**: disabling TLS verification means accepting any certificate, which makes
man-in-the-middle attacks easy.

**Fix**:

```python
# ❌
requests.get(url, verify=False)

# ✅ — keep the default (verify=True)
requests.get(url)

# ✅ — custom certificate (internal self-signed CA)
requests.get(url, verify="/path/to/internal-ca.pem")
```

## Patterns worth adding manually

The default L2 set covers universal patterns. For a specific project, add to
`asvs_patterns.json`:

### Sensitive logs

```json
{
  "id": "PROJ-LOG-1",
  "name": "Password in log",
  "regex": "log(?:ger)?\\.(?:info|debug|warn).*password",
  "severity": "medium",
  "extensions": [".py", ".js", ".ts", ".go"]
}
```

### Cookies without Secure/HttpOnly

```json
{
  "id": "PROJ-COOKIE-1",
  "name": "Cookie without Secure flag",
  "regex": "set_cookie\\([^)]*\\)(?!.*secure)",
  "severity": "medium",
  "extensions": [".py"]
}
```

## Topics beyond the automated scan

L2 also implies things a regex **cannot detect**:

- **Authentication**: passwords of at least 12 characters, MFA available.
- **Authorization**: RBAC or ABAC in place, least privilege.
- **Input validation**: every boundary (API, form, file) validates both format
  and semantics.
- **Logging**: security events logged (login, logout, auth failures, denied
  access) with timestamp, IP, user_id.
- **Rate limiting** on public endpoints.
- **Security headers**: CSP, X-Frame-Options, X-Content-Type-Options,
  Strict-Transport-Security.
- **Backup** strategy that has been tested (not "we have a backup" but "we
  restored it last week and it worked").

Document these points in `2_5_discussion.md` or `2_architecture.md` so an audit
can find them.

## When to move to L3

When the project goes to production with:

- medical or banking data;
- significant financial transaction volumes;
- explicit regulatory constraints (HIPAA, PCI-DSS, GDPR article 32);
- adversarial threat actors in scope (government, journalism, activism).

## L2 limits

L2 is still an **automated** scan. It does not replace:

- threat modeling (STRIDE, attack trees);
- manual penetration testing;
- security-focused human code review;
- runtime configuration audit.

For a genuinely high-risk project, combine L2/L3 with these manual practices.
