# ASVS L3 — Level 3 checklist (high security)

Includes L1 + L2 plus additional patterns. Use it for projects with high security
impact: healthcare, finance, highly sensitive data, regulatory constraints.

## L3 patterns (in addition to L1 + L2)

### ASVS-3.1 — AES ECB mode (insecure)

**Regex**: `AES\.new\([^)]*MODE_ECB`

**Severity**: high

**Why**: ECB encrypts each block independently, so patterns stay visible in the
ciphertext (the ECB penguin image is the famous example). Prefer GCM, or CBC
with a random IV.

**Fix**:

```python
# ❌
from Crypto.Cipher import AES
cipher = AES.new(key, AES.MODE_ECB)

# ✅ — AES-GCM (authenticated, recommended)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
aesgcm = AESGCM(key)
nonce = os.urandom(12)
ciphertext = aesgcm.encrypt(nonce, plaintext, associated_data)
```

### ASVS-3.2 — Unsafe pickle deserialization

**Regex**: `pickle\.load[s]?\s*\(`

**Severity**: high

**Why**: `pickle` can execute arbitrary code during deserialization. Never
unpickle data that is not fully under your control.

**Fix**:

```python
# ❌
import pickle
data = pickle.loads(untrusted_input)

# ✅ — JSON for simple data
import json
data = json.loads(untrusted_input)

# ✅ — msgpack for compact binary
import msgpack
data = msgpack.unpackb(untrusted_input, raw=False)
```

### ASVS-3.3 — Subprocess shell=True

**Regex**: `subprocess\.(?:Popen|run|call)\s*\([^)]*shell\s*=\s*True`

**Severity**: high

**Why**: `shell=True` starts a shell that interprets metacharacters, which means
command injection unless the input is fully trusted.

**Fix**:

```python
# ❌
subprocess.run(f"ls {user_dir}", shell=True)

# ✅ — separate arguments
subprocess.run(["ls", user_dir], shell=False)
```

### ASVS-3.4 — Use of os.system

**Regex**: `\bos\.system\s*\(`

**Severity**: medium

**Why**: `os.system` always goes through a shell, does not capture output, and
does not propagate the exit code cleanly. Avoid it.

**Fix**:

```python
# ❌
os.system(f"echo {value}")

# ✅
result = subprocess.run(["echo", value], capture_output=True, text=True, check=True)
```

## Patterns worth adding at L3

### Unsafe YAML deserialization

```json
{
  "id": "PROJ-YAML-1",
  "name": "yaml.load without SafeLoader",
  "regex": "yaml\\.load\\([^)]*\\)(?![^)]*Loader\\s*=\\s*yaml\\.SafeLoader)",
  "severity": "high",
  "extensions": [".py"]
}
```

### Non-constant-time string comparisons

```json
{
  "id": "PROJ-TIMING-1",
  "name": "String comparison for secrets (timing attack)",
  "regex": "if\\s+(token|signature|hmac|hash)\\s*==",
  "severity": "medium",
  "extensions": [".py"]
}
```

(Fix: use `hmac.compare_digest` in Python.)

### XML External Entities (XXE)

```json
{
  "id": "PROJ-XXE-1",
  "name": "XML parsing without disabling external entities",
  "regex": "etree\\.parse\\(|xml\\.dom\\.minidom\\.parse\\(",
  "severity": "high",
  "extensions": [".py"]
}
```

(Fix: use `defusedxml`.)

## L3 practices outside the scan

### Crypto

- ✅ Use **only** vetted libraries: `cryptography` (Python), `crypto/...` (Go),
  `ring`/`rustls` (Rust), Web Crypto API (browser), libsodium.
- ❌ Never home-made crypto ("I invented a great algorithm").
- ✅ Key rotation per policy (90 days to 1 year depending on use).
- ✅ Proper KDF for passwords: argon2id (preferred), bcrypt (acceptable), scrypt.
- ❌ No `SHA256(password)` — always a slow KDF.

### Logging and observability

- ✅ **No plaintext secrets** in logs (passwords, tokens, raw PII).
- ✅ Immutable **audit trail** for sensitive operations (hash chain or signed
  events).
- ✅ Anomaly detection (request volume, geo-IP, user-agent).

### Network

- ✅ TLS 1.3 minimum (`MinVersion: tls.VersionTLS13` in Go,
  `ssl.TLSVersion.TLSv1_3` in Python).
- ✅ Filtered cipher suites (no RC4, 3DES, MD5).
- ✅ HSTS preload for public web apps.
- ✅ Certificate pinning on mobile clients / critical connections.

### Storage

- ✅ Encryption at rest (LUKS, BitLocker, cloud provider encryption-at-rest).
- ✅ PII encrypted at column level in the DB (not just "the DB is encrypted").
- ✅ Logs purged after a retention period compliant with GDPR / sector rules.

### Threat modeling

L3 implies an explicit threat model:

- **STRIDE** (Spoofing, Tampering, Repudiation, Information disclosure, Denial
  of service, Elevation of privilege) on each component.
- **Attack trees** on critical assets (data, admin accounts, secrets).
- Mitigations documented in `2_5_discussion.md` or `2_architecture.md`
  (covered by A###).

### Adversarial testing

- Third-party penetration test before production.
- Bug bounty (if budget allows).
- Fuzzing of critical inputs (libFuzzer, AFL, atheris).

## L3 limits

Even at L3, the automated scan is **not enough** on its own. You also need:

- security-focused human code review;
- regular external audit (at least once a year);
- active CVE monitoring;
- a tested incident response plan;
- backups with restoration tested quarterly.

L3 is the **floor**, not the ceiling. For very sensitive targets, aim for
ASVS L3 + NIST SSDF, plus ISO 27001 where applicable.

## When to step down from L3

Practically never. If a project was moved to L3, regulatory or business
constraints require it; stepping down means revisiting those security
commitments.

If some L3 findings are systematically false positives on your project,
**disable those patterns individually** rather than lowering the level.
