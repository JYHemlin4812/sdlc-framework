# Go standards (SDLC)

## Expected environment

- **Go ≥ 1.22** (per-iteration loop variables); use a currently supported release — Go
  supports the two most recent minor versions
- **Module system**: `go.mod` at the root
- **GOFLAGS**: `-trimpath` recommended for reproducible builds

## Standard tools

| Task | Tool |
|---|---|
| Linter | `golangci-lint run` |
| Formatter | `gofmt -s -w .` (and `goimports`) |
| Tests | `go test -race -cover ./...` |
| HTML coverage | `go test -coverprofile=cover.out ./... && go tool cover -html=cover.out` |
| Vet | `go vet ./...` |

## Required style

```go
package csvparser

import (
    "encoding/csv"
    "fmt"
    "io"
    "strconv"
)

type Row struct {
    Price float64
    Qty   int
}

func ParseCSV(r io.Reader) ([]Row, error) {
    reader := csv.NewReader(r)
    records, err := reader.ReadAll()
    if err != nil {
        return nil, fmt.Errorf("reading csv: %w", err)
    }
    rows := make([]Row, 0, len(records)-1)
    for _, rec := range records[1:] {
        price, err := strconv.ParseFloat(rec[0], 64)
        if err != nil {
            return nil, fmt.Errorf("parsing price %q: %w", rec[0], err)
        }
        qty, err := strconv.Atoi(rec[1])
        if err != nil {
            return nil, fmt.Errorf("parsing qty %q: %w", rec[1], err)
        }
        rows = append(rows, Row{Price: price, Qty: qty})
    }
    return rows, nil
}
```

Firm rules:

- ✅ **Wrap errors with `%w`** — `fmt.Errorf("context: %w", err)`
- ✅ **Preallocate slices** when the size is known (`make([]T, 0, n)`)
- ✅ **`context.Context`** for long-running operations and I/O
- ✅ **`defer`** for close/cleanup
- ✅ **Small interfaces** defined on the consumer side (idiomatic Go)
- ❌ **No magic `init()`** unless truly justified
- ❌ **No unmanaged goroutines** — always synchronize via channels, `sync.WaitGroup` or
  errgroup
- ❌ **No `panic`** in application code (except unrecoverable cases); return an error
- ❌ **No `interface{}`/`any`** unless strictly necessary (prefer generics)

## Tests

- **Framework**: stdlib `testing` is enough; `testify` accepted
- **Naming**: `func TestXxx_Scenario(t *testing.T)`
- **Table-driven tests** preferred for multiple cases
- **Subtests**: `t.Run("name", func(t *testing.T) { ... })`
- **Race detector** required in CI: `go test -race`
- **Coverage target**: 70% minimum

```go
func TestParseCSV(t *testing.T) {
    cases := []struct {
        name    string
        input   string
        want    []Row
        wantErr bool
    }{
        {"empty", "", nil, true},
        {"valid", "price,qty\n1.5,3\n", []Row{{1.5, 3}}, false},
    }
    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            got, err := ParseCSV(strings.NewReader(tc.input))
            if (err != nil) != tc.wantErr {
                t.Fatalf("err = %v, wantErr %v", err, tc.wantErr)
            }
            if !reflect.DeepEqual(got, tc.want) {
                t.Errorf("got %v, want %v", got, tc.want)
            }
        })
    }
}
```

## Recommended project layout

```
project/
├── go.mod
├── go.sum
├── cmd/
│   └── mytool/
│       └── main.go
├── internal/                # unexported code
│   └── csvparser/
│       ├── csvparser.go
│       └── csvparser_test.go
├── pkg/                     # reusable public API
└── README.md
```

## Typical commands

```bash
# Setup
go mod init github.com/user/project

# Dev loop
gofmt -s -w .
goimports -w .
go vet ./...
golangci-lint run
go test -race -cover ./...

# Build
go build -trimpath -o bin/mytool ./cmd/mytool
```

## Forbidden anti-patterns

```go
// ❌ Bad
func Process(items []Item) []Result {
    results := []Result{}              // not preallocated
    for _, item := range items {
        result, err := transform(item)
        if err != nil {
            panic(err)                 // panic instead of error
        }
        results = append(results, result)
    }
    return results
}

// ✅ Good
func Process(items []Item) ([]Result, error) {
    results := make([]Result, 0, len(items))
    for _, item := range items {
        result, err := transform(item)
        if err != nil {
            return nil, fmt.Errorf("transforming item %v: %w", item.ID, err)
        }
        results = append(results, result)
    }
    return results, nil
}
```

## Security specifics

- ❌ No `exec.Command("sh", "-c", ...)` with user input (the Go equivalent of Python
  `shell=True`) — pass separate arguments
- ❌ No `text/template` with unescaped input in HTML — use `html/template`
- ✅ `crypto/rand` for secrets, never `math/rand`
- ✅ TLS 1.3 minimum (`MinVersion: tls.VersionTLS13`)

## Recommended commit message

```
P012: csvparser.ParseCSV handles header row

Implements P012:A003 — first row is header, parsing starts from
record[1:]. Tests TestParseCSV/header added.
```
