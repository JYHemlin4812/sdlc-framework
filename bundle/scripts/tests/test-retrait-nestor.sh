#!/usr/bin/env bash
# Tests écrits AVANT exécution (variante SANS Codex).
# Chaque test est marqué EXPECT=pass (comportement voulu aujourd'hui) ou EXPECT=FAIL
# (défaut connu : le test DOIT échouer tant que la correction n'est pas faite).
# Racines temporaires uniquement ; ~/.claude n'est jamais touché.
set -uo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; UNEXPECTED=0
report() { # name expect result(0|1)
    local name="$1" expect="$2" ok="$3"
    if [[ "$ok" == "1" ]]; then res=ok; else res=ko; fi
    if [[ "$expect" == "pass" && "$res" == "ok" ]] || [[ "$expect" == "FAIL" && "$res" == "ko" ]]; then
        printf 'ATTENDU  %-4s %s\n' "$res" "$name"; PASS=$((PASS+1))
    else
        printf 'INATTENDU %-4s (attendu %s) %s\n' "$res" "$expect" "$name"; UNEXPECTED=$((UNEXPECTED+1))
    fi
}

mk_root() { # fixture racine Claude avec domaine SDLC + éléments Nestor
    local R="$1"; rm -rf "$R"; mkdir -p "$R/skills/sdlc" "$R/commands/sdlc" "$R/agents"
    printf -- '---\nname: sdlc\n---\n' > "$R/skills/sdlc/SKILL.md"
    printf 'x\n' > "$R/commands/sdlc/dev.md"
    printf 'a\n' > "$R/agents/sdlc-a.md"
    printf 'NESTOR core\n' > "$R/NESTOR.md"
    printf 'nestor agent\n' > "$R/agents/nestor-b.md"
    printf '@NESTOR.md\nmes consignes\n' > "$R/CLAUDE.md"
}

# --- T1 (EXPECT pass) : aucune mention de Nestor hors des tests -------------
n=$(grep -ril nestor "$SCRIPTS" --exclude-dir=tests 2>/dev/null | wc -l)
report 'T1 aucune mention de Nestor dans bundle/scripts hors tests' pass $([[ $n -eq 0 ]] && echo 1 || echo 0)

# --- T2 (EXPECT FAIL tant que les tests ne sont pas migrés) -------------------
n=$(grep -ril nestor "$SCRIPTS/tests" --exclude='test-retrait-nestor*' 2>/dev/null | wc -l)
report 'T2 aucune mention de Nestor dans les autres tests' pass $([[ $n -eq 0 ]] && echo 1 || echo 0)

# --- T3 (EXPECT pass) : --remove-import n'existe plus -------------------------
mk_root "$T/r3"
bash "$SCRIPTS/install.sh" --remove-import --claude-root "$T/r3" >/dev/null 2>&1; rc=$?
report 'T3 install.sh refuse --remove-import (usage, code 2)' pass $([[ $rc -eq 2 ]] && echo 1 || echo 0)

# --- T4 (EXPECT pass) : --remove-core ne touche ni NESTOR.md, ni agent nestor-*, ni CLAUDE.md
mk_root "$T/r4"; cp "$T/r4/CLAUDE.md" "$T/r4.claude.before"
bash "$SCRIPTS/uninstall.sh" --claude-root "$T/r4" --discover --force --remove-core >/dev/null 2>&1
ok=1
[[ -f "$T/r4/NESTOR.md" ]] || ok=0
[[ -f "$T/r4/agents/nestor-b.md" ]] || ok=0
cmp -s "$T/r4/CLAUDE.md" "$T/r4.claude.before" || ok=0
report 'T4 --remove-core garde NESTOR.md, nestor-*, CLAUDE.md' pass $ok

