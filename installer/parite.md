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

## uninstall (`test-uninstall.sh`, `test-uninstall.ps1`, cas uninstall des trois `test-retrait-*`) → `installer/tests/test_uninstall.py`

Écarts voulus communs :

- Sauvegarde : seuls les fichiers supprimés (et le registre) sont sauvegardés ; les scripts copiaient les dossiers entiers, fichiers conservés compris. Un fichier conservé reste en place, il n'a donc pas besoin de sauvegarde.
- `--discover` sans registre : skills dérivés du disque (dossiers `skills/sdlc*` dont le `name:` commence par `sdlc`, §4) ; les scripts utilisaient une liste fixe de quatre skills.
- JSON invalide (§8.6.1.b, R3-07) : code 2 sans `--discover` ; `uninstall.sh` extrayait des champs par `grep` et continuait. Cas de migration : relancer avec `--discover`.
- Fichiers exclus de la synchro (`*.bak`, `__pycache__`…) dans un dossier ciblé : conservés comme par les scripts, mais signalés au niveau du dossier (« kept (not empty) ») et non fichier par fichier.
- Les registres des fixtures des fixtures sont écrits par un vrai installeur (Python, ou `install.sh` de `667d7ed`). Les registres écrits à la main des scripts (sans `checksum_sha256`) sont corrompus pour Python (décision E2), donc code 2 sans `--discover` (`test_hand_written_registry_without_aggregate_is_corrupt`).

| Scénario | Assertion des scripts | Test Python | Écart voulu |
|---|---|---|---|
| U0 | invariants du texte des scripts | — | sans objet |
| U1 | défaut : skills et commands retirés ; agents, PERSO.md, CLAUDE.md intacts ; sauvegarde sans agents | `test_u1_default_keeps_agents_and_core` | sauvegarde sous `<live>/_backups/uninstall-*` au lieu de `skills/_backups/sdlc-uninstall-*`, comme install |
| U2 | `--remove-core` : agents sdlc-* (imbriqués compris) retirés et sauvegardés ; le reste intact | `test_u2_remove_core` | idem |
| U3 | `--remove-core` sans agents : 0 | `test_u3_remove_core_without_agents` | — |
| U4 | confirmation refusée : 0, live intact | `test_u4_confirmation_refused` | fin d'entrée (EOF) = refus |
| retrait T4, T5, T9 | `--discover --remove-core` : agents sdlc-* retirés (imbriqués compris), autres agents, NESTOR.md et CLAUDE.md intacts | `test_retrait_t4_t5_t9_remove_core_with_discover` | — |
| retrait T6, T6b | fichier personnel et fichier modifié conservés | `test_retrait_t6_personal_and_modified_files_kept` | — |
| retrait T8 | sans registre ni `--discover` : refus, rien supprimé | `test_retrait_t8_no_registry_no_discover` | — |
| retrait T10 | homonymes `skills/sdlc/dev.md` et `commands/sdlc/dev.md` tous deux sauvegardés | `test_retrait_t10_homonyms_both_backed_up` | sous `--discover`, seuls les fichiers prouvés par l'historique Git sont supprimés (§8.6.1.b) ; sans historique lisible, rien n'est supprimé |
| retrait T9, T12, T10, T13 | registre sans `file_hashes` : avertissement ; avec : aucun | `test_retrait_t9_t12_legacy_registry`, `test_registry_file_hashes_without_history` | avec l'historique Git lisible (`--ref`), l'appartenance est prouvée et une modification manuelle est conservée (§3) |
| retrait T1-T3, T7, T8 (verify), T11 | invariants du texte, `--remove-import`, écriture atomique, dry-run install | `test_install` (C14, C7), `test_fsops` | T1/T2 : sans objet (texte des scripts) |

## capture (`test-capture.sh`, `test-capture.ps1`) → `installer/tests/test_capture.py`

Écarts voulus communs à capture et restore :

