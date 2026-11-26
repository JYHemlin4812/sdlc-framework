# Parité des scripts et de l'installeur Python (design §11.2)

Une ligne par assertion des suites `bundle/scripts/tests` (retirées en E7 ; leur dernier état est celui du commit `c7c437f`). Complète avant tout retrait (E7) : install, verify, uninstall, retrait, capture, restore, sync-lib, sync-bdd, planchers et scan-fuites.

## install (`test-install.sh`, `test-install.ps1`) → `installer/tests/test_install.py`

| Scénario | Assertion des scripts | Test Python | Écart voulu |
|---|---|---|---|
| C0 | invariants du texte des scripts (pas de rsync, sourcing de sync-lib, garde BASH_SOURCE) | — | sans objet : invariants propres aux scripts |
| C1 | vrai `claude/` : 14 skills `sdlc*` | `Verify.test_p4_real_head_inventory_cardinalities` (HEAD) et `Parity.test_c1b_real_reference_into_isolated_live` (live déployé) | **voulu (design §2)** : le script comptait les dossiers `skills/sdlc*` de l'arbre de travail, où un dossier vide non suivi comptait ; Python compte depuis HEAD et le live déployé, jamais l'arbre de travail. Un dossier vide n'est pas dans Git et n'est jamais déployé |
| C1 | vrai `claude/` : 19 commandes | `Verify.test_p4_real_head_inventory_cardinalities` (HEAD) et `Parity.test_c1b_real_reference_into_isolated_live` (live déployé) | idem : mesure depuis HEAD, pas depuis l'arbre de travail |
| C1 | vrai `claude/` : 12 agents `sdlc-*` | `Verify.test_p4_real_head_inventory_cardinalities` (HEAD) et `Parity.test_c1b_real_reference_into_isolated_live` (live déployé) | idem : mesure depuis HEAD, pas depuis l'arbre de travail |
| C1b | skill `sdlc-delivery` déployé (`skills/sdlc-delivery/SKILL.md`) | `Parity.test_c1b_real_reference_into_isolated_live` | lancé avec `--allow-dirty` pour ne pas dépendre de l'état du dépôt |
| C1b | liste de contrôle de messagerie de `sdlc-architecture` (`references/messaging.md`) | `Parity.test_c1b_real_reference_into_isolated_live` | lancé avec `--allow-dirty` pour ne pas dépendre de l'état du dépôt |
| C1b | fiche de contrat de `sdlc-contract` (`assets/contract.md`) | `Parity.test_c1b_real_reference_into_isolated_live` | lancé avec `--allow-dirty` pour ne pas dépendre de l'état du dépôt |
| C1b | gabarit `5_delivery` déployé (`skills/sdlc/assets/5_delivery.template.md`) | `Parity.test_c1b_real_reference_into_isolated_live` | lancé avec `--allow-dirty` pour ne pas dépendre de l'état du dépôt |
| C1b | `SOURCES.md` déployé (`skills/sdlc/SOURCES.md`) | `Parity.test_c1b_real_reference_into_isolated_live` | lancé avec `--allow-dirty` pour ne pas dépendre de l'état du dépôt |
| C1b | 14 skills `sdlc*` dans le live (mesure sur le live, littéraux de C1) | `Parity.test_c1b_real_reference_into_isolated_live` | idem |
| C1b | skill tiers hors domaine (`skills/se-tdd/SKILL.md`) intact, octet pour octet | `Parity.test_c1b_real_reference_into_isolated_live` | idem |
| C2 | skills, commandes et agents de premier niveau déployés, octets égaux à la source | `Parity.test_c2_bootstrap_git` | — |
| C2 | agent imbriqué (`agents/nested/sdlc-deep.md`) déployé | `Parity.test_c2_bootstrap_git` | — |
| C2 | copie imbriquée H3 non déployée | `Parity.test_c2_bootstrap_git` | — |
| C2 | inventaire du live égal à celui de la référence (0 écart) | `Parity.test_c2_bootstrap_git` | — |
| C2 | sortie « 0 drift » | `Parity.test_c2_bootstrap_git` | — |
| C2 | registre d'installation écrit | `Parity.test_c2_bootstrap_git` | Python vérifie en plus le commit source, les empreintes et la version |
| C3 | source hors Git : code 0 (verify indisponible, non bloquant) | `Parity.test_c3_archive_source` | — |
| C3 | déploiement fait malgré verify indisponible (`skills/sdlc/SKILL.md`) | `Parity.test_c3_archive_source` | Python compare les octets du live à ceux de la source |
| C3 | agent imbriqué déployé (`agents/nested/sdlc-deep.md`) | `Parity.test_c3_archive_source` | Python compare les octets du live à ceux de la source |
| C3 | message « unavailable » présent | `Parity.test_c3_archive_source` | Python vérifie en plus l'absence de `source_commit` dans le registre |
| C4 | 2e install : code 0 et « Already up to date » (empreinte inchangée) | `Parity.test_c4_idempotence_and_c5_force` | — |
| C4 | 2e install : rien redéployé (aucun « deployed ») | `Parity.test_c4_idempotence_and_c5_force` | — |
| C5 | `--force` : code 0, contourne l'idempotence (pas de « Already up to date ») | `Parity.test_c4_idempotence_and_c5_force` | — |
| C5 | `--force` : sauvegarde horodatée des fichiers du live avant remplacement | `Parity.test_c4_idempotence_and_c5_force` | — |
| C6 | skill tiers : code 3 | `Parity.test_c6_third_party_skill_guard` | — |
| C6 | ABORT signalé | `Parity.test_c6_third_party_skill_guard` | — |
| C6 | `skills/sdlc/SKILL.md` tiers non écrasé, octet pour octet | `Parity.test_c6_third_party_skill_guard` | le test compare l'instantané complet du live avant et après |
| C6 | aucun déploiement (abandon avant toute écriture) | `Parity.test_c6_third_party_skill_guard` | idem : instantané complet du live identique |
| C7 | `--dry-run` : code 0 | `Parity.test_c7_dry_run_writes_nothing` | — |
| C7 | `--dry-run` : aucun fichier écrit côté live | `Parity.test_c7_dry_run_writes_nothing` | Python ne crée pas non plus la racine live (instantané vide, et racine absente vérifiée) |
| C7 | `--dry-run` : aucune sauvegarde (`_backups`) | `Parity.test_c7_dry_run_writes_nothing` | couvert par l'instantané vide du live |
| C7 | `--dry-run` signalé (liste de ce qui serait déployé) : « DRY-RUN » dans la sortie | `Parity.test_c7_dry_run_writes_nothing` | — |
| C8 | racine live en forme courte 8.3 : code 0 (normalisée, verify sans écart) | `Parity.test_c8_short_path` | propre à Windows (ignoré ailleurs, ou si les noms 8.3 sont désactivés) |
| C8 | post-contrôle « 0 drift » malgré le chemin court | `Parity.test_c8_short_path` | idem |
| C8 | déploiement réel sous le chemin court (agent imbriqué `agents/nested/sdlc-deep.md`) | `Parity.test_c8_short_path` | idem |
| C9 | orphelin : mise à jour avec `--force`, code 0, non bloquant | `Parity.test_c9_orphan_is_not_fatal` | — |
| C9 | orphelin classé EXTRA | `Parity.test_c9_orphan_is_not_fatal` | — |
| C9 | installation additive : orphelin non retiré | `Parity.test_c9_orphan_is_not_fatal` | — |
| C9 | registre écrit malgré l'orphelin | `Parity.test_c9_orphan_is_not_fatal` | Python vérifie en plus que l'orphelin n'est pas dans `file_hashes`, et qu'une 2e install signale l'orphelin sans « 0 drift » |
| C10 | live abîmé : réinstallation, code 0 | `Parity.test_c10_self_repair` | — |
| C10 | dommage détecté : REPAIR | `Parity.test_c10_self_repair` | — |
| C10 | pas de raccourci « Already up to date » | `Parity.test_c10_self_repair` | — |
| C10 | fichier restauré par l'auto-réparation | `Parity.test_c10_self_repair` | Python compare le live à la source (pas de sous-processus verify) |
| C11 | référence sale → avertissement, 0 | `Parity.test_c11_dirty_reference_refused_then_allowed` | **voulu (§7)** : 5 sans `--allow-dirty`, 0 avec |
| C12 | `skills/sdlc/SKILL.md` du live sans `name:` lisible : abandon, code 3 | `Parity.test_c12_unreadable_name_fails_closed` | — |
| C12 | abandon signalé (« unreadable » dans la sortie ; le script acceptait aussi « fail-closed ») | `Parity.test_c12_unreadable_name_fails_closed` | — |
| C12 | cible non identifiable non écrasée, octet pour octet | `Parity.test_c12_unreadable_name_fails_closed` | le test compare l'instantané complet du live avant et après |
| C13 | `--force --no-backup` : code 0, aucun dossier de sauvegarde `sdlc-*` | `Parity.test_c13_force_no_backup` | Python sauvegarde quand même un fichier d'origine inconnue (§3) |
| C13 | déploiement fait malgré `--no-backup` | `Parity.test_c13_force_no_backup` | — |
| C14a, C14b | ligne `@keep-me.md` conservée une seule fois après l'install, puis après `--force` ; contenu privé conservé | `Parity.test_c14_external_import_preserved` | — |
| C14a | `CLAUDE.md` hors du domaine (jamais dans la liste verte) | `DomainRules.test_in_domain` (test_domain.py) | — |
| C14c | `--remove-import` refusé : code 2, diagnostic d'`argparse` (« unrecognized arguments », `--remove-import`) | `Parity.test_c14_external_import_preserved` | message d'`argparse` au lieu de `Unknown option` |
| C14c | ligne `@keep-me.md` toujours présente après le refus (`CLAUDE.md` identique à l'octet) | `Parity.test_c14_external_import_preserved` | — |
| C14d | `--dry-run` : code 0, `CLAUDE.md` non créé | `Parity.test_c7_dry_run_writes_nothing` (instantané du live vide) | — |
| C15a | `CLAUDE.local.md` créé vide, une seule ligne `@CLAUDE.local.md`, hors du domaine | `Parity.test_c15_local_overlay` | — |
| C15b | `CLAUDE.local.md` non vide jamais écrasé par `--force` ; une seule ligne d'import (idempotence) | `Parity.test_c15_local_overlay` | — |
| C15c | dry-run : ni `CLAUDE.md` ni `CLAUDE.local.md` créés | `Parity.test_c7_dry_run_writes_nothing` (instantané du live vide) | — |
| E1-R5-04 | écart sur référence propre : code exactement 7 (scripts) | `test_exit_parity.test_install_clean_reference_drift_gives_7_sh` et `_ps1` (un test par interpréteur, ignoré visiblement s'il manque) ; `Contract.test_e1_r5_04_drift_gives_exactly_7_and_no_registry` (Python, par injection) | **voulu (décision E3)** : Python déploie les blobs de HEAD ; la même fixture donne 0 (`Contract.test_clean_reference_deploys_head_bytes`) |
| E1-R5-04 | première installation en écart : aucun registre créé, ni `CLAUDE.md`, ni verrou résiduel | `Contract.test_e1_r5_04_drift_gives_exactly_7_and_no_registry` | propre à Python (hors scripts) |
| E1-R5-04 | installation en écart par-dessus un registre antérieur : code 7 et registre antérieur conservé octet pour octet | `Contract.test_e1_r5_04_previous_registry_untouched` | propre à Python (hors scripts) |

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

## uninstall (`test-uninstall.sh`, `test-uninstall.ps1`) → `installer/tests/test_uninstall.py`

Écarts voulus communs :

- Sauvegarde : seuls les fichiers supprimés (et le registre) sont sauvegardés ; les scripts copiaient les dossiers entiers, fichiers conservés compris. Un fichier conservé reste en place, il n'a donc pas besoin de sauvegarde.
- `--discover` sans registre : skills dérivés du disque (dossiers `skills/sdlc*` dont le `name:` commence par `sdlc`, §4) ; les scripts utilisaient une liste fixe de quatre skills.
- JSON invalide (§8.6.1.b, R3-07) : code 2 sans `--discover` ; `uninstall.sh` extrayait des champs par `grep` et continuait. Cas de migration : relancer avec `--discover`.
- Fichiers exclus de la synchro (`*.bak`, `__pycache__`…) dans un dossier ciblé : conservés comme par les scripts, mais signalés au niveau du dossier (« kept (not empty) ») et non fichier par fichier.
- Les registres des fixtures des fixtures sont écrits par un vrai installeur (Python, ou `install.sh` de `667d7ed`). Les registres écrits à la main des scripts (sans `checksum_sha256`) sont corrompus pour Python (décision E2), donc code 2 sans `--discover` (`test_hand_written_registry_without_aggregate_is_corrupt`).

| Scénario | Assertion des scripts | Test Python | Écart voulu |
|---|---|---|---|
| U0 | agents/core dérivés de `get_domain_relpaths` / `Get-DomainRelPaths` (source unique) | — | sans objet (texte des scripts) |
| U0 | le script ne nomme aucun composant externe | — | sans objet (texte des scripts) |
| U0 | logique enveloppée dans `invoke_uninstall` / `Invoke-Uninstall` (testable) | — | sans objet (texte des scripts) |
| U0 | garde d'exécution automatique (`BASH_SOURCE` / `InvocationName`) | — | sans objet (texte des scripts) |
| U0 | drapeau `--remove-core` déclaré (son comportement est vérifié en U2) | — | sans objet (texte des scripts) |
| U0 | aucune liste `AGENTS_DEFAULT` codée en dur | — | sans objet (texte des scripts) |
| U0 | aucun nom d'agent littéral codé en dur (`sdlc-architect`) | — | sans objet (texte des scripts) |
| U0 | périmètre des agents dérivé du préfixe de domaine (`agents/*`), pas d'une liste de noms | — | sans objet (texte des scripts) |
| U1 | défaut : code 0 ; skills et `commands/sdlc` retirés | `test_u1_default_keeps_agents_and_core` | — |
| U1 | agents (racine et imbriqué), agent tiers et `PERSO.md` intacts | `test_u1_default_keeps_agents_and_core` | — |
| U1 | `CLAUDE.md` intact, identique à l'octet | `test_u1_default_keeps_agents_and_core` | — |
| U1 | dossier de sauvegarde horodaté créé, avec les skills | `test_u1_default_keeps_agents_and_core` | sauvegarde sous `<live>/_backups/uninstall-*` au lieu de `skills/_backups/sdlc-uninstall-*`, comme install |
| U1 | la sauvegarde ne contient pas `agents/` (sans `--remove-core`) | `test_u1_default_keeps_agents_and_core` | — |
| U2 | `--remove-core` : code 0 ; skill `sdlc` retiré (comportement de base conservé) | `test_u2_remove_core` | — |
| U2 | agents `sdlc-*` retirés, premier niveau et imbriqués (`agents/sdlc-architect.md`, `agents/nested/sdlc-deep.md`) | `test_u2_remove_core` | — |
| U2 | agent tiers (`agents/autre-clara.md`) et `PERSO.md` conservés dans le live | `test_u2_remove_core` | — |
| U2 | `CLAUDE.md` conservé, identique à l'octet | `test_u2_remove_core` | — |
| U2 | dossier de sauvegarde horodaté créé (un seul), agent de premier niveau et agent imbriqué présents sous leur chemin relatif complet | `test_u2_remove_core` | sauvegarde sous `<live>/_backups/uninstall-*`, comme U1 |
| U2 | sauvegarde : agent tiers (`agents/autre-clara.md`) absent | `test_u2_remove_core` | idem |
| U2 | sauvegarde : `PERSO.md` absent | `test_u2_remove_core` | idem |
| U3 | `--remove-core` sans `agents/`, sans `PERSO.md` ni `CLAUDE.md` : code 0, sans plantage | `test_u3_remove_core_without_agents` | — |
| U3 | les skills sont retirés normalement (`skills/sdlc` supprimé) | `test_u3_remove_core_without_agents` | — |
| U4 | confirmation refusée (`non`) : code 0, annulé | `test_u4_confirmation_refused` | fin d'entrée (EOF) = refus |
| U4 | annulé : live intact (rien retiré) | `test_u4_confirmation_refused` (instantané complet du live) | — |
| retrait | cas uninstall des trois `test-retrait-*` | voir la section « retrait » | — |

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
| C1 | modified-both sans `--lww` : code 3, état `modified-both` et diff affichés | `Parity.test_c1_modified_both_blocks` | diff unifié Python (`difflib`, 200 lignes au plus) au lieu de `git diff --no-index` |
| C1 | fichier de la référence non écrasé | `Parity.test_c1_modified_both_blocks` | — |
| C1 | base non réécrite | `Parity.test_c1_modified_both_blocks` | — |
| C1 | aucun nouveau commit | `Parity.test_c1_modified_both_blocks` | — |
| C1 | `conflicts.log` non créé sans `--lww` | `Parity.test_c1_modified_both_blocks` | — |
| C2 | texte : `git add`/`commit` avec pathspec, jamais `-A` | — | sans objet (texte des scripts) ; couvert par C2b |
| C2b | capture OK (code 0) ; HEAD commit le chemin du domaine (`commands/sdlc/beta.md`) | `Parity.test_c2b_commit_scope` | — |
| C2b | S1 : fichier hors domaine et skill tiers non commités (le commit ne contient que `beta.md`) | `Parity.test_c2b_commit_scope` | — |
| C2b | S2 : fichier indexé hors `claude/` non commité, absent de la pointe | `Parity.test_c2b_commit_scope` | Python vérifie en plus que README.md reste indexé (§7) |
| C2b | S3 : suppression ignorée non commitée ; la pointe garde `sdlc-alpha.md` | `Parity.test_c2b_commit_scope` | — |
| C3 | base et `conflicts.log` hors du worktree (aucun `.sync-manifest.json` ni `conflicts.log` sous le dépôt) | `Parity.test_c3_d3_state_outside_worktree_and_success` | — |
| C3 | capture nominale (modified-live) : code 0, base écrite | `Parity.test_c3_d3_state_outside_worktree_and_success` | — |
| C3 | écriture atomique : aucun temporaire résiduel côté référence | `Parity.test_c3_d3_state_outside_worktree_and_success` | temporaires `.sdlc-tmp-*`, voir S5a |
| D3 | référence == live, `claude/` propre après le commit | `Parity.test_c3_d3_state_outside_worktree_and_success` | — |
| D3 | base réécrite avec le nouveau hash | `Parity.test_c3_d3_state_outside_worktree_and_success` | — |
| C4 | post-commit qui salit le chemin commité : code 7, échec du post-contrôle signalé (`POST-CHECK`) | `Parity.test_c4_post_check_failure` | — |
| C4 | base non réécrite | `Parity.test_c4_post_check_failure` | — |
| C5a | added-live : code 0, fichier présent dans la référence | `Parity.test_c5a_added_live_captured` | — |
| C5a | un nouveau commit, qui contient le fichier ajouté | `Parity.test_c5a_added_live_captured` | — |
| C5a | base mise à jour avec le nouveau chemin | `Parity.test_c5a_added_live_captured` | — |
| C5b | deleted-live : code 3, état signalé | `Parity.test_c5b_deleted_live_blocked` | — |
| C5b | fichier de la référence non supprimé | `Parity.test_c5b_deleted_live_blocked` | — |
| C5b | aucun commit, base non réécrite | `Parity.test_c5b_deleted_live_blocked` | — |
| C6a | dry-run : code 0, 0 commit | `Parity.test_c6a_dry_run_writes_nothing` | pas de verrou (voir plus haut) |
| C6a | dry-run : 0 fichier créé dans la référence | `Parity.test_c6a_dry_run_writes_nothing` | — |
| C6a | dry-run : base intacte | `Parity.test_c6a_dry_run_writes_nothing` | — |
| C6b | dry-run reflète le blocage (code 3) ; rien d'écrit, base intacte | `Parity.test_c6b_dry_run_reflects_block` | — |
| C6b | dry-run : `conflicts.log` non créé (vérifié avec `--lww --provenance live`) | `Parity.test_c6b_dry_run_reflects_block` | — |
| D1 | premier lancement, ref == live : seed, code 0, base écrite | `Parity.test_d1_first_run_seed_block_adopt` | — |
| D1 | asymétrie de présence : blocage (5), base non écrite | `Parity.test_d1_first_run_seed_block_adopt` | — |
| D1 | `--adopt` : seed forcé (code 0), base écrite | `Parity.test_d1_first_run_seed_block_adopt` | Python vérifie en plus qu'`--adopt` ne copie rien dans la référence |
| D2 | base corrompue : code 6, FAIL CLOSED signalé | `Parity.test_d2_corrupt_base_fails_closed` | code exact 6 vérifié |
| D2 | aucun commit, référence intacte | `Parity.test_d2_corrupt_base_fails_closed` | — |
| D4 | `--lww --provenance live` : conflit résolu (code 0), `conflicts.log` écrit | `Parity.test_d4_lww_live_winner_logged_and_backed_up` | — |
| D4 | `conflicts.log` hors du worktree (aucun exemplaire sous le dépôt) | `Parity.test_d4_lww_live_winner_logged_and_backed_up` | — |
| D4 | journal : `winner=live` ; la référence adopte le contenu du live | `Parity.test_d4_lww_live_winner_logged_and_backed_up` | — |
| D4 | un commit créé | `Parity.test_d4_lww_live_winner_logged_and_backed_up` | — |
| D4 | sauvegarde horodatée de la référence perdante (contenu `alpha-REF`), hors du worktree | `Parity.test_d4_lww_live_winner_logged_and_backed_up` | sauvegarde sous `<live>/_backups/capture-lww-*` au lieu de `<dossier de conflicts.log>/_backups` |
| E0 | `--ref` inexistante : code 2 | `Contract.test_missing_ref_gives_2_and_leaves_live_untouched` | — |
| E0 | live inchangé (aucune base semée) | `Contract.test_missing_ref_gives_2_and_leaves_live_untouched` | — |
| E1 | commit refusé (crochet `pre-commit`) : code 4 | `Parity.test_e1_commit_rejected_then_retry` | — |
| E1 | relance : code 0, un commit, HEAD contient les octets capturés, chemin propre | `Parity.test_e1_commit_rejected_then_retry` | — |
| E1 | base contient le hash capturé | `Parity.test_e1_commit_rejected_then_retry` | — |
| E2 | commit fait mais base non publiée : code 0, aucun nouveau commit | `Parity.test_e2_committed_but_base_stale` | — |
| E2 | base rafraîchie avec le hash commité | `Parity.test_e2_committed_but_base_stale` | — |
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
- Trace de déploiement dans le registre d'installation s'il existe (§4, R3-06), pour les seuls fichiers écrits, même si le post-contrôle échoue (7) ; sans rien à déployer, le registre n'est pas lu ; les scripts n'écrivaient rien. La trace est validée avant la première mutation, dry-run compris ; une ancienne clé qui ne diffère d'une nouvelle que par la casse est remplacée (E5-R1-05, E5-R1-07).
- Fast-forward (E5-R1-01) : le plan est fait contre le commit amont, puis l'avance rapide n'est appliquée qu'après tous les refus ; un blocage laisse HEAD, l'index et la référence intacts. Les scripts avançaient la branche avant de classer. Ordre : référence sale (5) avant divergence (4) ; le dry-run lit le commit amont sans avancer la branche et renvoie 4 en cas de divergence (les scripts l'ignoraient en dry-run). Une branche locale en avance sur son amont n'est pas une divergence : rien à appliquer (E5-R2-02). Avant l'avance rapide (dry-run compris), restore refuse (5) si elle écraserait quelque chose dans le dépôt : un fichier non suivi ou ignoré là où l'amont ajoute un chemin, un fichier là où il faut un dossier, ou un fichier suivi modifié localement ; un dossier ignoré qui peut coexister ne bloque pas. Le merge passe aussi `--no-overwrite-ignore` (E5-R2-01, E5-R3-01, E5-R3-02 ; `git read-tree -n` ne voit pas les fichiers ignorés, mesuré avec Git 2.54).
- Trace : les deux tables finales (`file_hashes`, `retained_hashes`) sont validées ensemble ; une ancienne clé dont le fichier ou un dossier parent ne diffère que par la casse est remplacée (E5-R2-07).

| Scénario | Assertion des scripts | Test Python | Écart voulu |
|---|---|---|---|
| C0 | texte : pas de robocopy, Copy-Tree, post-contrôle verify | — | sans objet (texte des scripts) |
| C1 | modified-ref et added-ref déployés : code 0, octets du live égaux à la référence | `Parity.test_c1_c7_nominal_restore` | — |
| C1 | sauvegarde de l'ancien contenu du live | `Parity.test_c1_c7_nominal_restore` | — |
| C7 | aucun temporaire restant côté live | `Parity.test_c1_c7_nominal_restore` | temporaires `.sdlc-tmp-*`, voir S5a |
| C2 | deleted-ref : supprimé du live, sauvegardé | `Parity.test_c2_base_aware_deletion` | — |
| C3 | modified-live seul sans `--force-restore` : code 3, état `modified-live-only` signalé | `Parity.test_c3_modified_live_blocked_then_forced` | — |
| C3 | live non écrasé, aucune sauvegarde (pas de dossier `_backups`) | `Parity.test_c3_modified_live_blocked_then_forced` | — |
| C3 | avec `--force-restore` : code 0, fichier canonique déployé, live perdant sauvegardé | `Parity.test_c3_modified_live_blocked_then_forced` | — |
| C4 | modified-both avec `--force-restore` : code 3 | `Parity.test_c4_modified_both_blocked_even_forced` | — |
| C4 | état `modified-both` signalé dans la sortie | `Parity.test_c4_modified_both_blocked_even_forced` | — |
| C4 | octets du live conservés (non écrasé) | `Parity.test_c4_modified_both_blocked_even_forced` | — |
| C5 | added-live protégé ; post-contrôle → 7 | `Parity.test_c5_added_live_protected` | — |
| C6 | dry-run : live et sauvegardes intacts, liste affichée | `Parity.test_c6_dry_run_writes_nothing` | — |
| C8 | référence sale → 5, rien écrit | `Parity.test_c8_canonical_guard` | vérifié aussi en dry-run |
| C9 | dry-run avec amont en avance : code 0 | `Parity.test_c9_dry_run_does_not_advance` | — |
| C9 | dry-run n'avance pas la branche locale (HEAD inchangé, fast-forward non exécuté) | `Parity.test_c9_dry_run_does_not_advance` | — |
| D1 | base corrompue : code 6, FAIL CLOSED signalé | `Parity.test_d1_corrupt_base_fails_closed` | code exact 6 vérifié |
| D1 | rien écrit (live inchangé, pas de dossier `_backups`) | `Parity.test_d1_corrupt_base_fails_closed` | — |
| — | fast-forward puis déploiement ; divergence → 4 | `Contract.test_fast_forward_then_deploy`, `Contract.test_diverged_gives_4` | — |
| — | base absente = base vide : le fichier ajouté dans la référence est déployé | `Contract.test_absent_base_is_empty` | — |
| — | base absente : un fichier du domaine présent seulement dans le live n'est jamais lu comme base implicite : octets conservés, post-contrôle EXTRA, code 7 | `Contract.test_absent_base_is_empty` | propre à Python (hors scripts) |
| — | base absente : le manifeste n'est jamais créé par restore | `Contract.test_absent_base_is_empty` | — |
| §5.2.4 | un dossier là où va un fichier déployé → 3, dry-run compris, rien écrit | `Contract.test_refusal_before_any_write_dry_run_included` | — |
| R3-06 | install A → restore B → uninstall sans historique : B supprimé, modification manuelle conservée | `Sequence.test_r3_06_uninstall_after_restore_without_history` | — |
| R3-06 (§13 littéral) | install A → restore B → install C (archive **sans** le fichier de B) → uninstall sans historique : B intact supprimé, B modifié à la main conservé | `Sequence.test_r3_06_literal_install_c_without_the_b_file`, `test_install.Retained` | décision JYH 2026-11-25 (option 1.4.1) : install garde dans `retained_hashes` les fichiers déjà enregistrés que la source ne livre plus, encore présents et identiques ; uninstall parcourt aussi les dossiers `skills/<s>` prouvés par `retained_hashes`, même absents de la liste `skills` (FINAL-R1-02, `Sequence.test_final_r1_02_skill_omitted_by_c_is_uninstalled`) |
| PYI-03 | install A → restore B → install C (archive) : B reconnu ; modification manuelle après B sauvegardée | `Sequence.test_pyi_03_install_a_restore_b_install_c_from_archive` | — |

## retrait (`test-retrait-nestor.sh` = A, `test-retrait-nestor-codex.sh` = B, `test-retrait-nestor-ps.ps1` = P) → `test_uninstall.py`, `test_install.py`, `test_fsops.py` (R3-10)

Les numéros T ne désignent pas le même cas d'une suite à l'autre : la table donne le numéro dans chaque suite (– : absent de la suite).

| Cas | A | B | P | Assertion des scripts | Test Python | Écart voulu |
|---|---|---|---|---|---|---|
| aucune mention de Nestor dans `bundle/scripts` hors tests | T1 | T1 | T1 | texte des scripts | — | sans objet (texte des scripts retirés) ; `installer/sdlc_installer` ne connaît aucun nom Nestor |
| aucune mention de Nestor dans les autres tests | T2 | T2 | T2 | texte des tests | — | sans objet (texte des scripts retirés) |
| ancienne option d'import refusée | T3 | T3 | T3 | `--remove-import` / `-RemoveImport` : code 2 (A, B), ≠ 0 (P) ; B exige le message `Unknown option` | `Parity.test_c14_external_import_preserved` (`test_install.py`) : code 2, diagnostic contenant `unrecognized arguments` et `--remove-import`, `CLAUDE.md` inchangé | message d'erreur d'`argparse` (« unrecognized arguments ») au lieu de `Unknown option` ; le code 2 est le même |
| `--remove-core` garde `NESTOR.md`, les autres agents et `CLAUDE.md` | T4 | T4 | T4 | rc 0 (B, P) ; `CLAUDE.md` identique à l'octet ; `NESTOR.md` à l'octet (B), présent (A, P) ; agent non sdlc présent | `test_retrait_t4_t5_t9_remove_core_with_discover` : rc 0, `CLAUDE.md`, `NESTOR.md` et `agents/nestor-b.md` comparés à l'octet | — |
| `--remove-core` retire les agents `sdlc-*` de premier niveau | T5 | T5 | T5 | `agents/sdlc-a.md` absent | idem (`agents/sdlc-architect.md` absent) | — |
| `--remove-core` retire les agents imbriqués | – | T9 | T9 | `agents/nested/sdlc-deep.md` absent | idem (`agents/nested/sdlc-deep.md` absent) | — |
| fichier personnel conservé (registre à empreintes) | T6 | T6 | T6 | `skills/sdlc/mes-notes.md` présent | `test_retrait_t6_personal_and_modified_files_kept` | Python vérifie aussi le contenu et la suppression des fichiers du bundle |
| fichier du bundle modifié à la main conservé | – | – | T6b | `commands/sdlc/dev.md` présent | idem (contenu modifié conservé, ligne « kept » affichée) | — |
| écriture atomique vers un dossier : erreur | T7 | T7 | T7 | `write_file_atomic` / `Write-FileAtomic` : code ≠ 0 ou exception | `test_fsops.test_directory_refused` (`fsops.safe_replace` : `InstallerError`, dossier intact et vide) | — |
| `verify` ne publie plus de compteur core | T8 | – | – | texte : aucune occurrence de `core=` dans `verify.sh` | — | sans objet (texte des scripts) ; `verify.py` n'a aucune notion de core |
| sans registre ni `--discover` : refus, rien supprimé | – | T8 | T8 | rc ≠ 0, `skills/sdlc/SKILL.md` présent | `test_retrait_t8_no_registry_no_discover` : code exact 2, live identique (instantané complet) | — |
| ancien registre sans `file_hashes` : avertissement | T9 | – | T12 | sortie contient `no file_hashes` | `test_retrait_t9_t12_legacy_registry` (registre écrit par le vrai `install.sh` de `667d7ed`) | ignoré visiblement si bash ou `667d7ed` manque ; avec l'historique Git lisible, l'appartenance est prouvée, pas d'avertissement, une modification manuelle est conservée (§3) |
| registre à empreintes : aucun avertissement | T10 | – | T13 | sortie sans `no file_hashes` | `test_registry_file_hashes_without_history` | — |
| homonymes `skills/sdlc/dev.md` et `commands/sdlc/dev.md` tous deux conservés en sauvegarde | – | T10 | T10 | les octets `XBYTES` et `YBYTES` restent sous la racine | `test_retrait_t10_homonyms_both_backed_up` : les deux dans le dossier de sauvegarde | sous `--discover`, seuls les fichiers prouvés par l'historique Git sont supprimés (§8.6.1.b) ; sans historique lisible, rien n'est supprimé |
| dry-run d'install : aucune racine créée | – | T11 | T11 | la racine cible n'existe pas après | `Parity.test_c7_dry_run_writes_nothing` (`test_install.py`) : racine `not-created` absente | — |

## sync-lib (`test-sync-lib.sh`, `test-sync-lib.ps1`) → tests Python par module

Les deux suites sont des miroirs (groupes (a) à (L) plus bonus), à ces exceptions près, signalées dans la colonne « Scénario » ou « Assertion » : les groupes (R) (R1 à R5) et l'invariant `sha256('abc')` n'existent que dans `test-sync-lib.sh` ; `test-sync-lib.ps1` regroupe en une assertion ce que le `.sh` sépare (portée des skills, `entries = {}`, `CLAUDE.md` et `CLAUDE.local.md` du groupe L5) ; seul le `.sh` vérifie l'absence de sauvegarde et de temporaire en dry-run (k6b) ; seul le `.ps1` passe un `-RelPath` à `Get-SyncState` (g-sp3, T070) et vérifie que l'avertissement k7 cite le marqueur. Les assertions de texte (groupes b, c, j-orphan) n'ont pas d'équivalent par construction : les propriétés visées sont portées par `fsops.safe_replace` et `locks.Lock`, et vérifiées par le comportement quand un test existe.

Écarts voulus communs :

- Il n'y a plus de bibliothèque à charger : `sync-lib` est répartie en modules du paquet `sdlc_installer` (table des fonctions ci-dessous). Les assertions de chargement (groupe a) sont donc sans objet.
- `set_generic_import` n'existe plus comme fonction publique : le seul import que l'installeur ajoute est `@CLAUDE.local.md` (design §1, décision 1, overlay.py). Les cas k1 à k7 sont portés sur `set_local_overlay_import` avec ce marqueur fixe.
- Les échecs se signalent par des exceptions typées (`SecurityError`, `InstallerError`, `LockHeld`) converties en codes de sortie par la CLI, au lieu d'un statut de fonction ou de lignes émises.

Correspondance des fonctions :

| Fonction des scripts | Fonction Python qui porte le comportement |
|---|---|
| `get_sync_exclusion` / `Get-SyncExclusion` | `domain.EXCLUDED_DIRS`, `EXCLUDED_FILES`, `EXCLUDED_NAMES` (domain.py) |
| `test_sync_excluded` / `Test-SyncExcluded` | `domain.is_excluded` (domain.py), `domain.is_pruned` (domain.py) |
| `get_sync_domain_skill` / `Get-SyncDomainSkill` | `manifests._derive_skills` (manifests.py) ; paramètre `skills` de `domain.domain_rels` |
| `get_domain_relpaths` / `Get-DomainRelPaths` | `domain.domain_rels` (domain.py), règle par chemin `domain.in_domain` (domain.py), `inventory.tree_inventory` (inventory.py), `inventory.head_inventory` |
| `get_rel_path` / `Get-RelPath` | sans objet : simple relativisation de chemin (sync-lib.ps1) ; Python construit les chemins relatifs en `/` pendant le parcours (`domain._scan`, domain.py) et les valide (`paths.validate_rel`, paths.py) |
| `get_file_hash_byteexact` / `Get-FileHashByteExact` | `manifests.sha256_hex` (manifests.py), `manifests.file_sha256` (manifests.py) |
| `get_sync_state` / `Get-SyncState` | `syncstate.classify` (syncstate.py) |
| `show_conflict_diff` / `Show-ConflictDiff` | `capture.show_diff` (capture.py) |
| `resolve_lww` / `Resolve-LWW` | `syncstate.resolve_lww` (syncstate.py) |
| `write_file_atomic` / `Write-FileAtomic` | `fsops.safe_replace` (fsops.py) |
| `copy_tree` / `Copy-Tree` | sans objet : remplacée par des octets lus en mémoire puis écrits un à un par `safe_replace` dans `install._install_locked` (install.py), `capture._capture` (capture.py), `restore._restore` (restore.py) ; chemins validés par `paths.validate_rel`, `paths.check_all` |
| `acquire_sync_lock` / `release_sync_lock` (`Acquire-SyncLock` / `Release-SyncLock`) | `locks.Lock.acquire` (locks.py), `Lock.release` (locks.py), `locks.live_lock` (locks.py) |
| `write_sync_manifest` / `read_sync_manifest` | `manifests.write_sync_manifest` (manifests.py), `manifests.read_sync_manifest` (manifests.py) |
| `get_first_run_plan` / `Get-FirstRunPlan` | `syncstate.first_run_plan` (syncstate.py), `syncstate.seed_entries` (syncstate.py) |
| `set_generic_import` / `Set-GenericImport` | `overlay.append_marker` (overlay.py), `overlay.set_local_overlay_import` (overlay.py) ; plus de marqueur libre (décision 1) |
| `set_local_overlay_import` / `Set-LocalOverlayImport` | `overlay.set_local_overlay_import` (overlay.py) |
| `_sync_py`, `require_bash4` (.sh seul) | sans objet : plus d'interpréteur à résoudre, plus de bash |

Correspondance des assertions :

| Scénario | Assertion des scripts | Test Python | Écart voulu |
|---|---|---|---|
| a | `source` / dot-source n'écrit aucun fichier ; ne crée aucune variable de portée | — | sans objet : sémantique du chargement d'un script. Le plus proche, sans être équivalent : `EntryPoint.test_no_write_anywhere` (test_entry.py) (le point d'entrée n'écrit rien) |
| a | 18 fonctions exportées appelables (`get_sync_exclusion` … `set_local_overlay_import`) | — | sans objet : introspection de l'ensemble des fonctions des scripts ; correspondance dans la table des fonctions ci-dessus, chaque fonction Python étant exercée par les tests cités plus bas |
| a | `get_sync_exclusion` appelable seul : la liste contient `__pycache__` | `DomainRules.test_in_domain` (test_domain.py) (chemins `__pycache__/a.pyc` et `__PYCACHE__/x.py` exclus et 15) | accès indirect : aucune assertion directe sur `domain.EXCLUDED_DIRS` |
| a | `get_file_hash_byteexact` appelable seul : 64 caractères | `Hash.test_sha256_hex_is_64_hex_stable_and_byte_exact`, `HashOfFile.test_file_sha256_is_64_hex_stable_and_matches_the_bytes` (test_manifests.py) | — |
| b | texte : `write_file_atomic` utilise `.tmp-`, publie par `mv -f` (.sh) ou `Replace`/`Move` (.ps1), n'écrit jamais directement dans la cible ; `write_sync_manifest` et `copy_tree` passent par `write_file_atomic` (5 assertions par script) | `SafeReplace.test_new_and_replace_bytes_exact` (test_fsops.py) ; `SafeReplace.test_no_temp_left_on_failure` (test_fsops.py) | sans objet pour le texte des scripts. Propriété portée par `fsops.safe_replace` (temporaire `.sdlc-tmp-`, `fsync`, `os.replace`) et vérifiée par le comportement (octets exacts, aucun temporaire restant) ; `write_sync_manifest` y passe par `_write_json` (manifests.py), sans test de structure |
| b | `write_sync_manifest` produit la cible finale ; aucun `.tmp-` restant | `SyncManifest.test_round_trip_and_atomic` (test_manifests.py) (le dossier ne contient que `.sync-manifest.json`) | — |
| b | manifeste réécrit sur une cible existante (sentinelle `OLD-SENTINEL`) : lisible, cible remplacée | `Parity.test_c3_d3_state_outside_worktree_and_success` (test_capture.py) (la base semée est réécrite : `base(k).ok`, entrée B = hash de la référence) ; `SafeReplace.test_new_and_replace_bytes_exact` (test_fsops.py) | la cible préexistante n'est pas une sentinelle non JSON : le remplacement est prouvé par le contenu neuf |
| c | texte : `copy_tree` sans `rsync`, `cp -r`, `--delete` (.sh) ; sans `robocopy`, `/MIR` (.ps1) | — | sans objet : invariant du texte des scripts. Python n'a aucune copie miroir : le déploiement n'écrit que les chemins du plan, un par un (`install._install_locked` install.py `capture._capture` capture.py `restore._restore` restore.py) |
| c | `copy_tree` copie le relPath autorisé (`a.md`) | `Parity.test_c2_bootstrap_git` (test_install.py) ; `Parity.test_c1_c7_nominal_restore` (test_restore.py) | — |
| c | crée les dossiers parents (`sub/b.md`) | `SafeReplace.test_new_and_replace_bytes_exact` (test_fsops.py) (`a/b.md` dans un dossier absent) ; `Parity.test_c3_archive_source` (test_install.py) (`agents/nested/sdlc-deep.md`) | — |
| c | ne copie pas un fichier hors liste (`c.md`) | `Parity.test_c2_bootstrap_git` (test_install.py) (le leurre `skills/sdlc/commands/sdlc/decoy.md` n'est pas déployé) ; `Parity.test_c2b_commit_scope` (test_capture.py) (fichier live hors domaine non capturé) | la liste est celle de l'inventaire du domaine, pas un argument libre |
| c | contenu copié fidèle à l'octet | `Parity.test_c2_bootstrap_git` (test_install.py) (octets live == `SEED`) ; `SafeReplace.test_new_and_replace_bytes_exact` (test_fsops.py) (`b'two\r\n'`) | — |
| c-sec | relPath `..` (et `sub//../../x.md`) rejeté : rien n'est copié | `RelValidation.test_refused` (test_paths.py) (`a/../b`, `..`, `a//b`) ; `Backups.test_refusal_creates_nothing` (test_backup.py) (`../escape.md` : `SecurityError`, arborescence inchangée) | voulu : Python lève `SecurityError` (code 3) avant toute écriture ; `copy_tree` ignorait le chemin en le signalant sur stderr et continuait (sync-lib.sh) |
| c-sec | la victime hors de la racine de destination n'est pas écrasée | `Junctions.test_nested_junction_refused` (test_paths.py) (le contenu hors racine, atteint par jonction, reste intact) ; `Backups.test_refusal_creates_nothing` (test_backup.py) | — |
| d | manifeste JSON tronqué : `FailClosed` ; base vide | `SyncManifest.test_fail_closed_cases` (test_manifests.py) (`{ "entries": ` donne `(ok, exists, fail_closed, entries) == (False, True, True, {})`) ; `Parity.test_d2_corrupt_base_fails_closed` (test_capture.py) (code 6) | — |
| d | fail-closed : ref ≠ live jamais tenu pour synchronisé ; sans base, `modified-both` | `Classify.test_truth_table` (test_syncstate.py) (`(r2, l2, None)` donne `MODIFIED_BOTH`) ; `Classify.test_empty_string_is_absent` (test_syncstate.py) ; `Parity.test_d2_corrupt_base_fails_closed` (test_capture.py) (aucun commit, référence intacte) | — |
| d-schema | `entries` = tableau JSON : `FailClosed`, base vide | `SyncManifest.test_fail_closed_cases` (test_manifests.py) (`{"entries": [1, 2]}`) | — |
| d-schema | `entries` = chaîne : `FailClosed`, base vide | `SyncManifest.test_fail_closed_cases` (test_manifests.py) (`{"entries": "x"}`) | — |
| d-schema | `entries` = `{}` : `Ok`, base vide conservatrice (non fail-closed) | `SyncManifest.test_empty_entries_object_is_valid_and_not_fail_closed` (test_manifests.py) | — |
| e | 13 lignes de la table de vérité de `get_sync_state` (identical ×2, modified-ref, modified-live, modified-both ×2, added-live, deleted-ref, conflict-deleted-ref-modified-live, added-ref, deleted-live, conflict-deleted-live-modified-ref, absent-both) | `Classify.test_truth_table` (test_syncstate.py) (14 lignes, les 13 plus `(None, None, None)`) ; `Classify.test_hashes_compared_without_case` (test_syncstate.py) | — |
| f | `*.pyc` exclu | `Verify.test_t4_pyc_ignored` (test_verify.py) (`leftover.pyc` hors `__pycache__`, ignoré par `verify`) ; `DomainRules.test_in_domain` (test_domain.py) (`a.pyc` sous `__pycache__`) | pas d'assertion directe sur `domain.is_excluded` |
| f | `__pycache__/` exclu | `DomainRules.test_in_domain` (test_domain.py) (`__pycache__/a.pyc`, `__PYCACHE__/x.py`) | Python exclut aussi sans casse (domain.py) |
| f | `conflicts.log` exclu | `DomainRules.test_sync_state_files_are_excluded` (test_domain.py) | — |
| f | `.sync-manifest.json` exclu | `DomainRules.test_sync_state_files_are_excluded` (test_domain.py) | — |
| f | un `.md` du domaine n'est pas exclu | `DomainRules.test_in_domain` (test_domain.py) (`skills/sdlc/SKILL.md`) | — |
| g | inclut `skills/sdlc/SKILL.md`, `skills/sdlc-reviewer/SKILL.md`, `commands/sdlc/plan.md`, `agents/sdlc-python-dev.md` | `DomainRules.test_in_domain` (test_domain.py) (règle par chemin) ; `DomainOnDisk.test_walk_matches_rules` (test_domain.py) (parcours disque) | noms de fixtures différents, même règle (préfixe `sdlc-`) |
| g | H3 : `skills/sdlc/commands/**` exclu | `DomainRules.test_in_domain` (test_domain.py) (`skills/sdlc/commands/dev.md`, `Commands/old.md`) ; `DomainOnDisk.test_walk_matches_rules` (test_domain.py) (`commands/old.md` absent du résultat) | — |
| g | H7 : skill tiers `autre` ignoré | `DomainOnDisk.test_walk_matches_rules` (test_domain.py) (`skills/other/SKILL.md` absent) ; `Verify.test_t7_third_party_ignored` (test_verify.py) | — |
| g | agents hors `sdlc-*` ignorés | `DomainRules.test_in_domain` (test_domain.py) (`agents/autre-clara.md`) ; `DomainOnDisk.test_walk_matches_rules` (test_domain.py) (`agents/autre.md`) | — |
| g | aucun `.pyc` dans le mapping | `DomainRules.test_in_domain` (test_domain.py) (`__pycache__/a.pyc`) ; `Verify.test_t4_pyc_ignored` (test_verify.py) | — |
| g | portée des skills dérivée de `sdlc*` ; inclut `sdlc` et `sdlc-reviewer`, exclut le tiers (.sh : 3 assertions, .ps1 : 2) | `DomainOnDisk.test_walk_matches_rules` (test_domain.py) (boucle `sdlc*` de `domain.domain_rels`, domain.py : `skills/other` ignoré) ; `ReadRegistry.test_missing_skills_derived_from_disk_with_warning` (test_manifests.py) (`manifests._derive_skills` : `sdlc`, `sdlc-b` retenus ; `other`, `sdlc-mine` de nom tiers et `sdlc_bad` écartés) | Python vérifie en plus le `name:` du `SKILL.md` et la validité du nom (`domain.is_valid_skill_name`) |
| g-sp3 | racine sans `PERSO.md` : pas d'erreur, hors domaine | `DomainRules.test_in_domain` (test_domain.py) (`PERSO.md`) ; `Verify.test_t1_identical` (test_verify.py) (la référence contient `README.md` et `OTHER.md`, hors domaine : code 0) | — |
| g-sp3 | T070 : `agents/autre-*` hors domaine ; `agents/autre-agent.md` toujours ignoré | `DomainRules.test_in_domain` (test_domain.py) (`agents/autre-clara.md`) ; `DomainOnDisk.test_walk_matches_rules` (test_domain.py) | — |
| g-sp3 | T071 : `PERSO.md` à la racine hors domaine | `DomainRules.test_in_domain` (test_domain.py) (`PERSO.md`) | — |
| g-sp3 | T071 : fichier racine arbitraire (`AUTRE.md`) hors domaine, aucun motif racine ouvert | `Verify.test_t1_identical` (test_verify.py) (`OTHER.md` : fichier racine commité, hors domaine) ; `DomainRules.test_in_domain` (test_domain.py) (`CLAUDE.md`) | — |
| g-sp3 | T070 : modified-ref seul classé `modified-ref`, pas ignoré (.ps1 passe `-RelPath`, .sh non) | `Classify.test_truth_table` (test_syncstate.py) (`(r2, b, b)` donne `MODIFIED_REF`) | `syncstate.classify` n'a pas de paramètre de chemin : la classification ne dépend pas du chemin, l'exclusion de domaine se fait avant (`domain.in_domain`) |
| h | hash stable (deux lectures identiques) | `Hash.test_sha256_hex_is_64_hex_stable_and_byte_exact`, `HashOfFile.test_file_sha256_is_64_hex_stable_and_matches_the_bytes` (test_manifests.py) | — |
| h | hash sensible à 1 octet | `Hash.test_sha256_hex_is_64_hex_stable_and_byte_exact`, `HashOfFile.test_file_sha256_is_64_hex_stable_and_matches_the_bytes` (test_manifests.py) | — |
| h | byte-exact : CRLF ≠ LF (aucune normalisation) | `Hash.test_sha256_hex_is_64_hex_stable_and_byte_exact`, `HashOfFile.test_file_sha256_is_64_hex_stable_and_matches_the_bytes` (test_manifests.py) | — |
| h | invariant `sha256('abc')` (.sh seul) | `Hash.test_sha256_hex_is_64_hex_stable_and_byte_exact`, `HashOfFile.test_file_sha256_is_64_hex_stable_and_matches_the_bytes` (test_manifests.py) | — |
| i | union identique : `seed` | `FirstRun.test_seed_block_adopt` (test_syncstate.py) | — |
| i | asymétrie de présence : `block` | `FirstRun.test_seed_block_adopt` (test_syncstate.py) (dans les deux sens : clé `b` seulement dans la référence, clé `x` seulement dans le live ; `block` et clé en écart attendus dans chaque cas) | — |
| i | `--adopt` / `-Adopt` force le `seed` malgré l'asymétrie | `FirstRun.test_seed_block_adopt` (test_syncstate.py) (dans les deux sens : `seed`, `adopted` vrai) | Python marque en plus `adopted` ; `seed_entries` couvert par `FirstRun.test_seed_prefers_the_reference` (test_syncstate.py) |
| i | divergence de contenu (même clé, hash différent) : `block` | `FirstRun.test_seed_block_adopt` (test_syncstate.py) | — |
| j | `acquire_sync_lock` crée le verrou | `SharedLock.test_exclusive_and_released` (test_locks.py) | — |
| j | 2e acquisition concurrente échoue (O_EXCL) | `SharedLock.test_exclusive_and_released` (test_locks.py) (`LockHeld`) | — |
| j | `release_sync_lock` supprime le verrou | `SharedLock.test_exclusive_and_released` (test_locks.py) ; `SharedLock.test_released_on_exception` (test_locks.py) | — |
| j | réacquisition possible après libération | `SharedLock.test_exclusive_and_released` (test_locks.py) | en plus : `SharedLock.test_bash_directory_lock_is_respected` (test_locks.py) (verrou répertoire de `sync-lib.sh`) |
| j-orphan | l'écriture des métadonnées échoue : le verrou orphelin est retiré (texte : `rmdir` .sh, `Remove-Item` .ps1) | `SharedLock.test_metadata_write_failure_propagates_and_leaves_no_lock` (test_locks.py) | test comportemental au lieu du texte des scripts |
| bonus | `show_conflict_diff` ne lève pas (dégrade sans git) | `Parity.test_c1_modified_both_blocks` (test_capture.py) (diff lisible `+alpha-LIVE`) | voulu : `capture.show_diff` utilise `difflib`, sans git (design, voir parité capture C1) |
| bonus | `resolve_lww` : gagnant `ref` par défaut | `Lww.test_default_winner_is_ref_and_logged` (test_syncstate.py) | — |
| bonus | `resolve_lww` journalise (append only) | `Lww.test_default_winner_is_ref_and_logged` (test_syncstate.py) (deux lignes après deux appels) ; `Lww.test_dry_run_writes_nothing` (test_syncstate.py) | Python n'écrit rien en dry-run |
| k1 | 6 appels de suite : 1 seule ligne marqueur à chaque pas ; contenu initial préservé | `Overlay.test_k1_idempotent_and_prefix_preserved` (test_overlay.py) | marqueur fixe `@CLAUDE.local.md` au lieu de `@keep-me.md` (voir k, marqueur) |
| k2 | ligne déjà présente au milieu : fichier inchangé | `Overlay.test_k2_line_in_the_middle_is_enough` (test_overlay.py) | — |
| k4 | (préalable) le fichier est absent | — | sans objet : précondition de fixture |
| k4 | fichier absent : créé avec la seule ligne marqueur | `Overlay.test_l1_missing_files_are_created` (test_overlay.py) (`CLAUDE.md == MARK`) | — |
| k5 | sans EOL final : octets initiaux + LF + marqueur | `Overlay.test_k5_no_final_eol_uses_dominant_style` (test_overlay.py) | — |
| k5b | sans EOL final, CRLF dominant : préfixe CRLF | `Overlay.test_k5_no_final_eol_uses_dominant_style` (test_overlay.py) | — |
| k6a | dry-run, fichier absent : toujours absent | `Overlay.test_k6_dry_run_writes_nothing` (test_overlay.py) (dossier vide) | — |
| k6b | dry-run, fichier existant : inchangé ; (.sh seul) aucune sauvegarde, aucun temporaire résiduel | `Overlay.test_k6_dry_run_writes_nothing` (test_overlay.py) (octets inchangés et `listdir == ['CLAUDE.md']` : ni `_backups`, ni temporaire) | — |
| k7 | 2 lignes marqueur : avertissement émis | `Overlay.test_k7_duplicates_warn_without_dedup` (test_overlay.py) (`len(res.warnings) == 1`) | — |
| k7 (.ps1 seul) | l'avertissement cite le marqueur (`keep-me.md`) | `Overlay.test_k7_duplicates_warn_without_dedup` (test_overlay.py) : l'avertissement cite `@CLAUDE.local.md` | marqueur fixe `@CLAUDE.local.md` (design §1, décision 1) |
| k7 | 2 lignes marqueur : AUCUN dédoublonnage (fichier inchangé) | `Overlay.test_k7_duplicates_warn_without_dedup` (test_overlay.py) | — |
| k, marqueur | `--marker` / `-Marker` arbitraire (`@keep-me.md`) de `set_generic_import` | `Parity.test_c14_external_import_preserved` (test_install.py) (`@keep-me.md` externe conservé, jamais lu ni retiré ; `--remove-import` donne 2) | voulu (design §1, décision 1) : le seul import ajouté est `@CLAUDE.local.md` ; `overlay.append_marker` garde un paramètre `marker`, mais aucune commande ni aucun appelant ne lui passe autre chose que `@CLAUDE.local.md` |
| L1 | (préalable) l'overlay est absent | — | sans objet : précondition de fixture |
| L1 | overlay absent : créé, vide | `Overlay.test_l1_missing_files_are_created` (test_overlay.py) | — |
| L1 | ligne `@CLAUDE.local.md` ajoutée au chemin | `Overlay.test_l1_missing_files_are_created` (test_overlay.py) | — |
| L2 | overlay non vide existant : jamais écrasé | `Overlay.test_l2_existing_overlay_never_overwritten` (test_overlay.py) ; `Parity.test_c15_local_overlay` (test_install.py) | — |
| L2 | ligne d'import ajoutée malgré l'overlay préexistant | `Overlay.test_l2_existing_overlay_never_overwritten` (test_overlay.py) | fixture : `CLAUDE.md` préexistant (`# mine`) ; la suite des scripts partait d'un `CLAUDE.md` absent |
| L3 | 2e appel : overlay intact, une seule ligne d'import (idempotence) | `Overlay.test_k1_idempotent_and_prefix_preserved` (test_overlay.py) (6 appels, 1 ligne) ; `Parity.test_c15_local_overlay` (test_install.py) (2e installation : overlay inchangé, 1 ligne) | l'overlay de la 2e passe est non vide dans `test_c15` (cas plus fort que « vide ») |
| L4 | dry-run : ni overlay ni `CLAUDE.md` créés | `Overlay.test_k6_dry_run_writes_nothing` (test_overlay.py) | — |
| L5 | `CLAUDE.md` hors du domaine | `DomainRules.test_in_domain` (test_domain.py) (`CLAUDE.md`) | — |
| L5 | `CLAUDE.local.md` hors du domaine (.sh : assertion séparée) | `Parity.test_c15_local_overlay` (test_install.py) (`CLAUDE.local.md` absent de `tree_inventory(live)`) | — |
| R1 (.sh seul) | `write_file_atomic` : échec d'écriture (un ancêtre est un fichier ordinaire) donne un statut non nul | `SafeReplace.test_ancestor_that_is_a_file_propagates` (test_fsops.py) (`OSError`, fichier `blocker` intact) ; `SafeReplace.test_directory_refused` (test_fsops.py) ; `SafeReplace.test_no_temp_left_on_failure` (test_fsops.py) | voulu : exception au lieu d'un statut |
| R2 (.sh seul) | `copy_tree` : sur échec d'écriture, n'émet pas le rel et renvoie non nul (pas de manifeste menteur) | `Contract.test_write_error_on_the_second_file_fails_without_registry_and_frees_the_lock` (test_install.py) : code non nul, aucun registre publié, verrou libéré | sans objet pour l'émission du rel : Python ne passe pas par une sortie standard |
| R3 (.sh seul) | `get_first_run_plan` lit la dernière ligne sans saut de ligne final | — | sans objet : Python reçoit des dictionnaires (`syncstate.first_run_plan`), aucun fichier TSV à relire |
| R4 (.sh seul) | `_sync_py` résout un interpréteur Python 3 | — | sans objet : l'installeur est lui-même du Python |
| R5 (.sh seul) | `require_bash4` réussit sur le bash courant | — | sans objet : plus de bash |

## sync-bdd (`sync-bdd.tests.ps1`) → `installer/tests/test_capture.py`, `test_restore.py`, `test_verify.py`

Fixtures des scripts reprises par `SyncCase.sync_case` (`test_capture.py`) : dépôt Git, live isolé, base et `conflicts.log` dans un dossier d'état hors du worktree.

| Scénario | Assertion des scripts | Test Python | Écart voulu |
|---|---|---|---|
| S1 | capture sans `--lww` sur modified-both : exit 3 | `test_capture.py` `Parity.test_c1_modified_both_blocks` | — |
| S1 | état modified-both et diff affichés | `test_capture.py` `Parity.test_c1_modified_both_blocks` (cherche aussi `+alpha-LIVE`) | diff unifié Python (`difflib`), voir capture C1 |
| S1 | fichier de la référence non écrasé | `test_capture.py` `Parity.test_c1_modified_both_blocks` (octets de A comparés avant et après) | — |
| S1 | base (manifest) non réécrite | `test_capture.py` `Parity.test_c1_modified_both_blocks` (octets de `.sync-manifest.json`) | — |
| S1 | aucun nouveau commit Git | `test_capture.py` `Parity.test_c1_modified_both_blocks` (`commits(k.repo)`) | — |
| S1 | `conflicts.log` non créé sans `--lww` | `test_capture.py` `Parity.test_c1_modified_both_blocks` | — |
| S1b | `--lww --provenance live` : capture poursuivie, exit 0 | `test_capture.py` `Parity.test_d4_lww_live_winner_logged_and_backed_up` | — |
| S1b | `conflicts.log` créé | `test_capture.py` `Parity.test_d4_lww_live_winner_logged_and_backed_up` | — |
| S1b | `conflicts.log` non vide | `test_capture.py` `Parity.test_d4_lww_live_winner_logged_and_backed_up` (le contenu lu contient `winner=live`, donc non vide) | — |
| S1b | journal : `winner=live` | `test_capture.py` `Parity.test_d4_lww_live_winner_logged_and_backed_up` | — |
| S1b | la référence adopte la version du live (hash identique) | `test_capture.py` `Parity.test_d4_lww_live_winner_logged_and_backed_up` (octets de la référence égaux à ceux du live) | Python compare les octets, pas les hash ; en plus : commit fait et référence perdante sauvegardée |
| S2 | restore sur modified-live-only sans `--force-restore` : exit 3 | `test_restore.py` `Parity.test_c3_modified_live_blocked_then_forced` | — |
| S2 | état `modified-live-only` signalé | `test_restore.py` `Parity.test_c3_modified_live_blocked_then_forced` | — |
| S2 | live non écrasé | `test_restore.py` `Parity.test_c3_modified_live_blocked_then_forced` | — |
| S2 | aucune sauvegarde (rien écrit) | `test_restore.py` `Parity.test_c3_modified_live_blocked_then_forced` (pas de dossier `_backups`) | — |
| S3 | premier lancement, ref == live, sans base : seed, exit 0 | `test_capture.py` `Parity.test_d1_first_run_seed_block_adopt` | — |
| S3 | le seed écrit la base | `test_capture.py` `Parity.test_d1_first_run_seed_block_adopt` (lecture de la base et comparaison des entrées) | — |
| S3 | asymétrie de présence au premier lancement : BLOQUÉ, exit 5 | `test_capture.py` `Parity.test_d1_first_run_seed_block_adopt` | — |
| S3 | blocage : base non écrite | `test_capture.py` `Parity.test_d1_first_run_seed_block_adopt` | — |
| S3 | `--adopt` force le seed malgré l'asymétrie : exit 0 | `test_capture.py` `Parity.test_d1_first_run_seed_block_adopt` | — |
| S3 | `--adopt` écrit la base | `test_capture.py` `Parity.test_d1_first_run_seed_block_adopt` (le fichier du live seul figure dans la base) | Python vérifie en plus qu'`--adopt` ne copie rien dans la référence |
| S4 | capture `--dry-run` avec modified-live et added-live en attente : exit 0 | `test_capture.py` `Parity.test_c6a_dry_run_writes_nothing` | — |
| S4 | capture dry-run : 0 commit | `test_capture.py` `Parity.test_c6a_dry_run_writes_nothing` | — |
| S4 | capture dry-run : 0 fichier créé dans la référence | `test_capture.py` `Parity.test_c6a_dry_run_writes_nothing` (instantané complet de la référence) | — |
| S4 | capture dry-run : base inchangée | `test_capture.py` `Parity.test_c6a_dry_run_writes_nothing` (instantané de l'état) | Python ne prend pas non plus le verrou, voir écart commun de capture |
| S4 | restore `--dry-run` : exit 0 | `test_restore.py` `Parity.test_c6_dry_run_writes_nothing` | — |
| S4 | restore dry-run : live inchangé | `test_restore.py` `Parity.test_c6_dry_run_writes_nothing` | — |
| S4 | restore dry-run : aucune sauvegarde | `test_restore.py` `Parity.test_c6_dry_run_writes_nothing` (l'instantané du live contient `_backups`) | — |
| S5a | restore nominal : exit 0 (déployé et verify 0) | `test_restore.py` `Parity.test_c1_c7_nominal_restore` (le code 0 inclut le post-contrôle, `restore.py`) | — |
| S5a | swap atomique : 0 résidu `*.tmp-` / `*.bak-` côté live | `test_restore.py` `Parity.test_c1_c7_nominal_restore` | Python : temporaires `.sdlc-tmp-*` (`fsops.safe_replace`) ; plus de `*.bak-*`, les sauvegardes vont dans `<live>/_backups` |
| S5b | capture interrompue (arbre sali après commit) : exit 7 POST-CHECK | `test_capture.py` `Parity.test_c4_post_check_failure` | — |
| S5b | échec du post-contrôle signalé (`POST-CHECK`) | `test_capture.py` `Parity.test_c4_post_check_failure` | — |
| S5b | base non réécrite en cas d'échec partiel | `test_capture.py` `Parity.test_c4_post_check_failure` | — |
| S6 | verify : `.pyc` / `__pycache__` du live ignorés, exit 0 | `test_verify.py` `Verify.test_t4_pyc_ignored` | — |
| S7a | deleted-ref avec live == base : restore exit 0 | `test_restore.py` `Parity.test_c2_base_aware_deletion` | — |
| S7a | fichier supprimé côté live | `test_restore.py` `Parity.test_c2_base_aware_deletion` | — |
| S7a | sauvegarde du fichier avant suppression | `test_restore.py` `Parity.test_c2_base_aware_deletion` (une seule copie, `[b'alpha-v1\n']`) | — |
| S7b | added-live (hors référence et base) non supprimé | `test_restore.py` `Parity.test_c5_added_live_protected` | — |
| S7b | contenu du fichier live intact | `test_restore.py` `Parity.test_c5_added_live_protected` | — |
| S7b | exit 7 (post-contrôle : EXTRA signalé, pas de suppression) | `test_restore.py` `Parity.test_c5_added_live_protected` | — |
| S8 | `.ps1` présent (contenu LF) dans la référence, le live et la base avant l'amorçage, puis réécrit en CRLF côté live seulement : capture, exit 0 | `Parity.test_s8_crlf_script_survives_capture_then_restore_byte_for_byte` (test_restore.py) | — |
| S8 | capture : octets de la référence identiques (CRLF conservé, pas de normalisation) | `Parity.test_s8_crlf_script_survives_capture_then_restore_byte_for_byte` (test_restore.py) | — |
| S8 | capture réussie : 0 résidu temporaire côté référence (atomicité à l'exécution), dans cette même capture du `.ps1` CRLF | `Parity.test_s8_crlf_script_survives_capture_then_restore_byte_for_byte` (test_restore.py) | Temporaires `.sdlc-tmp-*`, voir S5a ; `test_capture.py` `Parity.test_c3_d3_state_outside_worktree_and_success` le vérifie aussi pour C3 |
| S8 | restore après suppression du fichier côté live (deleted-live) : redéployé, exit 0 | `Parity.test_s8_crlf_script_survives_capture_then_restore_byte_for_byte` (test_restore.py) | — |
| S8 | cycle capture, commit, restore : SHA-256 stable (CRLF octet pour octet) | `Parity.test_s8_crlf_script_survives_capture_then_restore_byte_for_byte` (test_restore.py) | — |
| S9a | base identique à HEAD : verify 0 (avant corruption, non-vacuité) | `test_verify.py` `Verify.test_t1_identical` | — |
| S9a | octets d'un fichier du domaine réécrits : exit 1 | `test_verify.py` `Verify.test_t6_differences` (`res.code == 1`, `hash_diff` exact) | — |
| S9a | marqueur `[HASH DIFF]` affiché | `Verify.test_s9a_cli_prints_hash_diff_marker` (test_verify.py) (code 1, `[HASH DIFF]` sans `[MISSING]`) | — |
| S9b | fichier du domaine supprimé côté live : exit 1 | `test_verify.py` `Verify.test_t6_differences` (`res.code == 1`, `missing` exact) | — |
| S9b | marqueur `[MISSING]` affiché | `Verify.test_s9b_cli_prints_missing_marker_alone` (test_verify.py) (live identique sauf un fichier supprimé : code 1, `[MISSING]` sans `[HASH DIFF]`) | — |
| G1 | restore réussi : exit 0 via la primitive atomique | `test_restore.py` `Parity.test_c1_c7_nominal_restore` | — |
| G1 | `Write-FileAtomic` (temp + rename) appelée au moins une fois (aucune écriture en place) | `Parity.test_g1_restore_writes_through_safe_replace` (test_restore.py), `Parity.test_g1_capture_writes_through_safe_replace` (test_capture.py) ; la primitive : `SafeReplace` (test_fsops.py) | — |
| G4 | codes de sortie exacts (jamais `-ne 0`), entier réellement capturé (`Assert-Rc`) | sans objet : le harnais PowerShell (`Split-Rc`, sentinelle -999) n'existe plus ; `run_cli` renvoie toujours un entier (`test_install.py`) et les tests comparent le code exact par `assertEqual` | sans objet |
| N1 | `Copy-Tree` copie le chemin de la liste verte (`a.md`) | `test_restore.py` `Parity.test_c1_c7_nominal_restore` ; porteur : boucle de déploiement `restore.py` (`safe_replace` par chemin) ; `Copy-Tree` est remplacée | `Copy-Tree` n'existe plus : le déploiement écrit chemin par chemin |
| N1 | fichier de destination hors liste verte survit (anti-/MIR) | `Parity.test_n1_files_outside_the_domain_survive_a_restore_byte_for_byte` (test_restore.py) | — |
| N1 | contenu hors liste verte intact | `Parity.test_n1_files_outside_the_domain_survive_a_restore_byte_for_byte` (test_restore.py) | — |
| N2 | verify sur référence sans fichier de domaine et live vide : exit 0 observé (XFAIL, défaut P014) | `Verify.test_n2_reference_without_domain_files_gives_2` (test_verify.py) | **voulu (décision JYH 2026-11-26)** : référence sans fichier du domaine = verify indisponible (2), au lieu du 0 vacueux des scripts |
| N3 | restore.ps1 documente la fenêtre TOCTOU entre sauvegarde et swap | — | sans objet : invariant du texte du script ; le mode Python lit les octets de HEAD en mémoire (§3) et verrouille avec `<live>/.sync.lock` |
| N4 | capture réussie : 0 résidu `*.tmp-` / `*.bak-` côté référence | `test_capture.py` `Parity.test_c3_d3_state_outside_worktree_and_success` | Temporaires `.sdlc-tmp-*`, voir S5a |
| N4 | restore réussi : 0 résidu côté live | `test_restore.py` `Parity.test_c1_c7_nominal_restore` | Temporaires `.sdlc-tmp-*`, voir S5a |

## planchers (`planchers.assert.ps1`) → `installer/tests/test_install.py`, `test_verify.py`

Les cardinalités 14 / 12 / 19 sont déjà couvertes par la ligne C1 de la section install ; les lignes ci-dessous les rattachent à `planchers.assert.ps1`.

| Scénario | Assertion des scripts | Test Python | Écart voulu |
|---|---|---|---|
| P1 | plancher des skills : 14 == nombre de `claude/skills/sdlc*` | `test_install.py` `Parity.test_c1b_real_reference_into_isolated_live` (`cardinalities(inventory.tree_inventory(live))` égal à `(14, 12, 19)`) ; déjà listé en C1 de la section install | le test mesure le live après install du vrai `claude/` avec `--allow-dirty` (arbre de travail déployé, `install.py`), pas HEAD : voir ligne P4 |
| P2 | plancher des agents : 12 == nombre de `claude/agents/sdlc-*` | `test_install.py` (même assertion, deuxième élément) | idem |
| P3 | plancher des commandes : 19 == nombre de `claude/commands/sdlc/*` | `test_install.py` (même assertion, troisième élément) | idem |
| P4 | source des chemins : `git ls-tree -r HEAD -- claude` (HEAD, pas l'arbre de travail ; un fichier non commité ne touche pas le canari) | `Verify.test_p4_real_head_inventory_cardinalities` (test_verify.py) : `cardinalities(head_inventory(REPO)) == (14, 12, 19)` | — |
| P5 | planchers dérivés dans le code de production, jamais en dur | `test_verify.py` `Verify.test_t5_floors_derived` (aucun littéral 10, 12 ou 18 dans `verify.py` ; ligne `floor=2 live=3`) | Le test cherche `\b1[028]\b` : il ne protège pas les littéraux 14 ou 19 ; à élargir en même temps que P4 si JYH le veut |

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

Écarts voulus communs : les motifs de niveau 2 sont des expressions Python (`re`), plus .NET ni ERE, lus avec les marques d'ordre des octets reconnues par `Get-Content` (UTF-8, UTF-16, UTF-32), sinon en UTF-8 strict (fichier illisible → 2) ; la sonde d'historique lit les objets Git avec les mêmes motifs Python au lieu de `git grep -E`, fichiers réguliers seulement (pas les liens), et n'est pas lancée dans un clone partiel (`extensions.partialClone` ou un distant `promisor` ou `partialclonefilter` : lecture seule garantie) ; les liens symboliques de l'arbre de travail ne sont ni suivis ni lus ; un dossier illisible arrête le scan (2) au lieu d'être sauté en silence ; le rapport ne peut pas aller dans des métadonnées Git (un composant `.git`, ou le dossier Git du dépôt scanné ou du dépôt qui contient la destination) (2) ; sans git, le rapport est écrit avec la mention « probe not run » ; les dossiers exclus de la synchronisation ne sont jamais ouverts ; un fichier de motifs inaccessible donne 2 ; un `--motifs-path` explicite dont le dossier parent manque, ou qui n'est pas un fichier, donne 2 (le fichier par défaut absent reste en mode générique, comme les scripts) ; une destination de rapport est refusée si un nom `.git` apparaît dans son chemin (partie encore à créer comprise) ou si un ancêtre a la structure d'un dossier Git (`objects/`, `refs/` et un `HEAD` de forme Git, vérifiée sans git) ; une erreur d'écriture du rapport donne 2 ; un fichier vide n'a aucune ligne ; un nom de fichier non UTF-8 est affiché avec des échappements ; le scanner Python s'exclut lui-même (`installer/sdlc_installer/scanfuites.py`), comme les deux scripts.
