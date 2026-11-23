# Glossary — project terms

> **Language**: write this file in the project's `output_language`. Keep the headings,
> the table header and the field markers in English so the tooling can parse them.

> Business and project terms with a single agreed meaning. One line per term; add a term the
> first time two people (or an agent) could read it differently. Technical identifiers (file names,
> `P###`, `A###`) stay in the code and the architecture, not here.

> The AQ Gate reads this file: an unfilled template line is an error, and at tiers `full` and
> `exhaustive` a missing file is a warning.

---

## Terms

| Term | Definition | Also called / not to be confused with |
|---|---|---|
| `<term>` | `<what it means in this project>` | `<words not to use>` |

---

## Rules

- A term has one meaning in the project. If two meanings compete, split the term and rename one of them.
- Changing a definition is a change of the project context: update `0_context.md` in the same edit.