- Pas de verrou ni d'écriture en dry-run (design §2) ; les scripts prenaient le verrou même en dry-run.
- Verrou toujours `<live>/.sync.lock` (§2) : pas d'option `--lock`. `--manifest-path` et `--conflict-log` restent réglables, mais refusés (2) dans le worktree de la référence (§5.1).
- `--ref` désigne la racine du dépôt (comme verify), pas le dossier `claude/` ; un sous-dossier est refusé (2).
- Chaque fichier est lu une fois : les octets classés sont ceux copiés et enregistrés dans la base (les scripts relisaient au moment de la copie).
- Git est appelé avec `--literal-pathspecs` : un `[` dans un nom n'est jamais un motif.
- `--allow-dirty` refusé (2), §7.
- Une clé de base qui n'est pas un chemin relatif sûr rend la base non fiable (6).
- Fichiers d'état (base, `conflicts.log`) : `..` refusé dans l'argument brut, aucun lien ni jonction sur le chemin (3) ; base et journal distincts, jamais un fichier géré du live (domaine, registre, verrou, racine `_backups`) (2) ; journal avec d'autres liens physiques refusé (3) (E5-R1-02, E5-R1-03, E5-R2-03, E5-R2-04).
- L'inventaire complet de HEAD (liens du domaine refusés) est lu avant toute écriture, premier lancement compris (E5-R2-08, E5-R3-04) ; le post-contrôle vérifie aussi dans le HEAD final les chemins repris d'une capture interrompue (E5-R3-03) : un lien encore commité dans le domaine refuse la capture (3) tant que sa suppression n'est pas commitée.
- Capture interrompue dont le chemin a été modifié dans l'index ou l'arbre depuis : bloquée (3), rien écrit, index conservé (E5-R2-05). `git status` lu avec `--no-renames` (E5-R2-06).
- Capture interrompue (R3-05) : la base n'est publiée que si le blob de HEAD égale les octets capturés ; sinon le chemin reste à commiter (un ajout ignoré par Git donne 4 à chaque relance, jamais un faux succès) (E5-R1-04). Les scripts se fiaient à `git status`.
- Post-contrôle de capture : HEAD contient exactement les octets capturés et ces chemins sont propres ; sinon 7.
- Pathspecs transmis à `git add` et `git commit` par l'entrée standard (`--pathspec-from-file`, Git 2.26 ou plus) : pas de limite de ligne de commande (E5-R1-08).

| Scénario | Assertion des scripts | Test Python | Écart voulu |
|---|---|---|---|
| C1 | modified-both sans `--lww` → 3, diff affiché, rien écrit, pas de `conflicts.log` | `Parity.test_c1_modified_both_blocks` | diff unifié Python (`difflib`, 200 lignes au plus) au lieu de `git diff --no-index` |
| C2 | texte : `git add`/`commit` avec pathspec, jamais `-A` | — | sans objet (texte des scripts) ; couvert par C2b |
| C2b | commit limité : S1 hors domaine, skill tiers, S2 indexé hors `claude/`, S3 deleted-ref ignoré | `Parity.test_c2b_commit_scope` | Python vérifie en plus que README.md reste indexé (§7) |
| C3, D3 | base et `conflicts.log` hors worktree, écriture atomique, ref == live, base réécrite | `Parity.test_c3_d3_state_outside_worktree_and_success` | — |
| C4 | post-commit salit le chemin commité → 7, base intacte | `Parity.test_c4_post_check_failure` | — |
| C5a | added-live capturé et commité, base mise à jour | `Parity.test_c5a_added_live_captured` | — |
| C5b | deleted-live → 3, ref intacte, pas de commit | `Parity.test_c5b_deleted_live_blocked` | — |
| C6a | dry-run : 0 commit, 0 fichier, base intacte | `Parity.test_c6a_dry_run_writes_nothing` | pas de verrou (voir plus haut) |
| C6b | dry-run reflète le blocage ; pas de `conflicts.log` | `Parity.test_c6b_dry_run_reflects_block` | — |
| D1 | premier lancement : seed, blocage (5), `--adopt` | `Parity.test_d1_first_run_seed_block_adopt` | — |
| D2 | base corrompue → FAIL CLOSED, pas de commit | `Parity.test_d2_corrupt_base_fails_closed` | code exact 6 vérifié |
| D4 | `--lww --provenance live` : journalisé, live gagne, commit, référence perdante sauvegardée hors worktree | `Parity.test_d4_lww_live_winner_logged_and_backed_up` | sauvegarde sous `<live>/_backups/capture-lww-*` au lieu de `<dossier de conflicts.log>/_backups` |
| E1, E2 | R3-05 : commit refusé puis relancé ; commit fait mais base non publiée | `Parity.test_e1_*`, `Parity.test_e2_*` | — |
| R3-08 | `--lww` par défaut : la référence reste intacte, rien capturé | `Contract.test_r3_08_default_lww_keeps_the_reference` | — |
| §7 | LWW avec modification locale de la référence et fichier non suivi sans rapport | `Contract.test_lww_with_a_local_reference_change_and_unrelated_dirt` | — |
| PYI-01 | capture puis install depuis le commit produit | `Contract.test_pyi_01_capture_then_install_from_the_commit` | — |
| PYI-04 | base, `conflicts.log` ou live dans le worktree → 2, rien créé | `Contract.test_pyi_04_state_inside_worktree_refused` | — |
| §5.2.4 | un dossier là où va un fichier capturé → 3 avant `conflicts.log`, sauvegarde et copie, dry-run compris | `Contract.test_refusal_before_any_write_dry_run_included` | les scripts sautaient le chemin (Copy-Tree) |
| — | `a[1].md` capturé, voisin sale `a1.md` non commité | `Contract.test_literal_pathspecs` | — |

