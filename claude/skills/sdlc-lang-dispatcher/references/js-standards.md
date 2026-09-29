# JavaScript / TypeScript standards (SDLC)

## Expected environment

- **Node.js ≥ 22** (a supported LTS line; 24 preferred — Node 20 reached end of life in
  April 2026)
- **Package manager**: `pnpm` (preferred), `npm` accepted; avoid classic `yarn`
- **TypeScript** preferred over plain JavaScript. For JS, use `// @ts-check` + JSDoc
- **Module system**: ESM (`"type": "module"` in package.json)

## Standard tools

| Task | Tool |
|---|---|
| Linter | `eslint` (config @typescript-eslint/recommended) |
| Formatter | `prettier` |
| Type checker | `tsc --noEmit` |
| Tests | `vitest` (preferred over jest for speed + native ESM) |
| Coverage | `vitest --coverage` (`v8` or `istanbul`) |
| Runtime validation | `zod` |

## Required style

```typescript
// types-first, runtime-validated boundaries
import { z } from "zod";

const CsvRowSchema = z.object({
  price: z.coerce.number(),
  qty: z.coerce.number().int().positive(),
});

export type CsvRow = z.infer<typeof CsvRowSchema>;

export function parseCsv(content: string): CsvRow[] {
  const lines = content.trim().split("\n");
  return lines.slice(1).map((line) => {
    const [price, qty] = line.split(",");
    return CsvRowSchema.parse({ price, qty });
  });
}
```

Firm rules:

- ✅ **Strict TypeScript**: `"strict": true` in `tsconfig.json`
- ✅ **No `any`** except explicit cases (prefer `unknown`)
- ✅ **`as const`** for literals that must stay immutable
- ✅ **Zod validation** on every external input (API, file, user input)
- ✅ **async/await** throughout; no `.then()` chains except simple composition
- ✅ **Typed errors**: `class ValidationError extends Error`, etc.
- ❌ **No `var`** — `const` by default, `let` when reassigned
- ❌ **No `==`** — always `===` (and `!==`)
- ❌ **No `eval`/`Function()`**
- ❌ **No `JSON.parse(input)` without Zod** behind it

## Tests

- **Framework**: `vitest` (fast, ESM, jest-compatible when needed)
- **Naming**: `<module>.test.ts` next to the source or in `tests/`
- **Coverage target**: 70% minimum
- **Mocks**: `vi.fn()`, `vi.mock()`. Prefer real dependencies when they are cheap.

## Recommended project layout

```
project/
├── package.json
├── pnpm-lock.yaml
├── tsconfig.json
├── eslint.config.mjs
├── src/
│   ├── index.ts
│   └── module.ts
├── tests/
│   └── module.test.ts
└── README.md
```

## Typical commands

```bash
# Setup
pnpm init
pnpm add zod
pnpm add -D typescript vitest @types/node eslint prettier

# Dev loop
pnpm exec eslint src tests
pnpm exec prettier --check src tests
pnpm exec tsc --noEmit
pnpm test

# Run
pnpm exec tsx src/index.ts
```

## Forbidden anti-patterns

```typescript
// ❌ Bad
const data = JSON.parse(req.body); // any → time bomb

// ✅ Good
const data = RequestSchema.parse(JSON.parse(req.body));
```

```typescript
// ❌ Bad
fetch(url).then((r) => r.json()).then((data) => ...);

// ✅ Good
const response = await fetch(url);
if (!response.ok) throw new Error(`HTTP ${response.status}`);
const raw = await response.json();
const data = ResponseSchema.parse(raw);
```

## Security specifics

- ❌ No `dangerouslySetInnerHTML` without sanitization (DOMPurify)
- ❌ No SQL built with template strings — use a query builder
- ❌ No `eval` or `new Function`
- ✅ CSRF tokens on every POST/PUT/DELETE endpoint
- ✅ HTTPS only (except localhost)
- ✅ Secrets via `process.env`, never in code

## Recommended commit message

```
P007: parseCsv accepts BOM and CRLF

Implements P007:A002 — handles UTF-8 BOM stripping and Windows
line endings. Tests vitest-T015 added.
```

## Node.js (CLI / server) vs browser

If the P### targets the browser:
- Bundler: `vite` (preferred) or `esbuild`
- Front-end lint: `eslint-plugin-react` (if React) or equivalent
- UI tests: `vitest` + `@testing-library/...`
- Security: add `helmet` server-side, CSP client-side

For server APIs:
- Prefer `fastify` or `hono` over Express for new projects
- `express` accepted for projects migrated from SDLC v2 to v3
