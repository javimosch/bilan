#!/usr/bin/env bash
# Offline end-to-end smoke: every CLI command, the error contract (typed stderr JSON +
# semantic exit codes), idempotent import, the tax radar math, feedback dual-write, and
# the serve daemon (health, bearer gate, shutdown). No network, no real API.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN=./bilan
[ -x "$BIN" ] || ./build.sh

export BILAN_DB="$(mktemp -u /tmp/bilan-smoke-XXXXXX.db)"
P=0; F=0
ok(){   if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $1 — got [$3] want [$2]"; fi; }
okre(){ if printf '%s' "$3" | grep -qE "$2"; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $1 — [$3] !~ /$2/"; fi; }
code_of(){ "$@" >/dev/null 2>/tmp/smoke-err; echo $?; }
trap 'rm -f "$BILAN_DB" /tmp/smoke-err /tmp/smoke-etoro.csv' EXIT

# --- meta surfaces ----------------------------------------------------------
okre "version"            '"version":"[0-9]'        "$($BIN version)"
okre "help is json"       '"ok":true'               "$($BIN help)"
ok  "help-json first cmd" "stream add"              "$(jq -r .commands[0].name <<<"$($BIN help-json)")"
okre "guide mentions no-LLM rule" 'NO LLM inside'   "$($BIN guide)"
okre "guide has command ref"      '## Command reference' "$($BIN guide)"

# --- per-command help (--help / help <cmd> must NOT run the command) -----------
okre "help tax -> per-command"     '"command":"tax"'    "$($BIN help tax)"
okre "tax --help -> usage not data" '"command":"tax"'   "$($BIN tax --help)"
ok "tax --help exit 0"             0 "$(code_of $BIN tax --help)"
okre "stats --help -> usage"       '"command":"stats"'  "$($BIN stats --help)"
okre "brief --help -> usage"       '"command":"brief"'  "$($BIN brief --help)"
okre "stream --help -> usage"      '"command":"stream"' "$($BIN stream --help)"
okre "tx --help -> usage"          '"command":"tx"'     "$($BIN tx --help)"
okre "move --help -> usage"        '"command":"move"'   "$($BIN move --help)"
okre "import --help -> usage"      '"command":"import"' "$($BIN import --help)"
ok "help bogus -> error"           false "$(jq -r .ok <<<"$($BIN help boguscmd 2>&1)")"
okre "unknown cmd hints help"      'bilan help'         "$($BIN boguscmd 2>&1)"

# --- streams ----------------------------------------------------------------
ok "stream add missing kind -> 80" 80 "$(code_of $BIN stream add x)"
ok "stream add bad kind -> 80"     80 "$(code_of $BIN stream add x --kind nope)"
r=$($BIN stream add freelance --kind bnc)
ok "stream add" true "$(jq -r .ok <<<"$r")"
ok "stream add dup -> 93" 93 "$(code_of $BIN stream add freelance --kind bnc)"
$BIN stream add crypto --kind crypto >/dev/null
ok "stream list has bnc" bnc "$(jq -r '[.streams[] | select(.name=="freelance") | .kind][0]' <<<"$($BIN stream list)")"

# --- tx ---------------------------------------------------------------------
ok "tx add bad stream -> 94" 94 "$(code_of $BIN tx add ghost 2026-01-01 10)"
ok "tx add bad date -> 80"   80 "$(code_of $BIN tx add freelance 2026-1-1 10)"
ok "tx add bad amount -> 80" 80 "$(code_of $BIN tx add freelance 2026-01-01 abc)"
r=$($BIN tx add freelance 2026-03-15 1200.50 --label "mission conseil")
ok "tx add" 120050 "$(jq -r .cents <<<"$r")"
r=$($BIN tx add freelance 2026-03-15 1200.50 --label "mission conseil")
ok "tx add duplicate detected" true "$(jq -r .duplicate <<<"$r")"
$BIN tx add freelance 2026-04-10 350.25 --label "fr comma" >/dev/null
ok "tx list cents" 35025 "$(jq -r '.txs[0].cents' <<<"$($BIN tx list --stream freelance)")"

# --- import (generic via stdin; idempotent) ---------------------------------
CSV='date,amount,label
2026-02-01,100.00,invoice A
2026-02-15,200.50,mission B
15/03/2026,75,fr date row
badrow,notanumber,skipped'
r=$(printf '%s\n' "$CSV" | $BIN import generic - --stream freelance)
ok "import inserts 3"  3 "$(jq -r .inserted <<<"$r")"
ok "import skips 1"    1 "$(jq -r .skipped <<<"$r")"
r=$(printf '%s\n' "$CSV" | $BIN import generic - --stream freelance)
ok "re-import idempotent" 0 "$(jq -r .inserted <<<"$r")"

# --- stats ------------------------------------------------------------------
r=$($BIN stats --year 2026)
ok "stats bnc total" 192625 "$(jq -r .by_kind.bnc.cents <<<"$r")"
ok "stats net"       192625 "$(jq -r .net_cents <<<"$r")"

# --- tax radar --------------------------------------------------------------
printf 'Close Date,Profit(EUR),Details\n2026-05-01,54.40,BTC\n2026-06-01,-18.44,ETH\n' > /tmp/smoke-etoro.csv
r=$($BIN import etoro /tmp/smoke-etoro.csv --stream crypto)
ok "etoro import" 2 "$(jq -r .inserted <<<"$r")"
r=$($BIN tax --year 2026)
ok "tax bnc gross"     192625 "$(jq -r .regimes.bnc.gross_cents <<<"$r")"
ok "tax bnc abattement 34%" 65492 "$(jq -r .regimes.bnc.abattement_cents <<<"$r")"
ok "tax bnc net after abattement" 127133 "$(jq -r .regimes.bnc.net_ir_cents <<<"$r")"
ok "tax bnc social"    47385 "$(jq -r .regimes.bnc.social_cents <<<"$r")"
ok "crypto net (5440-1844)" 3596 "$(jq -r .crypto.net_cents <<<"$r")"
ok "crypto exempt under 305 EUR" true "$(jq -r .crypto.exempt <<<"$r")"
ok "capital tax on 3596 @31.4%" 1129 "$(jq -r .capital.tax_cents <<<"$r")"
ok "rule list has pfu" 314 "$(jq -r '.rules[] | select(.param=="pfu_pct_tenths") | .value' <<<"$($BIN rule list)")"
r=$($BIN rule set 2027 micro_bnc deduction_pct_tenths 350)
ok "rule set" 350 "$(jq -r .value <<<"$r")"
ok "rule list year filter" 340 "$(jq -r '[.rules[] | select(.year==2026 and .regime=="micro_bnc" and .param=="deduction_pct_tenths") | .value][0]' <<<"$($BIN rule list --year 2026)")"

# --- foncier social (micro-foncier has 17.2% social on net after abattement) ---
$BIN stream add appart --kind rent >/dev/null
$BIN tx add appart 2026-03-10 1000 --label "loyer mensuel" >/dev/null
r=$($BIN tax --year 2026)
ok "foncier abattement 30%" 30000 "$(jq -r .regimes.foncier.abattement_cents <<<"$r")"
ok "foncier net after abattement" 70000 "$(jq -r .regimes.foncier.net_ir_cents <<<"$r")"
ok "foncier social 17.2% on net" 12040 "$(jq -r .regimes.foncier.social_cents <<<"$r")"
ok "foncier social in totals" 59425 "$(jq -r .totals.social_cents <<<"$r")"

# --- progressive IR barème (5 brackets, quotient familial, 10% frais, décote) ---
IRDB="$(mktemp -u /tmp/bilan-ir-XXXXXX.db)"
BILAN_DB="$IRDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$IRDB" $BIN tx add sal 2026-06-30 50000 --label "salaire annuel" >/dev/null
r=$(BILAN_DB="$IRDB" $BIN tax --year 2026)
# 50000 EUR salary - 10% frais (5000, within 509..14555) = 45000 EUR net imposable.
# 2025 barème: 11% on (29315-11497)=17818 -> 1960.0; 30% on (45000-29315)=15685 -> 4705.5
# IR brut = 6665.50 EUR; décote = 889 - 45.25%×6665.50 = negative -> 0. IR = 6665.48.
ok "salary 10% frais abattement" 500000 "$(jq -r .regimes.salary.frais_abattement_cents <<<"$r")"
ok "salary net after frais" 4500000 "$(jq -r .regimes.salary.net_cents <<<"$r")"
ok "ir base = salary net after frais" 4500000 "$(jq -r .ir.base_cents <<<"$r")"
ok "ir 11%+30% brackets (2025 barème)" 666548 "$(jq -r .ir.ir_cents <<<"$r")"
ok "ir marginal 30%" 30 "$(jq -r .ir.marginal_rate_pct <<<"$r")"
ok "ir parts default 1" 1 "$(jq -r .ir.parts <<<"$r")"
ok "ir in totals" 666548 "$(jq -r .totals.ir_cents <<<"$r")"
ok "total_tax = ir + flat + social" 666548 "$(jq -r .totals.total_tax_cents <<<"$r")"
# quotient familial: 2 parts halves the quotient -> IR drops
BILAN_DB="$IRDB" $BIN rule set 2026 ir_bareme parts 2 >/dev/null
r=$(BILAN_DB="$IRDB" $BIN tax --year 2026)
# quotient = 4500000/2 = 2250000; 11% on (2250000-1149700)=1100300 -> 121033; x2 = 242066
ok "ir QF 2 parts lowers IR" 242066 "$(jq -r .ir.ir_cents <<<"$r")"
rm -f "$IRDB"

# --- décote (low IR: 24000 EUR salary -> 21600 net -> 1111.33 brut -> 725.20 after décote) ---
DCDB="$(mktemp -u /tmp/bilan-decote-XXXXXX.db)"
BILAN_DB="$DCDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$DCDB" $BIN tx add sal 2026-06-30 24000 --label "low salary" >/dev/null
r=$(BILAN_DB="$DCDB" $BIN tax --year 2026)
ok "décote: ir before décote" 111133 "$(jq -r .ir.ir_before_decote_cents <<<"$r")"
ok "décote: amount" 38613 "$(jq -r .ir.decote_cents <<<"$r")"
ok "décote: ir after décote" 72520 "$(jq -r .ir.ir_cents <<<"$r")"
rm -f "$DCDB"

# --- deficits carried forward (BNC: prior-year loss offsets current-year gross) ---
DFDB="$(mktemp -u /tmp/bilan-deficit-XXXXXX.db)"
BILAN_DB="$DFDB" $BIN stream add biz --kind bnc >/dev/null
BILAN_DB="$DFDB" $BIN tx add biz 2020-06-30 -80000 --label "loss 2020" >/dev/null
BILAN_DB="$DFDB" $BIN tx add biz 2026-06-30 60000 --label "profit 2026" >/dev/null
r=$(BILAN_DB="$DFDB" $BIN tax --year 2026)
# 2020 loss 80000 EUR (8000000 cents) carries forward (no intermediate years use it);
# 2026 gross 60000 EUR - deficit 80000 EUR = -20000, clamped to 0 adjusted gross.
ok "deficit carried forward (6y)" 8000000 "$(jq -r .regimes.bnc.deficit_carried_cents <<<"$r")"
ok "deficit adjusts gross (clamped to 0)" 0 "$(jq -r .regimes.bnc.adjusted_gross_cents <<<"$r")"
rm -f "$DFDB"

# --- fixtures (realistic broker exports; no real PII available on this box) --
$BIN stream add etoro --kind crypto >/dev/null
r=$($BIN import etoro test/fixtures/etoro-2026.csv --stream etoro)
ok "etoro fixture rows" 3 "$(jq -r .inserted <<<"$r")"
ok "etoro net P/L (3596 from crypto + 15596 from etoro)" 19192 "$(jq -r .by_kind.crypto.cents <<<"$($BIN stats --year 2026)")"
r=$($BIN import revolut test/fixtures/revolut-crypto-2026.csv --stream etoro)
ok "revolut fixture rows" 2 "$(jq -r .inserted <<<"$r")"
$BIN stream add diverse --kind other >/dev/null
r=$(cat test/fixtures/generic-fr-2026.csv | $BIN import generic - --stream diverse)
ok "fr semicolon csv rows" 3 "$(jq -r .inserted <<<"$r")"
ok "fr amounts parse (1 234,56)" 186406 "$(jq -r .by_kind.other.cents <<<"$($BIN stats --year 2026)")"

# --- demo (deterministic cold-start data, idempotent) -------------------------
DEMODB="$(mktemp -u /tmp/bilan-demo-XXXXXX.db)"
r=$(BILAN_DB="$DEMODB" $BIN demo)
ok "demo seeds 21 txs" 21 "$(jq -r .txs_ensured <<<"$r")"
ok "demo lists 4 streams" 4 "$(jq -r '.streams | length' <<<"$r")"
r=$(BILAN_DB="$DEMODB" $BIN demo)
ok "demo idempotent re-run" 0 "$(jq -r .txs_ensured <<<"$r")"
ok "demo stats has salary" 1080000 "$(jq -r .by_kind.salary.cents <<<"$(BILAN_DB="$DEMODB" $BIN stats --year 2026)")"
ok "demo stats has bnc" 2030000 "$(jq -r .by_kind.bnc.cents <<<"$(BILAN_DB="$DEMODB" $BIN stats --year 2026)")"
ok "demo stats has crypto" 173000 "$(jq -r .by_kind.crypto.cents <<<"$(BILAN_DB="$DEMODB" $BIN stats --year 2026)")"
ok "demo stats has rent" 565000 "$(jq -r .by_kind.rent.cents <<<"$(BILAN_DB="$DEMODB" $BIN stats --year 2026)")"
rm -f "$DEMODB"

# --- Brian: brief + moves + dashboard ---------------------------------------
okre "brian persona" 'copilote financier' "$($BIN brian)"
r=$($BIN move add --kind securite --action "provisionner 2774 EUR" --pourquoi "flat tax + sociales YTD" --impact "couvert au prochain salaire")
MID=$(jq -r .id <<<"$r")
ok "move add" true "$(jq -r .ok <<<"$r")"
ok "move list" 1 "$(jq '.moves | length' <<<"$($BIN move list --status proposed)")"
r=$($BIN brief --year 2026)
WANT=$(( $(jq -r .totals.ir_cents <<<"$($BIN tax --year 2026)") + $(jq -r .totals.flat_tax_cents <<<"$($BIN tax --year 2026)") + $(jq -r .totals.social_cents <<<"$($BIN tax --year 2026)") ))
ok "brief provision matches tax" "$WANT" "$(jq -r .provision.total_cents <<<"$r")"
ok "brief has moves" 1 "$(jq '.moves | length' <<<"$r")"
okre "brief momentum field" '"momentum":"[a-z]' "$r"
$BIN move done "$MID" >/dev/null
ok "move done" done "$(jq -r '.moves[0].status' <<<"$($BIN move list)")"

# --- feedback (relay off: never fails, reports honestly) --------------------
r=$(FEEDBACK_RELAY=off $BIN feedback "smoke test" --kind idea)
ok "feedback ok"      false "$(jq -r .relayed <<<"$r")"
okre "feedback has id" '"id":"[0-9a-f]' "$r"

# --- serve (daemon lifecycle + bearer gate) ---------------------------------
PORT=$(( 18000 + RANDOM % 20000 ))
BILAN_TOKEN=smoketoken $BIN serve --port "$PORT" >/tmp/smoke-serve.out 2>/tmp/smoke-serve.err &
SPID=$!
sleep 0.4
okre "health open" '"ok":true' "$(curl -sf http://127.0.0.1:$PORT/_health)"
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/v1/streams)
ok "v1 without token -> 401" 401 "$code"
r=$(curl -sf -H "Authorization: Bearer smoketoken" http://127.0.0.1:$PORT/v1/streams)
ok "v1 streams with token" bnc "$(jq -r '[.streams[] | select(.name=="freelance") | .kind][0]' <<<"$r")"
r=$(curl -sf -H "Authorization: Bearer smoketoken" "http://127.0.0.1:$PORT/v1/tax?year=2026")
ok "v1 tax exempt" true "$(jq -r .crypto.exempt <<<"$r")"
r=$(curl -sf -X POST -H "Authorization: Bearer smoketoken" -H "content-type: application/json" \
     -d '{"name":"rent","kind":"rent"}' http://127.0.0.1:$PORT/v1/streams)
ok "v1 stream create" true "$(jq -r .ok <<<"$r")"
okre "guide over http" 'NO LLM inside' "$(curl -sf http://127.0.0.1:$PORT/guide)"
okre "dashboard serves" 'image du jour' "$(curl -sf http://127.0.0.1:$PORT/app)"
r=$(curl -sf -X POST -H "Authorization: Bearer smoketoken" -H "content-type: application/json" \
  -d '{"kind":"controle","action":"verifier le stream muet","pourquoi":"aucune ecriture depuis 60j","impact":"visibilite"}' \
  http://127.0.0.1:$PORT/v1/moves)
ok "v1 move add" true "$(jq -r .ok <<<"$r")"
r=$(curl -sf -H "Authorization: Bearer smoketoken" "http://127.0.0.1:$PORT/v1/brief?year=2026")
WANTV1=$(( $(jq -r .totals.ir_cents <<<"$($BIN tax --year 2026)") + $(jq -r .totals.flat_tax_cents <<<"$($BIN tax --year 2026)") + $(jq -r .totals.social_cents <<<"$($BIN tax --year 2026)") ))
ok "v1 brief provision matches tax" "$WANTV1" "$(jq -r .provision.total_cents <<<"$r")"
okre "landing page" 'pluri-actifs' "$(curl -sf http://127.0.0.1:$PORT/)"
okre "landing links the specs" 'cli-specs.intrane.fr' "$(curl -sf http://127.0.0.1:$PORT/)"
r=$(curl -sf -X POST -H "Authorization: Bearer smoketoken" http://127.0.0.1:$PORT/_shutdown)
ok "shutdown" true "$(jq -r .shutdown <<<"$r")"
sleep 0.4
if kill -0 $SPID 2>/dev/null; then F=$((F+1)); echo "FAIL: server did not exit after /_shutdown"; else P=$((P+1)); fi
rm -f /tmp/smoke-serve.out /tmp/smoke-serve.err

# --- hosted PAYG (gift credit, then 402 with the peage pay object) -----------
HOMEDIR=$(mktemp -d)
HPORT=$(( 12000 + RANDOM % 20000 ))
HOME="$HOMEDIR" BILAN_HOSTED=1 BILAN_GIFT_CALLS=3 BILAN_TOKEN=optoken $BIN serve --port "$HPORT" >/tmp/smoke-hosted.out 2>/tmp/smoke-hosted.err &
HPID=$!
sleep 0.4
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer tenant-a" http://127.0.0.1:$HPORT/v1/stats)
ok "hosted gift call 1 -> 200" 200 "$code"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer tenant-a" http://127.0.0.1:$HPORT/v1/streams)
ok "hosted gift call 2 -> 200" 200 "$code"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer tenant-a" http://127.0.0.1:$HPORT/v1/tx)
ok "hosted gift call 3 -> 200" 200 "$code"
r=$(curl -s -H "Authorization: Bearer tenant-a" http://127.0.0.1:$HPORT/v1/stats)
ok "gift exhausted -> 402 pay object" peage "$(jq -r .pay.rail <<<"$r")"
ok "  ...price on the pay object" 1 "$(jq -r .pay.price_cents <<<"$r")"
# telemetry: the 4 calls above (3 gift + 1 402) are recorded; CLI reads them back.
# Local mode (no BILAN_HOSTED) reports telemetry:false — verified separately below.
r=$(HOME="$HOMEDIR" BILAN_HOSTED=1 $BIN telemetry)
ok "hosted telemetry records events" 4 "$(jq -r '.totals[0].n // .totals.n // empty' <<<"$r" 2>/dev/null || jq -r '.by_event[0].n // .by_event[].n' <<<"$r" | head -1)"
ok "hosted telemetry counts errors (402)" 1 "$(jq -r '[.by_event[].errs // 0] | add' <<<"$r" 2>/dev/null || echo 0)"
# local mode telemetry is a no-op (the OSS binary owes nobody metrics)
r=$($BIN telemetry)
ok "local telemetry is a no-op" false "$(jq -r .telemetry <<<"$r")"
# CLI hosted mode: same agent surface against the hosted API (fresh tenant, 3 gift calls)
export BILAN_URL=http://127.0.0.1:$HPORT BILAN_TOKEN=cli-tenant
r=$($BIN stream add hosted --kind bnc)
ok "cli hosted stream add" true "$(jq -r .ok <<<"$r")"
r=$($BIN tx add hosted 2026-01-15 100 --label x)
ok "cli hosted tx add" 10000 "$(jq -r .cents <<<"$r")"
r=$($BIN stats --year 2026)
okre "cli hosted stats" '"ok":true' "$r"
code=$($BIN tax --year 2026 >/dev/null 2>/tmp/smoke-402.err; echo $?)
ok "cli post-gift exits 100" 100 "$code"
ok "cli 402 carries pay link" peage "$(jq -r .pay.rail </tmp/smoke-402.err)"
unset BILAN_URL BILAN_TOKEN
curl -sf -X POST -H "Authorization: Bearer optoken" http://127.0.0.1:$HPORT/_shutdown >/dev/null
sleep 0.4
if kill -0 $HPID 2>/dev/null; then F=$((F+1)); echo "FAIL: hosted server did not exit"; else P=$((P+1)); fi
rm -rf "$HOMEDIR" /tmp/smoke-hosted.out /tmp/smoke-hosted.err /tmp/smoke-402.err

echo "smoke: $P passed, $F failed"
[ "$F" = "0" ]