## restore (`test-restore.sh`, `test-restore.ps1`) → `installer/tests/test_restore.py`

Écarts voulus (en plus des écarts communs ci-dessus) :

- Les octets déployés sont les blobs de HEAD (`git cat-file`), pas l'arbre de travail (décision E3, §3) ; un fichier ignoré par Git dans `claude/` n'est jamais déployé. Pas de dossier de staging : les octets sont en mémoire.
- Sauvegardes sous `<live>/_backups/restore-*` (comme install et uninstall) ; pas d'option `--backup-root`.
- Post-contrôle par `verify` en processus, pas en sous-processus ; même règle : toute différence (EXTRA compris) ou verify indisponible → 7.
- Après un post-contrôle propre : trace de déploiement dans le registre d'installation s'il existe (§4, R3-06) ; les scripts n'écrivaient rien. La trace est validée avant la première mutation, dry-run compris ; une ancienne clé qui ne diffère d'une nouvelle que par la casse est remplacée (E5-R1-05, E5-R1-07).
- Fast-forward (E5-R1-01) : le plan est fait contre le commit amont, puis l'avance rapide n'est appliquée qu'après tous les refus ; un blocage laisse HEAD, l'index et la référence intacts. Les scripts avançaient la branche avant de classer. Ordre : référence sale (5) avant divergence (4) ; le dry-run lit le commit amont sans avancer la branche et renvoie 4 en cas de divergence (les scripts l'ignoraient en dry-run). Une branche locale en avance sur son amont n'est pas une divergence : rien à appliquer (E5-R2-02). Avant l'avance rapide (dry-run compris), restore refuse (5) si elle écraserait quelque chose dans le dépôt : un fichier non suivi ou ignoré là où l'amont ajoute un chemin, un fichier là où il faut un dossier, ou un fichier suivi modifié localement ; un dossier ignoré qui peut coexister ne bloque pas. Le merge passe aussi `--no-overwrite-ignore` (E5-R2-01, E5-R3-01, E5-R3-02 ; `git read-tree -n` ne voit pas les fichiers ignorés, mesuré avec Git 2.54).
- Trace : les deux tables finales (`file_hashes`, `retained_hashes`) sont validées ensemble ; une ancienne clé dont le fichier ou un dossier parent ne diffère que par la casse est remplacée (E5-R2-07).

| Scénario | Assertion des scripts | Test Python | Écart voulu |
|---|---|---|---|
| C0 | texte : pas de robocopy, Copy-Tree, post-contrôle verify | — | sans objet (texte des scripts) |
| C1, C7 | modified-ref et added-ref déployés, sauvegarde de l'ancien live, aucun temporaire restant | `Parity.test_c1_c7_nominal_restore` | — |
| C2 | deleted-ref : supprimé du live, sauvegardé | `Parity.test_c2_base_aware_deletion` | — |
| C3 | modified-live → 3 sans `--force-restore`, déployé et sauvegardé avec | `Parity.test_c3_modified_live_blocked_then_forced` | — |
| C4 | modified-both → 3 même avec `--force-restore` | `Parity.test_c4_modified_both_blocked_even_forced` | — |
| C5 | added-live protégé ; post-contrôle → 7 | `Parity.test_c5_added_live_protected` | — |
| C6 | dry-run : live et sauvegardes intacts, liste affichée | `Parity.test_c6_dry_run_writes_nothing` | — |
| C8 | référence sale → 5, rien écrit | `Parity.test_c8_canonical_guard` | vérifié aussi en dry-run |
| C9 | dry-run n'avance pas la branche | `Parity.test_c9_dry_run_does_not_advance` | — |
| D1 | base corrompue → FAIL CLOSED, rien écrit | `Parity.test_d1_corrupt_base_fails_closed` | code exact 6 vérifié |
| — | fast-forward puis déploiement ; divergence → 4 | `Contract.test_fast_forward_then_deploy`, `Contract.test_diverged_gives_4` | — |
| — | base absente = base vide, jamais écrite par restore | `Contract.test_absent_base_is_empty` | — |
| §5.2.4 | un dossier là où va un fichier déployé → 3, dry-run compris, rien écrit | `Contract.test_refusal_before_any_write_dry_run_included` | — |
| R3-06 | install A → restore B → uninstall sans historique : B supprimé, modification manuelle conservée | `Sequence.test_r3_06_uninstall_after_restore_without_history` | — |
| R3-06 (§13 littéral) | install A → restore B → install C (archive **sans** le fichier de B) → uninstall sans historique : B intact supprimé, B modifié à la main conservé | `Sequence.test_r3_06_literal_install_c_without_the_b_file`, `test_install.Retained` | décision JYH 2026-11-25 (option 1.4.1) : install garde dans `retained_hashes` les fichiers déjà enregistrés que la source ne livre plus, encore présents et identiques ; limite : un tel fichier sous un dossier `skills/<s>` absent de la liste `skills` n'est pas visé par uninstall |
| PYI-03 | install A → restore B → install C (archive) : B reconnu ; modification manuelle après B sauvegardée | `Sequence.test_pyi_03_install_a_restore_b_install_c_from_archive` | — |

## scan-fuites (`scan-fuites.ps1`, `scan-fuites.sh` ; aucune suite de tests des scripts) → `installer/tests/test_scanfuites.py`

Référence : `scan-fuites.ps1` (déclaré comme référence par l'en-tête de `scan-fuites.sh`).

| Scénario | Comportement des scripts | Test Python | Écart voulu |
|---|---|---|---|
| rapport complet | zones publique et interne, sonde d'historique, verdict | `ScriptParity.test_ps1` : fichier identique octet pour octet à celui de `scan-fuites.ps1` (séparateur de ligne natif : CRLF sous Windows) | — |
| idem, `.sh` | idem | `ScriptParity.test_sh` | `scan-fuites.sh` s'écarte de sa référence sur un point : il analyse les fichiers à extension binaire (`img/logo.png` listé et compté) ; Python suit `.ps1`. Le test vérifie cette entrée exacte, puis compare le reste octet pour octet (LF et barres obliques du chemin racine sous Windows mis à part) |
| contenu | motifs niveau 1, niveau 2 sans casse, une ligne comptée une fois en zone interne, binaires et exclusions ignorés | `Behaviour.test_report_content` | — |
| absent | niveau 2 absent : « Generic mode only », lecture seule (index Git compris) | `Behaviour.test_generic_mode_and_read_only` | — |
| défaut | rapport sous `SDLC_PM/SP6-productisation/` | `Behaviour.test_default_report_under_sdlc_pm` | — |
| codes | racine absente → 2 | `Behaviour.test_codes_2` | **voulu** : chemin du rapport qui est un dossier → 2 (§5.1 point 3) ; motif niveau 2 invalide → 2 sans rapport (le script PowerShell s'arrêtait sur une exception) |
| sans git | sonde indisponible | `Behaviour.test_no_git` | — |

Écarts voulus communs : les motifs de niveau 2 sont des expressions Python (`re`), plus .NET ni ERE, lus avec les marques d'ordre des octets reconnues par `Get-Content` (UTF-8, UTF-16, UTF-32), sinon en UTF-8 strict (fichier illisible → 2) ; la sonde d'historique lit les objets Git avec les mêmes motifs Python au lieu de `git grep -E`, fichiers réguliers seulement (pas les liens), et n'est pas lancée dans un clone partiel (`extensions.partialClone` ou un distant `promisor` : lecture seule garantie) ; les liens symboliques de l'arbre de travail ne sont ni suivis ni lus ; un dossier illisible arrête le scan (2) au lieu d'être sauté en silence ; le rapport ne peut pas aller dans des métadonnées Git (un composant `.git`, ou le dossier Git du dépôt scanné ou du dépôt qui contient la destination) (2) ; sans git, le rapport est écrit avec la mention « probe not run » ; les dossiers exclus de la synchronisation ne sont jamais ouverts ; un fichier de motifs inaccessible donne 2 ; un `--motifs-path` explicite dont le dossier parent manque, ou qui n'est pas un fichier, donne 2 (le fichier par défaut absent reste en mode générique, comme les scripts) ; une destination de rapport est refusée si un nom `.git` apparaît dans son chemin (partie encore à créer comprise) ou si un ancêtre a la structure d'un dossier Git (`objects/`, `refs/` et un `HEAD` de forme Git, vérifiée sans git) ; une erreur d'écriture du rapport donne 2 ; un fichier vide n'a aucune ligne ; un nom de fichier non UTF-8 est affiché avec des échappements ; le scanner Python s'exclut lui-même (`installer/sdlc_installer/scanfuites.py`), comme les deux scripts.
