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

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/javimosch/bilan/master/install.sh | sh
bilan start        # what bilan is, and your first command — guided, in French
```

`bilan start` branches on the state of your ledger: empty, it walks you through the
three ways to fill it; populated, it hands you the commands that read it.

## Quickstart (human)

```sh
bilan demo                 # an example pluri-actif ledger — nothing to type
bilan tax   --text         # what you will owe, line by line, in euros
bilan brief --text         # the morning image
bilan stats --text         # where the money came from
bilan serve --port 8791    # then open http://localhost:8791/app
```

`--text` renders the *same numbers* as the JSON, as French prose — it is a
rendering of the JSON core, never a second computation, so the two cannot disagree.

## Quickstart (agent)

```sh
export BILAN_DB=~/.bilan.db

bilan stream add freelance --kind bnc
bilan tx add freelance 2026-03-15 1200.50 --label "mission conseil"
bilan import etoro exports/etoro-2026.csv --stream crypto   # - reads stdin
bilan stats --year 2026
bilan tax --year 2026
```

Every command prints one JSON object on stdout; errors are JSON on stderr with
semantic exit codes (0 ok · 80s input · 90s not-found · 100s upstream · 110s
internal). `bilan help-json` is the machine-readable catalog; `bilan guide`
is the full operator reference baked into the binary; `bilan brian` is the
persona to install into your harness.

## What the tax radar computes

| regime | math (rates are DATA in the db, override per year) |
|---|---|
| salary | 10% frais professionnels (art. 83 CGI, floor/cap per member) → IR base |
| micro_bnc | 34% abattement · 24.6% social |
| micro_bic_services | 50% abattement · 21.2% social |
| micro_foncier | 30% abattement · 17.2% social; déficit foncier imputed up to 10 700 € on the revenu global, excess carried 10 years |
| crypto/trading | PFU 31.4% on positive net gains; **exempt** under 305.00 EUR (form 2086) |
| dividends | PFU on the positive sum |
| impôt sur le revenu | progressive barème + plafonnement du quotient familial (1 791 €/demi-part) + décote (art. 197 CGI) + réduction dons (art. 200 CGI) |
| informational | TVA franchise en base (art. 293 B) · PAS taux neutre (art. 204 H) |

Deterministic integer-cent math on the seeded rate card — estimates to reason
from, not tax advice. `bilan guide` lists what the radar does *not* model.

## HTTP API

`bilan serve --port 8791` — `GET /` is the landing page and `GET /app` the human
dashboard (a first-run panel while the ledger is empty); `/v1/*` is Bearer-gated (`BILAN_TOKEN`, generated +
printed to stderr if unset); `/_health`, `/guide`, `/llms.txt` are open;
`POST /_shutdown` stops the server.

## Development

```sh
./build.sh          # machin encode framework/machweb.src src/*.src -> build -> native binary
./test.sh           # unit (core) + offline smoke (CLI + serve + error contract)
```

Layout: `src/core.src` pure helpers · `src/human.src` the prose surface (`start`, `--text`) · `src/store.src` schema + rate card ·
`src/ledger.src` domain logic (the `*_json` cores both CLI and HTTP share) ·
`src/serve.src` HTTP API · `src/main.src` CLI dispatch · `src/guide.src` the guide.
