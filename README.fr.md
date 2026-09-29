# sdlc-framework

🇬🇧 [English version](README.md)

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

Un **cycle de vie logiciel (SDLC)** structuré pour Claude Code : skills, commandes `/sdlc:*` et
sous-agents, packagés en bundle installable sous `~/.claude/`. Il mène un projet du cadrage à la
livraison avec une traçabilité de bout en bout (exigences E### → décisions d'architecture A### →
tâches codables P### → cas de test T###), une validation qualité bloquante (AQ Gate), le Code Lock
et l'exécution parallèle par vagues.

Autonome. Il peut, en option, fonctionner avec
[`nestor-agents`](https://github.com/JYHemlin4812/nestor-agents) (voir
[`docs/INTEROP.md`](docs/INTEROP.md)).

## Prérequis

- [Claude Code](https://claude.com/claude-code) — le framework s'exécute dedans.
- Python 3.9+ (scripts de l'AQ Gate et du planificateur de vagues), git, et PowerShell 7
  (Windows) ou bash 4+ (Linux/macOS) pour l'installeur. Détails dans
  [`bundle/INSTALL.md`](bundle/INSTALL.md).

## Langues

- Les **instructions** (skills, commandes, agents, références, scripts) sont rédigées en anglais.
- Les **artefacts** que le framework produit pour vous (`1_elicitation.md`, `2_architecture.md`,
  `HANDOFF.md`, rapports, questions) sont rédigés dans l'`output_language` du projet, demandé à
  `/sdlc:init` et enregistré dans `SDLC_PM/sdlc-config.json`. À défaut, les artefacts suivent la
  langue dans laquelle vous écrivez. Les identifiants, titres de modèles et marqueurs de champs
  restent en anglais pour que les scripts puissent les analyser.

## Optimisé pour Claude Opus 5.5

- Les prompts utilisent des impératifs calmes assortis d'une courte raison, sans consigne du type
  « réfléchis étape par étape » ni auto-vérification redondante ; ce sont les contrôles
  structurels (AQ Gate, Code Lock, exécution des tests) qui vérifient.
- Chaque agent fixe un niveau d'`effort` selon son tier dans son frontmatter : `low` pour les
  agents simples (code-auditor, archive-manager), `medium` pour les agents d'exécution
  (développeurs, analystes, concepteur de tests), `high` pour les agents de conception
  (architecte, facilitateur de discussion).
- Les profils de modèles (`budget` / `balanced` / `quality` / `inherit`) se résolvent en
  `claude-haiku-4-5`, `claude-sonnet-5` et `claude-opus-5-5`. Voir
  [`claude/skills/sdlc/references/model-profiles.md`](claude/skills/sdlc/references/model-profiles.md).

Mise à niveau depuis la v3.x : voir [`bundle/MIGRATION_v3_v4.md`](bundle/MIGRATION_v3_v4.md).

## Démarrage rapide

Clonez le dépôt puis lancez l'installeur — moins de 5 minutes, sans configuration préalable. Les
deux commandes déploient le même contenu (skills `sdlc*`, commandes `/sdlc:*`, agents `sdlc-*`)
vers `~/.claude/` et annoncent le même résultat.

### PowerShell (Windows)

```powershell
git clone https://github.com/JYHemlin4812/sdlc-framework.git
cd sdlc-framework
pwsh bundle/scripts/install.ps1
```

### Bash (Linux/macOS)

```bash
git clone https://github.com/JYHemlin4812/sdlc-framework.git
cd sdlc-framework
bash bundle/scripts/install.sh
```

**Résultat attendu (les deux commandes)** : un rapport `Installation complete` indiquant le nombre
de skills/commandes/agents déployés et le chemin cible (`~/.claude/` par défaut). Redémarrez
Claude Code, puis lancez `/sdlc:init` dans votre projet (ou `/sdlc:status` pour vérifier
l'installation).

Options utiles (identiques dans les deux scripts, syntaxe native de chaque shell) :
`-DryRun`/`--dry-run` (simulation, aucune écriture), `-Force`/`--force` (réinstalle même si à
jour), `-NoBackup`/`--no-backup` (pas de sauvegarde horodatée avant remplacement).

## Déroulé type

```
/sdlc:init        → structure SDLC_PM/, output_language, tier de documentation
/sdlc:brainstorm  → 1_elicitation.md (exigences E###)
/sdlc:discuss     → 2_5_discussion.md (optionnel, projets M/L)
/sdlc:plan        → 2_architecture.md (A###) + 3_conception.md (P### avec vagues)
/sdlc:gate        → AQ Gate, exit 0 requis pour continuer
/sdlc:dev         → implémentation vague par vague + cas de test T### (--wave N, --auto-approve)
/sdlc:gate        → puis /sdlc:report pour la livraison
```

## Structure du dépôt

```
sdlc-framework/
├── claude/           # Contenu canonique déployé par l'installeur (skills, commands/sdlc, agents)
├── bundle/           # Scripts d'installation/désinstallation/vérification/synchronisation et leurs tests, modèles, doc d'installation
├── docs/             # Interopérabilité, problèmes connus, notes historiques
├── AGENTS.md         # Instructions pour agents IA + inventaire détaillé du bundle
├── CONTRIBUTING.md   # Workflow de contribution, conventions, validation avant PR
├── CHANGELOG.md      # Historique des changements notables
└── LICENSE           # Licence MIT
```

## Inventaire

| Catégorie | Nombre |
|---|---|
| Skills (`claude/skills/*/SKILL.md`) | 10 |
| Commandes (`claude/commands/sdlc/*.md`, `/sdlc:*`) | 18 |
| Agents (`claude/agents/*.md`) | 12 |

Détail complet (rôle, effort et source de chaque skill/commande/agent) : voir
[`AGENTS.md`](AGENTS.md).

## Liens

- [`LICENSE`](LICENSE) — licence MIT.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — workflow de contribution, conventions de nommage, validation avant PR.
- [`AGENTS.md`](AGENTS.md) — instructions pour agents IA + inventaire du bundle.
- [`CHANGELOG.md`](CHANGELOG.md) — historique des changements notables.
