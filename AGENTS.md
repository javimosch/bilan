# AGENTS.md — bilan

Orientation for agents working on **bilan** — the deterministic financial ledger +
tax radar for professionnels pluri-actifs (machin/MFL single binary over SQLite).

## The one design rule (do not violate)

**No LLM inference in the platform — ever.** bilan stores and computes; it never
guesses. The client's own agent (claude-code/pi/opencode) is the intelligence:
it parses messy exports, normalizes them to the generic schema, explains the
radar. Any feature that would put a prompt or a model call inside bilan is out
of scope by definition.

## Before starting a task — memgraph skill discovery

```bash
memgraph recommend "<your task description>" --json
memgraph query "<keywords>" --json
```

Read the `file_path` of the top matches. Project memories: `memgraph recall "<task>" --project bilan --format index`.

## Build / test / verify

```sh
./build.sh     # machin encode framework/machweb.src src/*.src > build/bilan.mfl && machin build
./test.sh      # unit tests (core) + offline smoke (CLI + serve + error contract)
```

`machin` must be on PATH. The guide catalog rule applies here too: keep
`src/guide.src` and `help_json()` (src/main.src) in lockstep with the actual
command surface — an agent running an old binary must not discover a stale surface.

## Layout

| File | Role |
|---|---|
| `src/core.src` | pure helpers (esc, flags, parse_cents/fmt_cents, date_ok, csv_split, col_find) — no db/network/exit, unit-tested |
| `src/store.src` | db path, schema, seeded rate card (tax_rules), rule_int, current_year |
| `src/ledger.src` | domain logic — every op is a `*_json(db, …) (out, code, err)` core shared by CLI and HTTP |
| `src/serve.src` | HTTP API (machweb): /v1/* Bearer-gated, /_health + /guide + /llms.txt open, /_shutdown token-gated |
| `src/main.src` | CLI dispatch + cmd_* wrappers + feedback dual-write + update + help surfaces |
| `src/human.src` | the prose surface — `bilan start` (guided first run) and the `--text` rendering of tax/brief/stats. Reads the `*_json` cores and formats; computes no money |
| `src/guide.src` | `bilan guide` — the complete operator reference (cli-guide-spec) |
| `test/core_test.src` | unit tests for core (machin test) |
| `scripts/smoke.sh` | offline end-to-end: every command, the error contract, idempotent import, serve lifecycle |

## Conventions

- **stdout = data, stderr = errors, semantic exit codes.** 0 ok · 80 bad input ·
  93 conflict · 94 not-found · 100 upstream · 110 internal. Never print context to stdout.
- **Money is integer cents, always.** Rates are DECIPERCENT tenths (340 = 34.0%).
  No floats anywhere near money. MFL has no implicit int→float promotion — keep it that way.
- **The rate card is data, not code.** Tax rules live in `tax_rules` (year, regime,
  param, value). A loi de finances change is `bilan rule set`, never a new binary.
  When a rule is wrong, fix the seed in store.src AND document the override path.
- **Imports are idempotent**: (stream, ext_id) UNIQUE, ext_id derived from row
  content. Never break this — agents retry.
- **Two audiences, one number.** JSON is the contract (agents); `--text` and `/app`
  are renderings of that same JSON for the human who owns the money. A renderer may
  never compute — if the prose shows a number the JSON does not, that is a bug.
- **New command checklist**: *_json core in ledger.src → cmd_* wrapper in main.src →
  HTTP route in serve.src → entry in help_text() + help_json() + guide.src →
  smoke.sh case → test if pure logic.
- Keep every src file under 500 lines; split when it grows.

## MFL gotchas already paid for (don't relearn)

- No `!` negation — write `x == 0` / `x == false`.
- No non-empty `[]Struct{...}` literals — build with `append` onto `[]Struct{}`.
- `parse()` does not unescape `\uXXXX`; no `\uXXXX` in string literals (raw UTF-8 is fine).
- Never pass request-scoped strings/structs to `go` — machweb reclaims the request
  arena; flag work in SQLite and let a zero-arg goroutine re-read it.
- One short-lived SQLite handle per operation + WAL + busy_timeout (machweb is
  goroutine-per-connection).
- `parse_int`/`read_file`/`write_file` are builtins; `sqlite_query` returns a JSON
  array string — decode with `parse(rows, []Row{})`.
- **`sqlite_exec`'s return value is NOT "rows affected"** — it can be 0 on a successful
  INSERT. To detect an INSERT OR IGNORE collision, query `SELECT changes() AS n`
  immediately after (see `changes_n` in ledger.src).
- **`time_fields` takes SECONDS** (a unix timestamp), not millis — `time_fields(now_ms()/1000)`.
  Passing now_ms() raw yields a garbage year (58656).
- **`req.path` is the full request-URI** — machweb keeps the `?query` on it. Route-match
  on `path_only(req.path)` (see serve.src), and read params with `query(req, name)`.
- MFL vars are **function-scoped** — no `:=` shadowing; every branch needs its own names.
- `parse()` does not unescape `\uXXXX`; no `\uXXXX` in string literals (raw UTF-8 is fine).

## Release

Version lives in `src/core.src` `version_str()` — keep in lockstep with the git tag.
`main` is protected; feature work goes branch → PR → squash-merge.
