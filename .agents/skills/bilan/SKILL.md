# bilan — operator skill

Drive **bilan**, the deterministic financial ledger + tax radar for professionnels
pluri-actifs (salary + micro-BNC/BIC + crypto + rent + dividends). You are probably
the operating agent: your human hands you broker exports and asks "what did I earn
and what do I owe". bilan stores and computes; YOU parse, explain, and plan. There is
**no LLM inside bilan by design** — the platform never guesses.

## Setup

```sh
# local (free, no account): the ledger is one SQLite file
export BILAN_DB=~/.bilan.db

# hosted (pay-as-you-go): same commands, ledger server-side, one per token
export BILAN_URL=https://bilan.intrane.fr  BILAN_TOKEN=<your token>
```

Read `bilan guide` once — the full operator reference is embedded in the binary
(also at GET /guide). `bilan help-json` is the machine-readable command catalog.

## The core loop

```sh
bilan stream add freelance --kind bnc        # one stream per activity/income line
bilan import etoro exports/2026.csv --stream crypto   # - reads stdin
bilan stats --year 2026                      # per-kind signed totals + net
bilan tax --year 2026                        # the radar
```

Output contract: one JSON object on stdout; errors are JSON on **stderr** with
semantic exit codes (0 ok · 80s input · 93 conflict · 94 not-found · 100s upstream).

## Idioms

- **Streams are typed by kind** — `salary|bnc|bic|rent|crypto|trading|dividends|other`.
  The kind picks the regime math. An unknown kind is rejected, never stored.
- **Crypto/trading txs are signed realized P/L per closed position** (what form 2086
  needs), not gross buys/sells. Positive = gain, negative = loss.
- **Imports are idempotent** — re-running the same file inserts nothing (ext_id is
  derived from row content). Safe to retry; report `inserted` vs `skipped`.
- **The rate card is data, not code** — `bilan rule list` / `bilan rule set 2027
  micro_bnc deduction_pct_tenths 340` (decipercent tenths: 340 = 34.0%). A loi de
  finances change is an UPDATE, not a release. All math is integer cents.
- **The radar is estimates, not advice** — the IR progressive scale is out of scope
  (v0); net figures are post-abattement only. Say so to the human.

## The radar's JSON (what to explain)

`bilan tax` → `rates` (the active rate card) · `regimes` (per-regime gross,
abattement, net_ir, social) · `crypto` (net gains + `exempt`: net gains under the
threshold — €305 seeded — are not declarable, form 2086 skipped) · `capital`
(taxable + PFU) · `totals` (flat tax + social). Walk the human through 2042-C-PRO
cases (5HQ/5HY for BNC) and the 2086 decision from `crypto.exempt`.

## Hosted PAYG (when BILAN_URL is set)

The first `BILAN_GIFT_CALLS` (default 50) calls per token are a gift. Past the gift,
each call costs 1 peage cent charged to the wallet you send in `X-Peage-Wallet`.
When the gift is spent and no wallet is present (or it is empty), the API answers
**402** with a pay object:

```json
{"ok":false,"error":"...","pay":{"rail":"peage","price_cents":1,
 "header":"X-Peage-Wallet",
 "wallet_create":"POST https://peage.intrane.fr/v1/wallets",
 "topup":"POST https://peage.intrane.fr/v1/topup"}}
```

Your move: create a peage wallet (it ships with free starter credit), pass it as
`X-Peage-Wallet`, and when it runs dry, POST /v1/topup and hand the Stripe link to
the human. Local mode owes nobody.

## Gotchas

- Amounts are EUR; the ledger stores integer cents — never floats.
- `bilan tx add` on an unknown stream dies 94 with the create command in the error.
- A duplicate tx (same stream/date/amount/label) returns `{"ok":true,"duplicate":true}`
  and writes nothing — do not retry it as an error.
- The hosted API is Bearer-gated; `/guide`, `/llms.txt`, `/_health` and `/` are open.

## Brian — the persona (the cheap copilote)

Brian is a persona, not a service: install it into the harness your human already
pays for. Run `bilan brian`, paste the output into the harness instructions
(CLAUDE.md / AGENTS.md / system prompt). The rules it installs:

- **Never invent a number** — every figure you say comes from a bilan command you
  just ran. No bilan output => no opinion with numbers.
- **Max 3 moves/day**, each with Action + Pourquoi + Impact (record with
  `bilan move add --kind controle|securite|construction|patrimoine`).
- The human approves on the dashboard (`GET /app` — hosted: paste the token once)
  or `bilan move done <id>`.
- French, tutoiement, short sentences, not an advisor — decisions stay the human's.
- Morning loop: `bilan brief` (provision, stream momentum, pending moves) →
  propose moves → next day, verify the impact with the same numbers.

The dashboard (`/app`) is the human's view of the same ledger: provision,
per-stream momentum, moves to approve. Local: open directly; hosted: paste the
token once at /app/login (signed session cookie).
