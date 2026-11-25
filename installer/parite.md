# Parité des scripts et de l'installeur Python (design §11.2)

Une ligne par assertion des suites `bundle/scripts/tests`. Mise à jour à chaque étape ; complète avant tout retrait (E7).

## install (`test-install.sh`, `test-install.ps1`) → `installer/tests/test_install.py`

| Scénario | Assertion des scripts | Test Python | Écart voulu |
|---|---|---|---|
| C0 | invariants du texte des scripts (pas de rsync, sourcing de sync-lib, garde BASH_SOURCE) | — | sans objet : invariants propres aux scripts |
| C1 | cardinalités 14 skills / 19 commandes / 12 agents du vrai `claude/` | `Parity.test_c1b_*` : mesurées sur le live isolé, comparées aux mêmes littéraux | — |
| C1b | vrai `claude/` vers un live isolé ; skill tiers intact | `Parity.test_c1b_real_reference_into_isolated_live` | lancé avec `--allow-dirty` pour ne pas dépendre de l'état du dépôt |
| C2 | amorçage Git, agent imbriqué, H3 exclu, 0 écart, registre | `Parity.test_c2_bootstrap_git` | — |
| C3 | source hors Git : verify indisponible, non bloquant | `Parity.test_c3_archive_source` | Python compare en plus les octets live à la source |
| C4 | 2e install : « Already up to date », rien redéployé | `Parity.test_c4_idempotence_and_c5_force` | — |
| C5 | `--force` : réinstalle, sauvegarde horodatée | idem | — |
| C6 | skill tiers → 3, live intact | `Parity.test_c6_third_party_skill_guard` | — |
| C7 | `--dry-run` : 0 écriture | `Parity.test_c7_dry_run_writes_nothing` | Python ne crée pas non plus la racine live |
| C8 | chemin court 8.3 (.ps1) | `Parity.test_c8_short_path` | — |
| C9 | orphelin EXTRA non bloquant, conservé | `Parity.test_c9_orphan_is_not_fatal` | — |
| C10 | live abîmé → REPAIR | `Parity.test_c10_self_repair` | Python compare le live à la source (pas de sous-processus verify) |
| C11 | référence sale → avertissement, 0 | `Parity.test_c11_dirty_reference_refused_then_allowed` | **voulu (§7)** : 5 sans `--allow-dirty`, 0 avec |
| C12 | `name:` illisible → 3 | `Parity.test_c12_unreadable_name_fails_closed` | — |
| C13 | `--force --no-backup` : aucune sauvegarde `sdlc-*` | `Parity.test_c13_force_no_backup` | Python sauvegarde quand même un fichier d'origine inconnue (§3) |
| C14 | import externe conservé ; `--remove-import` → 2 | `Parity.test_c14_external_import_preserved` | — |
| C15 | `CLAUDE.local.md` créé vide, jamais écrasé ; dry-run sans écriture | `Parity.test_c15_local_overlay`, `test_c7_*` | — |
| E1-R5-04 | écart sur référence propre → exactement 7, registre non publié | `test_exit_parity.test_install_clean_reference_drift_gives_7_sh` et `_ps1` (un test par interpréteur, ignoré visiblement s'il manque) ; `Contract.test_e1_r5_04_*` (Python, par injection) | **voulu (décision E3)** : Python déploie les blobs de HEAD ; la même fixture donne 0 (`Contract.test_clean_reference_deploys_head_bytes`) |

## verify (`test-verify.sh`, `test-verify.ps1`) → `installer/tests/test_verify.py`

| Scénario | Assertion | Test Python | Écart voulu |
|---|---|---|---|
| T1 | identique → 0 | `test_t1_identical` | — |
| T2 | lecture seule (réf. et live inchangés) | `test_t2_read_only`, `test_index_not_rewritten` | Python vérifie aussi l'index Git |
| T3 | HEAD commité, pas l'arbre de travail | `test_t3_committed_head_not_working_tree` | — |
| T4 | `.pyc` live ignorés | `test_t4_pyc_ignored` | — |
| T5 | planchers dérivés, aucun littéral | `test_t5_floors_derived` | — |
| T6a-c | MISSING, HASH DIFF, EXTRA → ≠ 0 | `test_t6_differences` | Python vérifie le code exact (1) et la liste |
| T7 | skill/agent tiers ignorés | `test_t7_third_party_ignored` | — |
| T8, T9e | projection du domaine (fichier libre, casse) | `test_t8_t9e_domain_projection` | — |
| — | indisponible → 2 | `test_unavailable_gives_2` | — |
