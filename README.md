# bilan

**The deterministic financial ledger + tax radar for professionnels pluri-actifs.**
Salary + micro-BNC/BIC + crypto + trading + rent + dividends — one SQLite file, one
native binary, and your own AI agent driving it all through a JSON CLI.

> **No LLM inside — by design.** Tax and money math must be deterministic and
> auditable, so bilan only stores and computes; it never guesses. The intelligence
> is your agent's (claude-code, pi, opencode…): it parses the messy broker exports,
> normalizes them, explains the radar, and plans around the numbers. The platform
> runs zero inference and sees zero prompts.

Part of the [agent-first CLI specs](https://cli-specs.intrane.fr/) family
(output · guide · feedback · update contracts). Built with
[machin](https://github.com/javimosch/machin) (MFL → C → native).

## Quickstart

```sh
./build.sh
export BILAN_DB=~/.bilan.db

./bilan stream add freelance --kind bnc
./bilan tx add freelance 2026-03-15 1200.50 --label "mission conseil"
./bilan import etoro exports/etoro-2026.csv --stream crypto   # - reads stdin
./bilan stats --year 2026
./bilan tax --year 2026
```

Every command prints one JSON object on stdout; errors are JSON on stderr with
semantic exit codes (0 ok · 80s input · 90s not-found · 100s upstream · 110s
internal). `./bilan help-json` is the machine-readable catalog; `./bilan guide`
is the full operator reference baked into the binary.

## What the tax radar computes (v0)

| regime | math (rates are DATA in the db, override per year) |
|---|---|
| micro_bnc | 34% abattement · 24.6% social |
| micro_bic_services | 50% abattement · 21.2% social |
| micro_foncier | 30% abattement |
| crypto/trading | PFU 31.4% on positive net gains; **exempt** under 305.00 EUR (form 2086) |
| dividends | PFU on the positive sum |
| salary | gross reported only (progressive IR scale is v1) |

Estimates to reason from, not tax advice.

## HTTP API

`./bilan serve --port 8791` — `/v1/*` is Bearer-gated (`BILAN_TOKEN`, generated +
printed to stderr if unset); `/_health`, `/guide`, `/llms.txt` are open;
`POST /_shutdown` stops the server.

## Development

```sh
./build.sh          # machin encode framework/machweb.src src/*.src -> build -> native binary
./test.sh           # unit (core) + offline smoke (CLI + serve + error contract)
```

Layout: `src/core.src` pure helpers · `src/store.src` schema + rate card ·
`src/ledger.src` domain logic (the `*_json` cores both CLI and HTTP share) ·
`src/serve.src` HTTP API · `src/main.src` CLI dispatch · `src/guide.src` the guide.
