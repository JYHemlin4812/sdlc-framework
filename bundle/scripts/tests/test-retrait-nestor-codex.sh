#!/usr/bin/env bash
# Variante AVEC Codex : suite A + corrections et tests retenus de la relecture Codex.
# EXPECT=pass : comportement voulu aujourd'hui. EXPECT=FAIL : défaut connu, le test DOIT échouer.
# Racines temporaires uniquement ; ~/.claude n'est jamais touché.
set -uo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)" || { echo 'mktemp en échec : arrêt'; exit 1; }
[[ -n "$T" && -d "$T" ]] || { echo 'racine temporaire invalide : arrêt'; exit 1; }
trap 'rm -rf -- "$T"' EXIT
PASS=0; UNEXPECTED=0
report() { # name expect ok(1|0)
    local name="$1" expect="$2" ok="$3" res
    if [[ "$ok" == "1" ]]; then res=ok; else res=ko; fi
    if [[ "$expect" == "pass" && "$res" == "ok" ]] || [[ "$expect" == "FAIL" && "$res" == "ko" ]]; then
        printf 'ATTENDU   %-4s %s\n' "$res" "$name"; PASS=$((PASS+1))
    else
        printf 'INATTENDU %-4s (attendu %s) %s\n' "$res" "$expect" "$name"; UNEXPECTED=$((UNEXPECTED+1))
    fi
}
mk_root() {
    local R="$1"; rm -rf -- "$R"; mkdir -p "$R/skills/sdlc" "$R/commands/sdlc" "$R/agents/nested"
    printf -- '---\nname: sdlc\n---\n' > "$R/skills/sdlc/SKILL.md"
    printf 'x\n' > "$R/commands/sdlc/dev.md"
    printf 'a\n' > "$R/agents/sdlc-a.md"
    printf 'NESTOR core\n' > "$R/NESTOR.md"
    printf 'nestor agent\n' > "$R/agents/nestor-b.md"
    printf '@NESTOR.md\nmes consignes\n' > "$R/CLAUDE.md"
}

# T1 (pass) : aucune mention de Nestor dans bundle/scripts hors tests
n=$(grep -ril nestor "$SCRIPTS" --exclude-dir=tests 2>/dev/null | wc -l)
report 'T1 aucune mention de Nestor hors tests' pass $([[ $n -eq 0 ]] && echo 1 || echo 0)

# T2 (FAIL tant que les autres tests ne sont pas migrés) : aucune mention dans les AUTRES tests
n=$(grep -ril nestor "$SCRIPTS/tests" --exclude='test-retrait-nestor*' 2>/dev/null | wc -l)
report 'T2 aucune mention de Nestor dans les autres tests' pass $([[ $n -eq 0 ]] && echo 1 || echo 0)

# T3 (pass) : --remove-import rejeté par le parseur (code 2, option inconnue)
mk_root "$T/r3"
out=$(bash "$SCRIPTS/install.sh" --remove-import --claude-root "$T/r3" 2>&1); rc=$?
report 'T3 install.sh : --remove-import refusé comme option inconnue' pass $([[ $rc -eq 2 && "$out" == *'Unknown option'* ]] && echo 1 || echo 0)

# T4 (pass) : --remove-core : rc 0, NESTOR.md et agent nestor-* et CLAUDE.md intacts (octets)
mk_root "$T/r4"; cp -- "$T/r4/CLAUDE.md" "$T/r4.before"; cp -- "$T/r4/NESTOR.md" "$T/r4.nestor"
bash "$SCRIPTS/uninstall.sh" --claude-root "$T/r4" --discover --force --remove-core >/dev/null 2>&1; rc=$?
ok=1; [[ $rc -eq 0 ]] || ok=0
cmp -s -- "$T/r4/CLAUDE.md" "$T/r4.before" || ok=0
cmp -s -- "$T/r4/NESTOR.md" "$T/r4.nestor" || ok=0
[[ -f "$T/r4/agents/nestor-b.md" ]] || ok=0
report 'T4 --remove-core rc0, NESTOR.md/nestor-*/CLAUDE.md intacts' pass $ok

# T5 (pass) : --remove-core retire agents/sdlc-* de premier niveau
mk_root "$T/r5"
bash "$SCRIPTS/uninstall.sh" --claude-root "$T/r5" --discover --force --remove-core >/dev/null 2>&1
report 'T5 --remove-core retire agents/sdlc-a.md' pass $([[ ! -e "$T/r5/agents/sdlc-a.md" ]] && echo 1 || echo 0)

