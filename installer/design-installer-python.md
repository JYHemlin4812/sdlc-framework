# Design : installeur Python sdlc-framework (`installer/`) — tour 4

Date : 2026-11-24. Branche : `feat/installer-python` (base `ab6399c`). Tour 4 : intègre les constats R3-01 à R3-10 de la revue Codex du tour 3 (`_revue/codex-tour3-reply.json`, REVISE) sans nouvelle relecture complète (décision JYH du 2026-11-24 ; revues Codex par étape). Constats du tour 2 : `_revue/codex-tour2-reply.json` (PYI-01 à PYI-10).
Python 3.9+, bibliothèque standard seule ; tests en `unittest`. Windows d'abord, puis Linux (WSL Ubuntu). macOS : non vérifié (aucune machine).
Portée : install, uninstall, verify, capture, restore et scan-fuites, en un seul design. Les scripts Bash et PowerShell de `bundle/scripts` restent en place jusqu'à la parité prouvée (étape E7).
Hors portée : toute écriture dans le vrai `~/.claude` sans approbation de JYH ; push, PR ou fusion sans approbation.

## 1. Décisions déjà prises (ne pas rouvrir)

1. L'installeur ne lit, n'ajoute et ne retire aucune ligne d'import dans `CLAUDE.md`, sauf l'overlay `CLAUDE.local.md` (comportement actuel de `Set-LocalOverlayImport`, porté à l'identique). `CLAUDE.md` reste identique à l'octet près pour uninstall, avec ou sans `--remove-core`.
2. `--remove-core` ajoute seulement les agents `agents/**/sdlc-*` (toute profondeur) à la désinstallation.
3. Désinstallation d'une installation sans `file_hashes` ni historique Git lisible : avertissement, puis suppression comme avant (choix JYH du 2026-11-23).
4. Mise à niveau par-dessus un fichier dont l'origine ne peut pas être prouvée : sauvegarde, puis remplacement, avec avertissement (choix JYH du 2026-11-24, PYI-02).
5. Retrait des scripts Bash seulement après des suites Python vertes sous WSL Ubuntu (choix JYH, PYI-09).
6. L'installeur vit dans `installer/` de ce dépôt.

## 2. Structure

```
installer/
  install.py           seul point d'entrée documenté ; fixe sys.dont_write_bytecode avant tout import du paquet
  sdlc_installer/
    cli.py             sous-commandes install | uninstall | verify | capture | restore | scan-fuites ; table des codes (§6)
    domain.py          domaine SDLC dérivé (skills/sdlc*, commands/sdlc/*, agents/**/sdlc-*) + exclusions de synchro ; aucune liste en dur
    inventory.py       inventaire DÉRIVÉ, jamais versionné : contre HEAD, `git ls-tree -r -z --name-only HEAD -- claude` (récursif, chemins séparés par NUL) ; pour une archive ou `--allow-dirty`, énumération de l'arbre réel avec le même domaine et les mêmes exclusions (R3-01)
    ownership.py       preuve d'appartenance au bundle (§3)
    paths.py           résolution physique (realpath, jonctions, liens) ; confinement (§5)
    locks.py           un seul verrou O_EXCL partagé `<live>/.sync.lock` (pid, délai), comme les scripts actuels ; pris AVANT les contrôles qui décident (R3-09) ; non réentrant ; aucun verrou en dry-run
    fsops.py           safe_replace : refus si la destination est un répertoire ; temporaire dans le dossier de destination (droits : voir §5.2 point 5) ; fsync ; os.replace
    backup.py          sauvegarde horodatée unique (mkdtemp), chemins relatifs conservés ; toute erreur arrête avant suppression
    manifests.py       deux registres, deux schémas (§4)
    overlay.py         import CLAUDE.local.md seulement ; octets préservés ; UTF-8 sinon refus avant mutation
    gitstate.py        git --no-optional-locks ; racine du worktree ; politique d'arbre sale par commande (§7)
    syncstate.py       classification à trois états (porté de Get-SyncState) ; premier lancement, adoption
    install.py, uninstall.py, verify.py, capture.py, restore.py, scanfuites.py
  tests/               un fichier par module + parité ; racines temporaires seulement (jamais ~/.claude)
```

## 3. Appartenance au bundle (PYI-01, PYI-02, PYI-03)

Un fichier live `<rel>` du domaine est **propriété du bundle** si ses octets égalent l'un de :

1. la version source en cours d'installation ;
2. un blob déjà commité à `claude/<rel>` dans l'historique de la branche de référence (`git log --format= --raw --no-abbrev --root -m -- claude` ; `--root` et `-m` sont nécessaires pour couvrir le commit racine et les fusions ; comparaison par empreinte de blob Git calculée en Python) ;
3. l'empreinte `file_hashes[<rel>]` du registre d'installation (couvre une installation faite depuis une archive).

Sinon il est **d'origine inconnue**.

Pourquoi l'historique Git plutôt qu'un inventaire versionné :

- `.gitattributes` contient `* -text` : le blob égale le fichier, octet pour octet. Vérifié le 2026-11-24 : `git hash-object` = `HEAD:<rel>` pour `claude/skills/sdlc/SKILL.md` et `claude/skills/sdlc/scripts/check_sdlc.ps1`. Test à garder (fichier CRLF).
- Complétude vérifiée le 2026-11-24 : les 122 blobs de `HEAD:claude` sont tous dans les 182 blobs de l'historique (commande ci-dessus).
- Ancienne installation (agrégat seul, sans `file_hashes`) : un fichier intact d'une version passée est un blob de l'historique, donc reconnu sans identifier la version. Aucune étiquette Git n'existe ; il n'en faut pas.
- restore déploie HEAD (garde canonique) : ce qu'il pose est donc dans l'historique. La séquence install A → restore B → install C reconnaît B.
- capture commite ce qu'il copie : le contenu capturé devient un blob, donc la HEAD suivante s'installe sans mise à jour d'un inventaire. PYI-01 disparaît avec l'inventaire versionné (REV-01 du tour 1 est remplacé).

Limites :

- L'historique ne remonte qu'au 2026-09-29 (`6f33a9b`, 8 commits sur HEAD ; dépôt non superficiel ; `public-main` est un ancêtre de HEAD). Un fichier d'une version antérieure (v3) est « d'origine inconnue ».
- Un clone superficiel (`--depth`) a moins d'historique : même effet. install le signale (« historique incomplet »).
- Passage d'une source à une autre (R3-06) : install A, restore B depuis un dépôt, puis install C depuis une archive (sans historique). B n'est prouvable que par la trace de déploiement de restore (§4, point 1) ; c'est pourquoi restore l'écrit.
- Agrégat `checksum_sha256` (établi en E2) : lignes `rel:sha256\n` ; `install.sh` trie en octets (`LC_ALL=C`), `install.ps1` sans casse (`Sort-Object`). Python écrit l'ordre en octets et reconnaît les deux (`manifests.aggregate_matches`) ; avec `file_hashes`, la comparaison se fait fichier par fichier. Limite acceptée (E2-R1-08) : un agrégat `.ps1` dont l'ordre de collation .NET diffère n'est pas reconnu, ce qui provoque une réinstallation, jamais un faux « à jour ».

Effets par commande :

| Commande | Propriété du bundle | Origine inconnue |
|---|---|---|
| install (mise à niveau) | remplacé (sauvegarde sauf `--no-backup`) | sauvegardé **toujours** (même avec `--no-backup`), puis remplacé, avertissement par fichier |
| uninstall | supprimé (après sauvegarde) | conservé, signalé |
| uninstall, après restore puis install depuis une archive | reconnu par la trace de restore (§4) : supprimé | conservé si modifié à la main après restore |
| uninstall, registre sans `file_hashes` et sans Git | — | avertissement global, puis suppression (décision 3) |

## 4. Registres

1. `skills/sdlc/.install-manifest.json` (installation) : écrit par install après un post-contrôle acceptable ; champs obligatoires `version`, `skills` (liste des skills posés, lue par uninstall comme `uninstall.ps1` aujourd'hui), `checksum_sha256` (agrégat), `file_hashes`, `source_commit` (si Git). Lu par install et uninstall. **restore** y ajoute ou met à jour `file_hashes[<rel>]` pour chaque fichier déployé, après un post-contrôle réussi, sous le même verrou (trace de déploiement, R3-06) ; sans registre d'installation, restore n'en crée pas. Si `skills` manque (schéma inconnu) : dérivé des dossiers `skills/sdlc*` dont le `name:` du `SKILL.md` commence par `sdlc`, avec avertissement (R3-04). Les deux formats existants sont acceptés : agrégat seul (origin/main `667d7ed`) et agrégat + `file_hashes` (`ab6399c`). Fixtures produites avec les **vrais** anciens scripts (`git show 667d7ed:bundle/scripts/install.sh`), pas du JSON écrit à la main.
2. `.sync-manifest.json` à la racine live (synchro) : écrit seulement par capture (et le premier lancement) ; restore ne l'écrit pas (comportement actuel, `restore.ps1`, en-tête « On NOT rewriting the base »).

## 5. Confinement (PYI-04, REV-04, R3-02, R3-03)

### 5.1 Racines, avant tout verrou ou toute création de fichier

1. Toujours : source (ou référence) et live ne sont ni égales ni imbriquées, comparées en chemins physiques résolus → sinon code 2. C'est le seul contrôle pour une source d'archive hors Git.
2. Si la référence est dans un dépôt Git (install depuis un dépôt, capture, restore) : résoudre la racine du worktree (`git rev-parse --show-toplevel`) ; refuser (code 2) si l'un des éléments **machine-locaux** suivants est dedans : racine live, registre de synchro, `conflicts.log`, verrou, racine des sauvegardes live.
3. Non concernés par la règle 2 : la source elle-même (`--source repo/claude` explicite est valide), et scan-fuites, qui lit le dépôt et écrit son rapport par défaut sous `<dépôt>/SDLC_PM/` (`scan-fuites.ps1`, `Invoke-ScanFuites`) ; pour scan-fuites, seul le chemin du rapport est contrôlé (fichier, pas un répertoire).

### 5.2 Chaque chemin, avant chaque sauvegarde, copie, remplacement ou suppression

1. Un nom de skill lu dans le registre est un seul composant (`sdlc` ou `sdlc-*`, sans séparateur, sans `.`/`..`) → sinon code 3, rien écrit.
2. Chaque chemin relatif est validé (pas absolu, pas de segment `.`/`..`/vide), puis sa chaîne de parents physiques est vérifiée sous la racine prévue.
3. Liens symboliques et points de réanalyse (jonctions) : refusés (code 3) s'ils apparaissent dans la chaîne des parents ou comme fichier, côté source comme côté destination. La racine live elle-même peut être un lien (résolue une fois au départ).
4. Tous les contrôles de 5.2 se font sur l'ensemble des chemins **avant** la première mutation : un refus ne laisse rien de modifié.
5. Modèle de menace (décision JYH du 2026-11-24, constats E1-01 et E1-03) : aucun autre programme n'écrit dans la racine live ni dans la source pendant une opération ; le verrou partagé coordonne seulement les installeurs. Hors périmètre, comme dans les scripts actuels (`restore.ps1`, note « outside the threat model ») : un dossier remplacé par un lien entre le contrôle et l'écriture (pas d'opérations relatives à un descripteur) ; les droits du fichier temporaire, créé dans le dossier de destination, qui hérite sous Windows des droits de ce dossier. À revoir si l'installeur doit un jour tourner sur une machine partagée.

Tests : live dans `repo/live` ; `--manifest-path` dans le worktree ; installation depuis une archive hors Git ; `--source repo/claude` explicite accepté ; scan-fuites par défaut accepté ; jonction `commands/sdlc` vers un dossier sentinelle externe → code 3, sentinelle intacte ; nom de skill `../x` dans un registre → code 3. Le test C3 existant (`test-capture.sh`, état hors worktree) reste.

## 6. Codes de sortie (PYI-05, REV-08)

Codes actuels conservés, relevés dans le code exécutable (`.ps1`) ; la parité avec les `.sh` est vérifiée par test en E1.

| Code | install | uninstall | verify | capture | restore | scan-fuites |
|---|---|---|---|---|---|---|
| 0 | succès / déjà à jour | succès / annulé | 0 écart | succès / rien à capturer | succès | rapport écrit |
| 1 | erreur E/S (`SYNC.md`) | — | écart détecté | erreur (`SYNC.md`) | erreur E/S (`SYNC.md`) | — |
| 2 | prérequis ou source (`install.ps1:225-279`) | registre absent sans `--discover`, ou corrompu | indisponible | racine ou git absent (`capture.ps1:129,135,289`) | prérequis (`restore.ps1:159-184`) | racine ou prérequis introuvable |
| 3 | skill tiers ou nom illisible (`install.ps1:354,359`) | — | — | blocage modified-both (`capture.ps1:250`) | blocage (`restore.ps1:282`) | — |
| 4 | — | — | — | git add/commit en échec (`capture.ps1:330,337`) | ff-only divergent (`restore.ps1:202`) | — |
| 5 | **nouveau** : claude/ sale sans `--allow-dirty` | — | — | premier lancement divergent sans `--adopt` (`capture.ps1:173`) | référence sale (`restore.ps1:217`) | — |
| 6 | — | — | — | registre corrompu (`capture.ps1:198`) | registre corrompu (`restore.ps1:231`) | — |
| 7 | écart réel après déploiement (`install.ps1:450`) | — | — | post-contrôle en échec (`capture.ps1:348`) | post-contrôle en échec (`restore.ps1:358`) | — |

Les lignes « code 1 » viennent de `SYNC.md`, pas d'un `return` relevé dans le code : à confirmer en E1.
Nouveaux refus sans code existant (proposition, à confirmer en E1) : verrou déjà pris → 1 ; fichier `CLAUDE.md` non UTF-8 → 3 (contrôle de sécurité, rien écrit) ; racines confondues ou état dans le worktree (§5) → 2.
Changement voulu : install code 5 (§7). La colonne capture de `bundle/docs/SYNC.md` est fausse aujourd'hui (4, 5, 6, 7 absents) : corrigée en E6, pas avant.
install vérifie le live **avant** d'écrire le registre (comportement actuel). Depuis une archive (pas de HEAD) : vérification par comparaison d'octets avec la source.

## 7. Arbre sale, par commande (PYI-06)

| Commande | Règle | Option |
|---|---|---|
| install | `claude/` sale → refus, code 5 (changement voulu : aujourd'hui avertissement, `install.ps1` « DIRTY ref → not fatal ») | `--allow-dirty` : déploie l'arbre de travail, post-contrôle non bloquant comme aujourd'hui |
| capture | aucun refus global ; modified-both bloqué (3) ou résolu par `--lww` avec sauvegarde hors worktree ; commit limité aux chemins copiés (changements indexés sans rapport préservés) | `--allow-dirty` refusé (erreur d'usage) |
| restore | garde canonique toujours active (5) | `--allow-dirty` refusé |
| verify | compare à HEAD seulement ; l'arbre sale n'influence pas le résultat | — |
| uninstall | sans objet | — |

Tests : capture `--lww` avec une modification locale de la référence ; capture avec un fichier indexé hors `claude/` resté indexé et non commité ; restore refusé sur référence sale ; install refusé puis accepté avec `--allow-dirty`.

## 8. Contrats par commande

Relevés dans `install.ps1`, `capture.ps1`, `restore.ps1`, `verify.ps1` (en-tête), `scan-fuites.ps1` (en-tête et `Invoke-ScanFuites`) et `sync-lib.ps1` (`Get-SyncState`, `Get-FirstRunPlan`, `Set-LocalOverlayImport`, `Get-SyncExclusion`), lus le 2026-11-24. Les versions `.sh` : non relues, parité vérifiée par test en E1.

### 8.1 install

1. Contrôles préalables en lecture seule (indicatifs) : source (`skills/`, `commands/sdlc`, `SKILL.md` de chaque skill), domaine non vide → sinon 2 ; racines (§5.1), arbre sale (§7).
2. Dry-run : refait les contrôles 3 et 4 sans verrou, liste ce qui serait déployé, 0 écriture, retour 0.
3. Hors dry-run, **verrou pris d'abord** (R3-09), puis contrôles qui décident, refaits sous verrou : inventaire et agrégat de la source ; si égal au registre et sans `--force` : verify ; live intact → overlay puis « déjà à jour », 0 (tout sous verrou) ; live abîmé → réparation (comportement actuel F4).
4. Garde des skills tiers (sous verrou) : `SKILL.md` cible avec `name:` illisible ou hors `sdlc*` → 3, rien écrit. Contrôles de chemins §5.2 sur tout l'ensemble.
5. Les octets déployés sont vérifiés contre la source choisie (HEAD, arbre de travail avec `--allow-dirty`, ou archive) (R3-01). Décision JYH du 2026-11-24 (E3) : depuis un worktree propre, install déploie les **blobs de HEAD** (`git cat-file --batch`), pas l'arbre de travail ; chaque octet source est lu une fois, sous verrou, et sert au déploiement, au registre et au post-contrôle. Registre corrompu : avertissement puis écrasement (comme les scripts). `version` du registre : `3.2.0`, constante des scripts.
6. Toujours sous le même verrou : staging hors live → sauvegarde des fichiers live présents (§3 pour l'origine inconnue) → remplacement atomique fichier par fichier → post-contrôle verify classé (0 écart ; indisponible ; orphelins seuls ; arbre sale ; écart réel → 7) → registre écrit seulement après un post-contrôle acceptable, puis overlay ; verrou libéré à la fin.
7. Overlay `CLAUDE.local.md` en fin de parcours nominal et sur « déjà à jour » ; jamais d'autre ligne.
8. install est additif : il ne supprime jamais un orphelin (c'est le rôle de restore).

### 8.2 verify

Lecture seule : aucun fichier, aucun verrou. Compare le live au **HEAD commité** (`git cat-file blob HEAD:claude/<rel>`), jamais à l'arbre de travail. Rapporte MISSING, HASH DIFF, EXTRA (domaine sdlc seulement ; skills tiers ignorés ; exclusions de synchro jamais comptées) et FLOOR (cardinalités dérivées de HEAD). Codes 0, 1, 2.

### 8.3 capture (live → référence)

| État (`Get-SyncState`) | Action |
|---|---|
| modified-live, added-live | copié live → référence |
| modified-both | bloqué (3), sauf `--lww` (voir LWW ci-dessous) |
| deleted-live, conflict-* | bloqué (3) |
| identical, base = référence | ignoré |
| identical, base ≠ référence (capture précédente interrompue, R3-05) | chemin sale par rapport à HEAD → commité maintenant ; propre → base seule mise à jour |
| modified-ref, added-ref, deleted-ref, absent-both | ignoré |

LWW (R3-08) : `--lww` avec `--provenance ref|live`, défaut `ref`. `ref` : la référence gagne, ses octets restent intacts, rien n'est capturé pour ce chemin. `live` : choisi seulement sur `--provenance live` explicite ; la version de référence perdante est sauvegardée hors worktree avant écrasement. Jamais de décision par date de modification. Chaque résolution ajoute une ligne à `conflicts.log` (ajout seulement) : horodatage, `relpath`, empreintes ref et live, `provenance`, `winner` (comportement actuel de `Resolve-LWW`). Tests : les deux gagnants sur le même cas modified-both ; le défaut laisse la référence intacte.

Reprise après interruption (R3-05) : corrigé dans les scripts actuels sur cette branche (`capture.sh`, `capture.ps1`, tests E1/E2 de `test-capture.*`) ; porté tel quel. Couvre un commit refusé puis relancé, et un commit réussi dont la base n'a pas été publiée.

Ordre : verrou → union des domaines → registre de synchro (absent : premier lancement, amorçage si égal, sinon 5 sans `--adopt` ; corrompu : 6) → classification → un blocage = rien écrit (fichiers, registre, Git) → copie fichier par fichier → `git add` et `git commit` limités aux chemins copiés (échec : 4) → post-contrôle `git status --porcelain` sur ces chemins (sale : 7, registre non réécrit) → registre réécrit. Dry-run : 0 écriture, code reflète le blocage.

### 8.4 restore (référence → live)

| État | Action |
|---|---|
| modified-ref, added-ref, deleted-live | déployé référence → live |
| deleted-ref (live = base) | supprimé du live |
| modified-live | bloqué (3), sauf `--force-restore` |
| modified-both, conflict-* | bloqué (3), toujours |
| added-live | protégé, jamais touché |
| identical, absent-both | ignoré |

Ordre : git requis (2) → verrou → fast-forward seulement si une branche amont existe (divergence : 4 ; jamais en dry-run) → garde canonique (5) → registre corrompu (6) ; absent = base vide → classification → un blocage = rien écrit → staging → sauvegarde horodatée de chaque fichier live remplacé ou supprimé → remplacement atomique → suppressions → post-contrôle verify (écart ou indisponible : 7) → trace de déploiement dans le registre d'installation s'il existe (§4, R3-06). restore n'écrit pas le registre de synchro (§4).

### 8.5 scan-fuites

Outil de rapport, pas une porte. Lit l'arbre de travail (hors `.git/`, exclusions de synchro) et trois révisions (`git grep` sur racine, dernier commit avant « SP4 », HEAD). Motifs niveau 1 intégrés et figés, niveau 2 optionnel (`SDLC_PM/scan-fuites-motifs.txt`). Zone interne = `SDLC_PM/` (comptes seulement) ; tout le reste est public. Seule écriture : le rapport (`--report-path`). Codes : 0 rapport écrit (avec ou sans résultats) ; 2 racine ou prérequis introuvable.

### 8.6 uninstall (PYI-07)

1. Par défaut : dossiers `skills/<s>` listés au registre (`skills`, §4 ; ou découverts avec `--discover`) et `commands/sdlc` ; seuls les fichiers propriété du bundle (§3) sont supprimés ; un dossier vide est retiré, un dossier non vide est conservé et signalé. Les agents ne sont pas touchés.
1.a. Le registre `.install-manifest.json` est une métadonnée de l'installeur, hors domaine de synchro et sans empreinte propre : il est lu une fois avant toute suppression, sauvegardé, puis retiré **après** la suppression réussie des fichiers ; `skills/sdlc` est alors retiré s'il est vide (R3-04 ; comportement actuel de `Remove-OwnedTree`).
1.b. Registre illisible (JSON invalide) (R3-07) : sans `--discover` → code 2, rien supprimé (comme `uninstall.ps1`) ; avec `--discover` → découverte heuristique, appartenance par l'historique Git (§3), avertissement. Changement voulu par rapport à `uninstall.sh`, qui extrait des champs par `grep` d'un fichier invalide et continue : cas de migration documenté. Test : JSON invalide + `commands/sdlc` présent → code 2 et `commands/sdlc` intact ; même cas avec `--discover`.
2. Avec `--remove-core` : en plus, `agents/**/sdlc-*` à toute profondeur, propriété du bundle seulement.
3. Jamais : `CLAUDE.md` (identique à l'octet), fichiers hors domaine (ex. `agents/autre-*.md`, `PERSO.md`).
4. Sauvegarde horodatée avant suppression, chemins relatifs complets.

Les assertions U1 à U4 de `test-uninstall.sh` (environ lignes 100-165) sont reprises telles quelles. Test ajouté : install avec le nouvel écrivain puis uninstall par défaut → ni registre ni `skills/sdlc` ne restent ; avec un fichier personnel dans `skills/sdlc` → seul ce fichier reste.

## 9. Point d'entrée et zéro écriture (PYI-08, REV-11)

`sys.dont_write_bytecode` fixé dans le paquet arrive trop tard : le `.pyc` de `__init__` est déjà écrit. Seul point d'entrée documenté : `python installer/install.py <commande>`. `python -m` n'est pas documenté ; s'il est utilisé, seulement avec `-B`.
Test : sur une copie propre en écriture, `install.py verify` et `install.py install --dry-run` ne créent aucun `__pycache__`, aucun fichier, aucun verrou ; l'index Git est inchangé.

## 10. Plateformes (PYI-09)

- Windows : Python 3.9 et une version récente.
- WSL Ubuntu : mêmes suites, plus droits 0600/0700, remplacement atomique, verrou et fidélité des octets.
- macOS : non vérifié, dit dans INSTALL.md.
- Retrait de Bash conditionné aux suites WSL vertes (décision 5).

## 11. Tests (critères de sortie)

1. Chaque constat (PYI, REV, INST, R2-R4, DES, DES2) a un test qui échoue avant et passe après (table §13).
2. Parité : chaque scénario de `test-install`, `test-uninstall`, `test-sync-lib`, `test-verify`, `test-capture`, `test-restore`, `sync-bdd.tests.ps1`, `planchers.assert.ps1` et des trois `test-retrait-*` (`.sh`, variante Codex `.sh`, `.ps1` : refus de l'ancienne option d'import, conservation des fichiers personnels et des fichiers modifiés, dry-run sans racine créée, agents imbriqués, sauvegarde des homonymes) a son équivalent Python, listé dans une table de correspondance avant tout retrait (R3-10). Un `git grep` propre ne suffit pas : il faut la correspondance des assertions.
3. Exécution Windows et WSL, racines temporaires seulement.
4. Relecture Codex du diff final en session neuve : APPROVED.

## 12. Étapes

Chaque étape : tests verts, revue Codex de l'étape, commit après approbation JYH.

1. E1 : domain, inventory, paths, fsops, locks, backup ; test de parité des codes `.sh`/`.ps1`.
2. E2 : manifests, ownership (historique Git, fixtures des deux anciens formats), overlay.
3. E3 : install + verify, parité ; inclut le test exact du code 7 d'install sur une référence propre, registre non publié (constat E1-R5-04 reporté ici).
4. E4 : uninstall, parité.
5. E5 : capture + restore, parité, séquence A → B → C.
6. E6 : scan-fuites porté ; documentation alignée (§14).
7. E7 : retrait de PowerShell, puis de Bash après WSL ; commits séparés, approbation JYH.

## 13. Constats → section → test qui échoue avant

| Id | Section | Test |
|---|---|---|
| PYI-01 | §3 | capture d'une modification et d'un ajout, puis install depuis le commit produit : réussite |
| PYI-02 | §3, §4 | fixture créée par l'install.sh de `667d7ed` : mise à niveau intacte sans avertissement ; fichier modifié à la main : sauvegardé puis remplacé |
| PYI-03 | §3 | install A → restore B → install C : réussite ; modification manuelle après B : sauvegardée |
| PYI-04 | §5 | live dans `repo/live` et `--manifest-path` dans le worktree : code 2, rien créé |
| PYI-05 | §6 | parité des codes par commande et condition, `.sh` et `.ps1` |
| PYI-06 | §7 | quatre cas du §7 |
| PYI-07 | §8 | U1 à U4 repris ; `CLAUDE.md` identique à l'octet |
| PYI-08 | §9 | aucun `__pycache__` après verify et dry-run |
| PYI-09 | §10 | suites WSL vertes avant le commit de retrait de Bash |
| PYI-10 | §14 | `git grep` des points d'entrée retirés : seules restent des références historiques |
| R3-01 | §2, §8.1 | `--allow-dirty` avec un ajout non suivi et une suppression locale : les deux reflétés ; inventaire HEAD non vide |
| R3-02 | §5.2 | jonction `commands/sdlc` vers une sentinelle externe : code 3, sentinelle intacte ; nom de skill `../x` : code 3 |
| R3-03 | §5.1 | archive hors Git acceptée ; `--source repo/claude` accepté ; scan-fuites par défaut accepté |
| R3-04 | §4, §8.6 | install puis uninstall : ni registre ni `skills/sdlc` ; fichier personnel : seul il reste |
| R3-05 | §8.3 | E1/E2 de `test-capture.sh` et `test-capture.ps1` (déjà rouges puis verts sur les scripts actuels) |
| R3-06 | §3, §4 | install A → restore B (dépôt) → install C (archive) → uninstall : B supprimé ; modification manuelle après B : conservée |
| R3-07 | §8.6 | JSON invalide + `commands/sdlc` : code 2, rien supprimé ; avec `--discover` : heuristique |
| R3-08 | §8.3 | modified-both : défaut `ref` intact ; `--provenance live` : live capturé, ref sauvegardée |
| R3-09 | §2, §8.1 | référence modifiée entre les contrôles préalables et la prise du verrou : registre cohérent avec les octets déployés |
| R3-10 | §11, §14 | table de correspondance des trois `test-retrait-*` complète avant E7 |

## 14. Documentation et consommateurs à aligner en E6 (PYI-10, REV-06, REV-10)

Relevé par `git grep` sur les fichiers suivis (2026-11-24) :

- `.github/PULL_REQUEST_TEMPLATE.md:7` (boucle `test-*.sh`) ;
- `AGENTS.md:5,10`, `CONTRIBUTING.md:67` ;
- `README.md:55,63`, `README.fr.md:57,65` ;
- `bundle/INSTALL.md:31-177`, `bundle/README.md:26-50,153-154`, `bundle/MIGRATION_v3_v4.md:34` ;
- `bundle/docs/SYNC.md` (table des codes, §6) ;
- `SDLC_PM/scan-fuites-motifs.txt:1-2` (consigne : regex .NET pour `.ps1`, ERE POSIX pour `.sh` ; à réécrire pour le moteur `re` de Python) ;
- les trois `bundle/scripts/tests/test-retrait-*` : appelants actifs des anciens scripts, retirés seulement avec leur correspondance (§11) ;
- `claude/skills/{sdlc,sdlc-asvs-auditor,sdlc-lang-dispatcher,sdlc-wave-orchestrator}/SKILL.md` : fichiers du domaine livré ; les modifier change le contenu installé (reconnu par §3).

Références historiques conservées : `CHANGELOG.md`, `docs/KNOWN-ISSUES.md`, `bundle/docs/KNOWN-ISSUES.md`.
Ordre de retrait (REV-06) : scan-fuites porté avant tout retrait de `sync-lib` ; un test `git grep` vérifie qu'aucun consommateur actif ne reste.