# --- T5 (EXPECT pass) : --remove-core retire bien les agents sdlc-* -----------
mk_root "$T/r5"
bash "$SCRIPTS/uninstall.sh" --claude-root "$T/r5" --discover --force --remove-core >/dev/null 2>&1
report 'T5 --remove-core retire agents/sdlc-*' pass $([[ ! -e "$T/r5/agents/sdlc-a.md" ]] && echo 1 || echo 0)

# T6 (pass, corrigé DES2-02) : fichier personnel dans skills/sdlc conservé — la désinstallation
# ne supprime que les fichiers du bundle dont l'empreinte correspond au manifeste (file_hashes).
mk_root "$T/r6"; printf 'mes notes\n' > "$T/r6/skills/sdlc/mes-notes.md"
( . "$SCRIPTS/sync-lib.sh"
  h1=$(get_file_hash_byteexact "$T/r6/skills/sdlc/SKILL.md"); h2=$(get_file_hash_byteexact "$T/r6/commands/sdlc/dev.md")
  printf '{\n  "version": "4.0",\n  "skills": ["sdlc"],\n  "file_hashes": {\n    "skills/sdlc/SKILL.md": "%s",\n    "commands/sdlc/dev.md": "%s"\n  },\n  "checksum_sha256": "0"\n}\n' "$h1" "$h2" > "$T/r6/skills/sdlc/.install-manifest.json" )
bash "$SCRIPTS/uninstall.sh" --claude-root "$T/r6" --force >/dev/null 2>&1
report 'T6 fichier personnel dans skills/sdlc conservé (corrigé : pass)' pass $([[ -f "$T/r6/skills/sdlc/mes-notes.md" ]] && echo 1 || echo 0)

# --- T7 (EXPECT FAIL, défaut REV-07) : write_file_atomic vers un répertoire doit échouer
( . "$SCRIPTS/sync-lib.sh"; mkdir -p "$T/r7/.install-manifest.json"; printf 'x' | write_file_atomic "$T/r7/.install-manifest.json" >/dev/null 2>&1 ); rc=$?
report 'T7 écriture atomique sur un répertoire : code != 0 (corrigé : pass)' pass $([[ $rc -ne 0 ]] && echo 1 || echo 0)

# --- T8 (EXPECT pass) : verify ne publie plus le compteur core -----------------
out=$(bash "$SCRIPTS/verify.sh" --help 2>&1 || true)
report 'T8 verify.sh : plus de compteur core dans le code' pass $([[ $(grep -c 'core=' "$SCRIPTS/verify.sh") -eq 0 ]] && echo 1 || echo 0)

# --- T9 (EXPECT pass) : manifeste ancien (sans file_hashes) : avertissement avant suppression
mk_root "$T/r9"
printf '{\n  "version": "3.9",\n  "skills": ["sdlc"]\n}\n' > "$T/r9/skills/sdlc/.install-manifest.json"
out9=$(bash "$SCRIPTS/uninstall.sh" --claude-root "$T/r9" --force 2>&1)
report 'T9 manifeste sans file_hashes : avertissement affiché' pass $([[ "$out9" == *"no file_hashes"* ]] && echo 1 || echo 0)

# --- T10 (EXPECT pass) : manifeste à empreintes : aucun avertissement
mk_root "$T/r10"
( . "$SCRIPTS/sync-lib.sh"
  h1=$(get_file_hash_byteexact "$T/r10/skills/sdlc/SKILL.md")
  printf '{\n  "version": "4.0",\n  "skills": ["sdlc"],\n  "file_hashes": {\n    "skills/sdlc/SKILL.md": "%s"\n  }\n}\n' "$h1" > "$T/r10/skills/sdlc/.install-manifest.json" )
out10=$(bash "$SCRIPTS/uninstall.sh" --claude-root "$T/r10" --force 2>&1)
report 'T10 manifeste à empreintes : pas d avertissement' pass $([[ "$out10" != *"no file_hashes"* ]] && echo 1 || echo 0)

echo; echo "Résumé : $PASS attendus, $UNEXPECTED inattendus"
[[ $UNEXPECTED -eq 0 ]]