# T6 (pass, corrigé DES2-02) : fichier personnel dans skills/sdlc conservé — la désinstallation
# ne supprime que les fichiers du bundle dont l'empreinte correspond au manifeste (file_hashes).
mk_root "$T/r6"; printf 'mes notes\n' > "$T/r6/skills/sdlc/mes-notes.md"
( . "$SCRIPTS/sync-lib.sh"
  h1=$(get_file_hash_byteexact "$T/r6/skills/sdlc/SKILL.md"); h2=$(get_file_hash_byteexact "$T/r6/commands/sdlc/dev.md")
  printf '{\n  "version": "4.0",\n  "skills": ["sdlc"],\n  "file_hashes": {\n    "skills/sdlc/SKILL.md": "%s",\n    "commands/sdlc/dev.md": "%s"\n  },\n  "checksum_sha256": "0"\n}\n' "$h1" "$h2" > "$T/r6/skills/sdlc/.install-manifest.json" )
bash "$SCRIPTS/uninstall.sh" --claude-root "$T/r6" --force >/dev/null 2>&1
report 'T6 fichier personnel dans skills/sdlc conservé (corrigé : pass)' pass $([[ -f "$T/r6/skills/sdlc/mes-notes.md" ]] && echo 1 || echo 0)

# T7 (FAIL, défaut REV-07) : write_file_atomic vers un répertoire : code non nul
( . "$SCRIPTS/sync-lib.sh"; mkdir -p "$T/r7/.install-manifest.json"; printf 'x' | write_file_atomic "$T/r7/.install-manifest.json" >/dev/null 2>&1 ); rc=$?
report 'T7 write_file_atomic vers répertoire : code != 0 (corrigé : pass)' pass $([[ $rc -ne 0 ]] && echo 1 || echo 0)

# T8 (pass) : sans manifeste ni --discover, refus et rien supprimé (R09)
mk_root "$T/r8"
bash "$SCRIPTS/uninstall.sh" --claude-root "$T/r8" --force >/dev/null 2>&1; rc=$?
report 'T8 sans manifeste ni --discover : refus, rien supprimé' pass $([[ $rc -ne 0 && -f "$T/r8/skills/sdlc/SKILL.md" ]] && echo 1 || echo 0)

# T9 (FAIL, défaut R06) : --remove-core supprime aussi un agent sdlc-* dans un sous-dossier
mk_root "$T/r9"; printf 'deep\n' > "$T/r9/agents/nested/sdlc-deep.md"
bash "$SCRIPTS/uninstall.sh" --claude-root "$T/r9" --discover --force --remove-core >/dev/null 2>&1
report 'T9 --remove-core retire agents/nested/sdlc-deep.md (corrigé : pass)' pass $([[ ! -e "$T/r9/agents/nested/sdlc-deep.md" ]] && echo 1 || echo 0)

# T10 (FAIL, défaut R13 / REV-01) : collision de sauvegarde skills/sdlc/dev.md vs commands/sdlc/dev.md
mk_root "$T/r10"; printf 'XBYTES\n' > "$T/r10/skills/sdlc/dev.md"; printf 'YBYTES\n' > "$T/r10/commands/sdlc/dev.md"
bash "$SCRIPTS/uninstall.sh" --claude-root "$T/r10" --discover --force >/dev/null 2>&1
okx=0; oky=0
grep -rq -- XBYTES "$T/r10" 2>/dev/null && okx=1
grep -rq -- YBYTES "$T/r10" 2>/dev/null && oky=1
report 'T10 sauvegarde : les deux fichiers homonymes sont conservés (corrigé : pass)' pass $([[ $okx -eq 1 && $oky -eq 1 ]] && echo 1 || echo 0)

# T11 (pass) : dry-run install n'écrit rien (racine cible inexistante)
rm -rf -- "$T/r11"
bash "$SCRIPTS/install.sh" --dry-run --claude-root "$T/r11" --source-root "$SCRIPTS/../../claude" >/dev/null 2>&1
report 'T11 dry-run install : aucune racine créée' pass $([[ ! -e "$T/r11" ]] && echo 1 || echo 0)

echo; echo "Résumé : $PASS attendus, $UNEXPECTED inattendus"
[[ $UNEXPECTED -eq 0 ]]
