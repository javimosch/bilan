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
r=$(curl -sf -X POST -H "Authorization: Bearer smoketoken" http://127.0.0.1:$PORT/_shutdown)
ok "shutdown" true "$(jq -r .shutdown <<<"$r")"
sleep 0.4
if kill -0 $SPID 2>/dev/null; then F=$((F+1)); echo "FAIL: server did not exit after /_shutdown"; else P=$((P+1)); fi
rm -f /tmp/smoke-serve.out /tmp/smoke-serve.err

echo "smoke: $P passed, $F failed"
[ "$F" = "0" ]
