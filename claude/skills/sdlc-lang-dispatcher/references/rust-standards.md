# Rust standards (SDLC)

## Expected environment

- **Rust ≥ 1.85**, edition 2024 for new crates (stable since 1.85; 2021 accepted for
  existing crates)
- **Toolchain**: `rustup` with the stable channel + clippy + rustfmt
- **Build**: `cargo` only

## Standard tools

| Task | Tool |
|---|---|
| Linter | `cargo clippy --all-features -- -D warnings` |
| Formatter | `cargo fmt --all --check` (CI) / `cargo fmt --all` (dev) |
| Tests | `cargo test --all-features` |
| Coverage | `cargo llvm-cov` or `cargo tarpaulin` |
| Dependency audit | `cargo audit` |
| Docs | `cargo doc --no-deps` |

## Required style

```rust
use anyhow::{Context, Result};
use serde::Deserialize;
use std::path::Path;

#[derive(Debug, Deserialize, PartialEq)]
pub struct Row {
    pub price: f64,
    pub qty: u32,
}

pub fn parse_csv(path: &Path) -> Result<Vec<Row>> {
    let mut reader = csv::Reader::from_path(path)
        .with_context(|| format!("opening {}", path.display()))?;
    let mut rows = Vec::with_capacity(64);
    for result in reader.deserialize() {
        let row: Row = result.context("parsing row")?;
        rows.push(row);
    }
    Ok(rows)
}
```

Firm rules:

- ✅ **`anyhow::Result`** or a custom error type (`thiserror`) — never `Box<dyn Error>`
  directly in a public API
- ✅ **`?` operator** for error propagation
- ✅ **Explicit lifetimes** only when ambiguous (Rust elides most of them)
- ✅ **`///` doc comments** on every public item
- ✅ **`#[must_use]`** on values that must be handled
- ✅ **`clippy::pedantic`** enabled unless justified
- ❌ **No `unwrap()`/`expect()`** in production code (acceptable in tests and in `main`)
- ❌ **No `unsafe`** without documented justification and review
- ❌ **No lazy `clone()`** — prefer borrows
- ❌ **No `String` where `&str` is enough**, or the reverse

## Tests

- **Framework**: built-in (`#[cfg(test)] mod tests`)
- **Integration tests**: `tests/` at the root
- **Property-based**: `proptest` or `quickcheck` recommended for pure functions
- **Coverage target**: 70% minimum

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_empty_returns_empty() {
        let path = Path::new("tests/fixtures/empty.csv");
        let rows = parse_csv(path).unwrap();
        assert!(rows.is_empty());
    }

    #[test]
    fn parse_single_row() {
        let path = Path::new("tests/fixtures/single.csv");
        let rows = parse_csv(path).unwrap();
        assert_eq!(rows, vec![Row { price: 1.5, qty: 3 }]);
    }
}
```

## Recommended project layout

```
project/
├── Cargo.toml
├── Cargo.lock
├── src/
│   ├── lib.rs
│   ├── main.rs           # if binary
│   └── parser.rs
├── tests/                # integration tests
│   ├── csvparser.rs
│   └── fixtures/
└── README.md
```

## Typical commands

```bash
# Setup
cargo new --lib mypkg  # or --bin
cd mypkg
cargo add anyhow serde csv --features derive

# Dev loop
cargo fmt --all
cargo clippy --all-features -- -D warnings
cargo test --all-features
cargo audit

# Release build
cargo build --release
```

## Forbidden anti-patterns

```rust
// ❌ Bad
fn parse(s: &str) -> u32 {
    s.parse().unwrap()  // crashes on invalid input
}

// ✅ Good
fn parse(s: &str) -> Result<u32, std::num::ParseIntError> {
    s.parse::<u32>()
}
```

```rust
// ❌ Bad
fn process(items: Vec<Item>) -> Vec<Result> {
    items.into_iter()
        .map(|i| i.transform().clone())  // needless clone
        .collect()
}

// ✅ Good
fn process(items: &[Item]) -> Vec<Result> {
    items.iter()
        .map(Item::transform)
        .collect()
}
```

## Security specifics

- ✅ Always run `cargo audit` in CI
- ✅ `cargo deny` to block licenses/CVEs
- ❌ No unreviewed `unsafe`
- ❌ No `std::process::Command` through a shell (Rust does not use one by default) —
  always pass separate args
- ✅ `secrecy` crate for sensitive values in memory

## Async / concurrency

- **Runtime**: `tokio` (`async-std` is discontinued)
- **Patterns**: prefer `tokio::join!` and `try_join!` over manual spawning; use
  `tokio::spawn` when the work is truly independent
- **Synchronization**: `tokio::sync::Mutex` for async critical sections,
  `parking_lot::Mutex` for sync-only code

## Recommended commit message

```
P020: csvparser handles BOM and trailing whitespace

Implements P020:A005 — strips UTF-8 BOM and trims fields. Tests
parse_with_bom and parse_with_trailing_ws added.
```
