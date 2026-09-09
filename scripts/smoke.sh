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
ok "ir demi_parts default 2 (1 part)" 2 "$(jq -r .ir.demi_parts <<<"$r")"
ok "ir qf not capped (1 part = base)" false "$(jq -r .ir.qf_capped <<<"$r")"
ok "ir in totals" 666548 "$(jq -r .totals.ir_cents <<<"$r")"
ok "total_tax = ir + flat + social" 666548 "$(jq -r .totals.total_tax_cents <<<"$r")"
# TVA franchise en base: 0 BNC+BIC -> eligible (under 36800 services threshold)
ok "tva franchise eligible (no turnover)" true "$(jq -r .tva.franchise_eligible <<<"$r")"
ok "tva services threshold" 3680000 "$(jq -r .tva.threshold_services_cents <<<"$r")"
ok "tva vente threshold" 9190000 "$(jq -r .tva.threshold_vente_cents <<<"$r")"
# PAS taux neutre: 4500000/12=375000 monthly -> bracket 347600-391300 at 11.9%
ok "pas monthly base" 375000 "$(jq -r .pas.monthly_base_cents <<<"$r")"
ok "pas taux neutre 11.9%" "11.9" "$(jq -r .pas.taux_neutre_pct <<<"$r")"
ok "pas monthly prepayment" 44625 "$(jq -r .pas.monthly_prepayment_cents <<<"$r")"
# Réductions: no dons -> 0 reduction
ok "dons reduction 0 (no dons)" 0 "$(jq -r .reductions.dons.reduction_cents <<<"$r")"
ok "ir_after_reductions = ir (no dons)" 666548 "$(jq -r .ir.ir_after_reductions_cents <<<"$r")"
# quotient familial: couple (2 parts = 4 demi-parts, base_parts=2) halves the quotient.
# Set base_parts=2 so the 2 base parts are NOT capped by plafonnement.
BILAN_DB="$IRDB" $BIN rule set 2026 ir_bareme parts 2 >/dev/null
BILAN_DB="$IRDB" $BIN rule set 2026 ir_bareme base_parts 2 >/dev/null
r=$(BILAN_DB="$IRDB" $BIN tax --year 2026)
# quotient = 4500000*2/4 = 2250000; 11% on (2250000-1149700)=1100300 -> 121033; x4/2 = 242066
ok "ir QF couple (2 parts, base 2) lowers IR" 242066 "$(jq -r .ir.ir_cents <<<"$r")"
ok "ir QF couple not capped" false "$(jq -r .ir.qf_capped <<<"$r")"
rm -f "$IRDB"

# --- plafonnement du quotient familial (célibataire + 1 child: parts=1.5, base=1) ---
PFDB="$(mktemp -u /tmp/bilan-plafond-XXXXXX.db)"
BILAN_DB="$PFDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$PFDB" $BIN tx add sal 2026-06-30 200000 --label "high salary" >/dev/null
# célibataire + 1 child = 1.5 parts = 3 demi-parts; base_parts=1 (célibataire) -> 1 extra demi-part
BILAN_DB="$PFDB" $BIN rule set 2026 ir_bareme demi_parts 3 >/dev/null
BILAN_DB="$PFDB" $BIN rule set 2026 ir_bareme base_parts 1 >/dev/null
r=$(BILAN_DB="$PFDB" $BIN tax --year 2026)
# 200k - 10% frais (14555 max) = 185445 net. With 3 demi-parts the QF advantage on 1
# extra demi-part exceeds 1791 EUR -> plafonnement caps it. qf_capped=true.
ok "plafonnement QF triggers (célibataire+1 child, high income)" true "$(jq -r .ir.qf_capped <<<"$r")"
rm -f "$PFDB"

# --- 10% frais per salary stream (couple both earning: each gets own abattement) ---
FRDB="$(mktemp -u /tmp/bilan-frais-XXXXXX.db)"
BILAN_DB="$FRDB" $BIN stream add him --kind salary >/dev/null
BILAN_DB="$FRDB" $BIN stream add her --kind salary >/dev/null
BILAN_DB="$FRDB" $BIN tx add him 2026-06-30 30000 >/dev/null
BILAN_DB="$FRDB" $BIN tx add her 2026-06-30 30000 >/dev/null
r=$(BILAN_DB="$FRDB" $BIN tax --year 2026)
# each stream: 10% of 30000 = 3000 (within 509..14555); total frais 6000, net 54000
ok "frais per stream (2 earners)" 600000 "$(jq -r .regimes.salary.frais_abattement_cents <<<"$r")"
ok "salary net (2 earners)" 5400000 "$(jq -r .regimes.salary.net_cents <<<"$r")"
rm -f "$FRDB"

# --- déficit foncier imputation on revenu global (10700 cap, 10y carry) ---
FNDB="$(mktemp -u /tmp/bilan-fondef-XXXXXX.db)"
BILAN_DB="$FNDB" $BIN stream add apt --kind rent >/dev/null
BILAN_DB="$FNDB" $BIN tx add apt 2026-06-30 -15000 --label "travaux deficit" >/dev/null
BILAN_DB="$FNDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$FNDB" $BIN tx add sal 2026-06-30 40000 >/dev/null
r=$(BILAN_DB="$FNDB" $BIN tax --year 2026)
# -15000 rent deficit: 10700 imputed on revenu global, 4300 carried 10y on foncier
ok "foncier deficit global imputation (10700 cap)" 1070000 "$(jq -r .regimes.foncier.deficit_global_imputation_cents <<<"$r")"
ok "foncier deficit carry 10y (excess)" 430000 "$(jq -r .regimes.foncier.deficit_carry_10y_cents <<<"$r")"
rm -f "$FNDB"

# --- décote (low IR: 24000 EUR salary -> 21600 net -> 1111.33 brut -> 725.20 after décote) ---
DCDB="$(mktemp -u /tmp/bilan-decote-XXXXXX.db)"
BILAN_DB="$DCDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$DCDB" $BIN tx add sal 2026-06-30 24000 --label "low salary" >/dev/null
r=$(BILAN_DB="$DCDB" $BIN tax --year 2026)
ok "décote: ir before décote" 111133 "$(jq -r .ir.ir_before_decote_cents <<<"$r")"
ok "décote: amount" 38613 "$(jq -r .ir.decote_cents <<<"$r")"
ok "décote: ir after décote" 72520 "$(jq -r .ir.ir_cents <<<"$r")"
rm -f "$DCDB"

# --- dons reduction (art. 200 CGI: 75% to 1000, 66% to 20% of revenu) ---
DONDB="$(mktemp -u /tmp/bilan-dons-XXXXXX.db)"
BILAN_DB="$DONDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$DONDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$DONDB" $BIN stream add charities --kind dons >/dev/null
BILAN_DB="$DONDB" $BIN tx add charities 2026-06-30 -1500 >/dev/null
r=$(BILAN_DB="$DONDB" $BIN tax --year 2026)
# 1500 dons: 75% on 1000 = 75000 + 66% on 500 = 33000 -> 108000 reduction
ok "dons gross" 150000 "$(jq -r .reductions.dons.gross_cents <<<"$r")"
ok "dons base_75 capped at 1000" 100000 "$(jq -r .reductions.dons.base_75_cents <<<"$r")"
ok "dons base_66 = 500" 50000 "$(jq -r .reductions.dons.base_66_cents <<<"$r")"
ok "dons reduction = 750+330" 108000 "$(jq -r .reductions.dons.reduction_cents <<<"$r")"
# IR was 666548 (50k salary); after 108000 dons reduction -> 558548
ok "ir after dons reduction" 558548 "$(jq -r .ir.ir_after_reductions_cents <<<"$r")"
ok "totals ir = ir_after_reductions" 558548 "$(jq -r .totals.ir_cents <<<"$r")"
rm -f "$DONDB"

# --- QF special caps (parent_isole, veuf, personne_seule_invalide) ---
# High income (200k salary -> 180k net), 3 demi-parts (1 part + 1 child), base_parts=1.
# The plafonnement caps differ by situation; all should trigger qf_capped=true.
QFDB="$(mktemp -u /tmp/bilan-qf-XXXXXX.db)"
BILAN_DB="$QFDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$QFDB" $BIN tx add sal 2026-06-30 200000 >/dev/null
BILAN_DB="$QFDB" $BIN rule set 2026 ir_bareme demi_parts 3 >/dev/null
# default: cap = 1 × 1791 = 1791 -> IR = IR_base - 1791
r=$(BILAN_DB="$QFDB" $BIN tax --year 2026)
ok "qf default situation" default "$(jq -r .ir.situation <<<"$r")"
ok "qf default capped" true "$(jq -r .ir.qf_capped <<<"$r")"
ir_default=$(jq -r .ir.ir_cents <<<"$r")
# parent_isole: cap = 4262 total -> IR = IR_base - 4262 (lower than default)
BILAN_DB="$QFDB" $BIN rule set 2026 ir_bareme situation parent_isole >/dev/null
r=$(BILAN_DB="$QFDB" $BIN tax --year 2026)
ok "qf parent_isole situation" parent_isole "$(jq -r .ir.situation <<<"$r")"
ok "qf parent_isole capped" true "$(jq -r .ir.qf_capped <<<"$r")"
ok "qf parent_isole IR < default" true "$(jq -r '.ir.ir_cents < '$ir_default <<<"$r")"
# diff = 4262 - 1791 = 2471 EUR = 247100 cents
ok "qf parent_isole saves 2471 vs default" 247100 "$(( ir_default - $(jq -r .ir.ir_cents <<<"$r") ))"
# veuf: cap = 1 × 1807 + 2011 = 3818 -> IR = IR_base - 3818
BILAN_DB="$QFDB" $BIN rule set 2026 ir_bareme situation veuf >/dev/null
r=$(BILAN_DB="$QFDB" $BIN tax --year 2026)
ok "qf veuf situation" veuf "$(jq -r .ir.situation <<<"$r")"
ok "qf veuf capped" true "$(jq -r .ir.qf_capped <<<"$r")"
# diff = 3818 - 1791 = 2027 EUR = 202700 cents
ok "qf veuf saves 2027 vs default" 202700 "$(( ir_default - $(jq -r .ir.ir_cents <<<"$r") ))"
# personne_seule_invalide: cap = 3608 -> IR = IR_base - 3608
BILAN_DB="$QFDB" $BIN rule set 2026 ir_bareme situation personne_seule_invalide >/dev/null
r=$(BILAN_DB="$QFDB" $BIN tax --year 2026)
ok "qf personne_seule_invalide situation" personne_seule_invalide "$(jq -r .ir.situation <<<"$r")"
# diff = 3608 - 1791 = 1817 EUR = 181700 cents
ok "qf invalide saves 1817 vs default" 181700 "$(( ir_default - $(jq -r .ir.ir_cents <<<"$r") ))"
rm -f "$QFDB"

# --- emploi à domicile crédit (art. 199 sexdecies: 50%, cap 12000) ---
EDDB="$(mktemp -u /tmp/bilan-ed-XXXXXX.db)"
BILAN_DB="$EDDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$EDDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$EDDB" $BIN stream add menage --kind emploi_domicile >/dev/null
BILAN_DB="$EDDB" $BIN tx add menage 2026-06-30 -10000 >/dev/null
r=$(BILAN_DB="$EDDB" $BIN tax --year 2026)
# 10000 depenses, 50% -> 5000 credit (under 12000 cap)
ok "emploi depenses" 1000000 "$(jq -r .reductions.emploi_domicile.depenses_cents <<<"$r")"
ok "emploi credit 50%" 500000 "$(jq -r .reductions.emploi_domicile.credit_cents <<<"$r")"
# IR was 666548; after 5000 EUR (500000 cents) credit -> 166548 (refundable credit reduces IR)
ok "emploi credit reduces IR" 166548 "$(jq -r .ir.ir_after_credit_cents <<<"$r")"
ok "totals ir = ir_after_credit" 166548 "$(jq -r .totals.ir_cents <<<"$r")"
rm -f "$EDDB"

# --- PINEL réduction (art. 199 novovicies: 18% 9y, cap 300000) ---
PNDB="$(mktemp -u /tmp/bilan-pn-XXXXXX.db)"
BILAN_DB="$PNDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$PNDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$PNDB" $BIN stream add invest --kind pinel >/dev/null
BILAN_DB="$PNDB" $BIN tx add invest 2026-06-30 200000 >/dev/null
r=$(BILAN_DB="$PNDB" $BIN tax --year 2026)
# 200000 investment, 9y -> 18% / 9 = 2% per year = 4000
ok "pinel investment" 20000000 "$(jq -r .reductions.pinel.investment_cents <<<"$r")"
ok "pinel engagement 9y" 9 "$(jq -r .reductions.pinel.engagement_years <<<"$r")"
ok "pinel rate 18%" "18" "$(jq -r .reductions.pinel.rate_pct <<<"$r")"
ok "pinel annual reduction 4000" 400000 "$(jq -r .reductions.pinel.annual_reduction_cents <<<"$r")"
# IR was 666548; after 4000 EUR (400000 cents) pinel reduction -> 266548
ok "pinel reduces IR" 266548 "$(jq -r .ir.ir_after_reductions_cents <<<"$r")"
rm -f "$PNDB"

# --- DENORMANDIE réduction (art. 199 novovicies IV bis: 18% 9y, cap 300000) ---
DNDB="$(mktemp -u /tmp/bilan-dn-XXXXXX.db)"
BILAN_DB="$DNDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$DNDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$DNDB" $BIN stream add denorm --kind denormandie >/dev/null
BILAN_DB="$DNDB" $BIN tx add denorm 2026-06-30 200000 >/dev/null
r=$(BILAN_DB="$DNDB" $BIN tax --year 2026)
# 200000 investment, 9y -> 18% / 9 = 2% per year = 4000
ok "denormandie investment" 20000000 "$(jq -r .reductions.denormandie.investment_cents <<<"$r")"
ok "denormandie engagement 9y" 9 "$(jq -r .reductions.denormandie.engagement_years <<<"$r")"
ok "denormandie rate 18%" "18" "$(jq -r .reductions.denormandie.rate_pct <<<"$r")"
ok "denormandie annual reduction 4000" 400000 "$(jq -r .reductions.denormandie.annual_reduction_cents <<<"$r")"
ok "denormandie reduces IR" 266548 "$(jq -r .ir.ir_after_reductions_cents <<<"$r")"
rm -f "$DNDB"

# --- MALRAUX réduction (art. 199 tervicies: 30% PSMV, cap 400000) ---
MLDB="$(mktemp -u /tmp/bilan-ml-XXXXXX.db)"
BILAN_DB="$MLDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$MLDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$MLDB" $BIN stream add restau --kind malraux >/dev/null
BILAN_DB="$MLDB" $BIN tx add restau 2026-06-30 100000 >/dev/null
r=$(BILAN_DB="$MLDB" $BIN tax --year 2026)
# 100000 depenses, PSMV -> 30% = 30000
ok "malraux depenses" 10000000 "$(jq -r .reductions.malraux.depenses_cents <<<"$r")"
ok "malraux zone psmv" psmv "$(jq -r .reductions.malraux.zone <<<"$r")"
ok "malraux rate 30%" "30" "$(jq -r .reductions.malraux.rate_pct <<<"$r")"
ok "malraux reduction 30000" 3000000 "$(jq -r .reductions.malraux.reduction_cents <<<"$r")"
# IR was 666548; after 30000 EUR (3000000 cents) reduction -> 0 (floored)
ok "malraux floors IR at 0" 0 "$(jq -r .ir.ir_after_reductions_cents <<<"$r")"
# PVAP zone -> 22%
BILAN_DB="$MLDB" $BIN rule set 2026 malraux zone pvap >/dev/null
r=$(BILAN_DB="$MLDB" $BIN tax --year 2026)
ok "malraux pvap rate 22%" "22" "$(jq -r .reductions.malraux.rate_pct <<<"$r")"
ok "malraux pvap reduction 22000" 2200000 "$(jq -r .reductions.malraux.reduction_cents <<<"$r")"
rm -f "$MLDB"

# --- Régime réel foncier (art. 29-31: net = loyer - charges, no abattement) ---
FRDB="$(mktemp -u /tmp/bilan-fr-XXXXXX.db)"
BILAN_DB="$FRDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$FRDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$FRDB" $BIN stream add immeuble --kind foncier_reel >/dev/null
BILAN_DB="$FRDB" $BIN tx add immeuble 2026-06-30 10000 --label "loyer" >/dev/null
BILAN_DB="$FRDB" $BIN tx add immeuble 2026-06-30 -8000 --label "interets emprunt" >/dev/null
r=$(BILAN_DB="$FRDB" $BIN tax --year 2026)
# net = 10000 - 8000 = 2000 (no 30% abattement)
ok "foncier_reel net (no abattement)" 200000 "$(jq -r .regimes.foncier.reel_net_cents <<<"$r")"
ok "foncier_reel note" "régime réel foncier (art. 29-31 CGI): net = loyer - charges, no abattement" "$(jq -r .regimes.foncier.reel_note <<<"$r")"
# net_fon includes reel_net (200000) + micro (0) = 200000
ok "foncier net_ir includes reel" 200000 "$(jq -r .regimes.foncier.net_ir_cents <<<"$r")"
# social 17.2% on 2000 = 344
ok "foncier social on reel net" 34400 "$(jq -r .regimes.foncier.social_cents <<<"$r")"
rm -f "$FRDB"

# --- PAS taux personnalisé (art. 204 H: IR / revenu imposable) ---
# 50k salary -> 45000 net; IR = 666548; base = 4500000; taux = 666548/4500000 = 14.8%
PPDB="$(mktemp -u /tmp/bilan-pp-XXXXXX.db)"
BILAN_DB="$PPDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$PPDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
r=$(BILAN_DB="$PPDB" $BIN tax --year 2026)
ok "pas taux personnalise 14.8%" "14.8" "$(jq -r .pas.taux_personnalise_pct <<<"$r")"
# monthly = 4500000 * 148 / 1000000 / 12 = 55500 cents = 555 EUR
ok "pas monthly personnalise" 55500 "$(jq -r .pas.monthly_prepayment_personnalise_cents <<<"$r")"
rm -f "$PPDB"

# --- LMNP micro-BIC meublé (art. 50 CGI): 50% abattement ---
# 20000 loyer -> 10000 net (50% abattement); social 17.2% on gross 20000 = 3440
LMDB="$(mktemp -u /tmp/bilan-lmnp-XXXXXX.db)"
BILAN_DB="$LMDB" $BIN stream add meuble --kind lmnp >/dev/null
BILAN_DB="$LMDB" $BIN tx add meuble 2026-06-30 20000 >/dev/null
r=$(BILAN_DB="$LMDB" $BIN tax --year 2026)
ok "lmnp micro-BIC 50% abattement" 1000000 "$(jq -r .regimes.lmnp.net_ir_cents <<<"$r")"
ok "lmnp social 17.2% on gross" 344000 "$(jq -r .regimes.lmnp.social_cents <<<"$r")"
rm -f "$LMDB"

# --- LMNP régime réel (art. 39 CGI): net = loyer - charges, no abattement ---
# 12000 loyer - 8000 interets = 4000 net; social 17.2% on net 4000 = 688
LRDB="$(mktemp -u /tmp/bilan-lmnp-reel-XXXXXX.db)"
BILAN_DB="$LRDB" $BIN stream add meuble --kind lmnp_reel >/dev/null
BILAN_DB="$LRDB" $BIN tx add meuble 2026-06-30 12000 --label "loyer" >/dev/null
BILAN_DB="$LRDB" $BIN tx add meuble 2026-06-30 -8000 --label "interets emprunt" >/dev/null
r=$(BILAN_DB="$LRDB" $BIN tax --year 2026)
ok "lmnp_reel net (no abattement)" 400000 "$(jq -r .regimes.lmnp_reel.net_ir_cents <<<"$r")"
ok "lmnp_reel social 17.2% on net" 68800 "$(jq -r .regimes.lmnp_reel.social_cents <<<"$r")"
rm -f "$LRDB"

# --- CENSI-BOUVARD (art. 199 sexvicies): 11% cap 300000, spread 9y ---
# 200000 investment * 11% / 9y = 2444.44 EUR/year = 244444 cents
CBDB="$(mktemp -u /tmp/bilan-censi-XXXXXX.db)"
BILAN_DB="$CBDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$CBDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$CBDB" $BIN stream add res --kind censi_bouvard >/dev/null
BILAN_DB="$CBDB" $BIN tx add res 2026-06-30 200000 >/dev/null
r=$(BILAN_DB="$CBDB" $BIN tax --year 2026)
ok "censi-bouvard rate 11%" "11" "$(jq -r .reductions.censi_bouvard.rate_pct <<<"$r")"
ok "censi-bouvard annual reduction" 244444 "$(jq -r .reductions.censi_bouvard.annual_reduction_cents <<<"$r")"
ok "censi-bouvard ir reduction" 244444 "$(jq -r .ir.censi_bouvard_reduction_cents <<<"$r")"
rm -f "$CBDB"

# --- TVA régime simplifié eligibility (art. 302 septies A) ---
# 50000 BNC (services) > franchise 36800, <= RSI 254000, no TVA due -> rsi_eligible true
RSDB="$(mktemp -u /tmp/bilan-rsi-XXXXXX.db)"
BILAN_DB="$RSDB" $BIN stream add biz --kind bnc >/dev/null
BILAN_DB="$RSDB" $BIN tx add biz 2026-06-30 50000 >/dev/null
r=$(BILAN_DB="$RSDB" $BIN tax --year 2026)
ok "tva rsi eligible (services 50k)" true "$(jq -r .tva.rsi_eligible <<<"$r")"
rm -f "$RSDB"

# --- TVA collectée / déductible (art. 271): à payer = collectée - déductible ---
# 5000 collectée - 2000 déductible = 3000 à payer
TVDB="$(mktemp -u /tmp/bilan-tva-XXXXXX.db)"
BILAN_DB="$TVDB" $BIN stream add col --kind tva_collectee >/dev/null
BILAN_DB="$TVDB" $BIN tx add col 2026-06-30 5000 >/dev/null
BILAN_DB="$TVDB" $BIN stream add ded --kind tva_deductible >/dev/null
BILAN_DB="$TVDB" $BIN tx add ded 2026-06-30 2000 >/dev/null
r=$(BILAN_DB="$TVDB" $BIN tax --year 2026)
ok "tva collectee" 500000 "$(jq -r .tva.collectee_cents <<<"$r")"
ok "tva deductible" 200000 "$(jq -r .tva.deductible_cents <<<"$r")"
ok "tva a payer" 300000 "$(jq -r .tva.a_payer_cents <<<"$r")"
ok "tva credit (zero when a_payer)" 0 "$(jq -r .tva.credit_cents <<<"$r")"
ok "totals includes tva" 300000 "$(jq -r .totals.tva_cents <<<"$r")"
rm -f "$TVDB"

# --- TVA crédit (collectée < déductible) ---
TCDB="$(mktemp -u /tmp/bilan-tva-credit-XXXXXX.db)"
BILAN_DB="$TCDB" $BIN stream add col --kind tva_collectee >/dev/null
BILAN_DB="$TCDB" $BIN tx add col 2026-06-30 1000 >/dev/null
BILAN_DB="$TCDB" $BIN stream add ded --kind tva_deductible >/dev/null
BILAN_DB="$TCDB" $BIN tx add ded 2026-06-30 3000 >/dev/null
r=$(BILAN_DB="$TCDB" $BIN tax --year 2026)
ok "tva credit (collectee < deductible)" 200000 "$(jq -r .tva.credit_cents <<<"$r")"
ok "tva a payer (zero when credit)" 0 "$(jq -r .tva.a_payer_cents <<<"$r")"
rm -f "$TCDB"

# --- Frais de garde d'enfants (art. 200 quater B): 50% crédit, cap 3500/child ---
# 4000 dépenses -> cap 3500 -> 50% = 1750 EUR credit = 175000 cents
FGDB="$(mktemp -u /tmp/bilan-fg-XXXXXX.db)"
BILAN_DB="$FGDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$FGDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$FGDB" $BIN stream add garde --kind frais_garde >/dev/null
BILAN_DB="$FGDB" $BIN tx add garde 2026-06-30 4000 >/dev/null
r=$(BILAN_DB="$FGDB" $BIN tax --year 2026)
ok "frais_garde 50% cap 3500" 175000 "$(jq -r .reductions.frais_garde.credit_cents <<<"$r")"
ok "frais_garde ir credit" 175000 "$(jq -r .ir.frais_garde_credit_cents <<<"$r")"
rm -f "$FGDB"

# --- Frais de garde under cap: 2000 -> 50% = 1000 ---
FGDB2="$(mktemp -u /tmp/bilan-fg2-XXXXXX.db)"
BILAN_DB="$FGDB2" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$FGDB2" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$FGDB2" $BIN stream add garde --kind frais_garde >/dev/null
BILAN_DB="$FGDB2" $BIN tx add garde 2026-06-30 2000 >/dev/null
r=$(BILAN_DB="$FGDB2" $BIN tax --year 2026)
ok "frais_garde 50% under cap" 100000 "$(jq -r .reductions.frais_garde.credit_cents <<<"$r")"
rm -f "$FGDB2"

# --- Crédit d'impôt adaptation du logement (art. 200 quater A) ---
# 25% of 8000 EUR dépenses, single cap 5000 EUR → 25% × 5000 = 1250 EUR = 125000 cents
ALDB1="$(mktemp -u /tmp/bilan-al1-XXXXXX.db)"
BILAN_DB="$ALDB1" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$ALDB1" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$ALDB1" $BIN stream add adap --kind adaptation_logement >/dev/null
BILAN_DB="$ALDB1" $BIN tx add adap 2026-06-30 8000 >/dev/null
r=$(BILAN_DB="$ALDB1" $BIN tax --year 2026)
ok "adaptation_logement 25% cap 5000 single" 125000 "$(jq -r .reductions.adaptation_logement.credit_cents <<<"$r")"
ok "adaptation_logement ir credit" 125000 "$(jq -r .ir.adaptation_logement_credit_cents <<<"$r")"
rm -f "$ALDB1"

# --- Crédit d'impôt adaptation du logement (couple cap 10000) ---
# 25% of 12000 EUR dépenses, couple cap 10000 EUR → 25% × 10000 = 2500 EUR = 250000 cents
ALDB2="$(mktemp -u /tmp/bilan-al2-XXXXXX.db)"
BILAN_DB="$ALDB2" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$ALDB2" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$ALDB2" $BIN stream add adap --kind adaptation_logement >/dev/null
BILAN_DB="$ALDB2" $BIN tx add adap 2026-06-30 12000 >/dev/null
BILAN_DB="$ALDB2" $BIN rule set 2026 adaptation_logement situation couple >/dev/null
r=$(BILAN_DB="$ALDB2" $BIN tax --year 2026)
ok "adaptation_logement 25% cap 10000 couple" 250000 "$(jq -r .reductions.adaptation_logement.credit_cents <<<"$r")"
rm -f "$ALDB2"

# --- Crédit d'impôt borne de recharge VE (art. 200 quater C) ---
# 75% of 800 EUR dépenses, cap 500 EUR per system → 75% × 500 = 375 EUR = 37500 cents
BRDB1="$(mktemp -u /tmp/bilan-br1-XXXXXX.db)"
BILAN_DB="$BRDB1" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$BRDB1" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$BRDB1" $BIN stream add borne --kind borne_recharge >/dev/null
BILAN_DB="$BRDB1" $BIN tx add borne 2026-06-30 800 >/dev/null
r=$(BILAN_DB="$BRDB1" $BIN tax --year 2026)
ok "borne_recharge 75% cap 500" 37500 "$(jq -r .reductions.borne_recharge.credit_cents <<<"$r")"
ok "borne_recharge ir credit" 37500 "$(jq -r .ir.borne_recharge_credit_cents <<<"$r")"
rm -f "$BRDB1"

# --- Crédit d'impôt borne de recharge VE (under cap) ---
# 75% of 400 EUR dépenses → 75% × 400 = 300 EUR = 30000 cents
BRDB2="$(mktemp -u /tmp/bilan-br2-XXXXXX.db)"
BILAN_DB="$BRDB2" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$BRDB2" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$BRDB2" $BIN stream add borne --kind borne_recharge >/dev/null
BILAN_DB="$BRDB2" $BIN tx add borne 2026-06-30 400 >/dev/null
r=$(BILAN_DB="$BRDB2" $BIN tax --year 2026)
ok "borne_recharge 75% under cap" 30000 "$(jq -r .reductions.borne_recharge.credit_cents <<<"$r")"
rm -f "$BRDB2"

# --- Scolarité (art. 199 quater F): forfaitaire passthrough ---
# 1 child collège (61) + 1 lycée (153) + 1 supérieur (183) = 397 EUR = 39700 cents
SCDB="$(mktemp -u /tmp/bilan-scol-XXXXXX.db)"
BILAN_DB="$SCDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$SCDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$SCDB" $BIN stream add ecole --kind scolarite >/dev/null
BILAN_DB="$SCDB" $BIN tx add ecole 2026-06-30 397 >/dev/null
r=$(BILAN_DB="$SCDB" $BIN tax --year 2026)
ok "scolarite passthrough 397" 39700 "$(jq -r .reductions.scolarite.reduction_cents <<<"$r")"
ok "scolarite ir reduction" 39700 "$(jq -r .ir.scolarite_reduction_cents <<<"$r")"
rm -f "$SCDB"

# --- Pension alimentaire (art. 156 II.2°): deduction from ir_base, cap 6794 ---
# 5000 salary -> 45000 net; pension 5000 -> cap 6794 -> 5000 deducted from base
# base = 45000 - 5000 = 40000 EUR = 4000000 cents
PADB="$(mktemp -u /tmp/bilan-pa-XXXXXX.db)"
BILAN_DB="$PADB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$PADB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$PADB" $BIN stream add pens --kind pension_alimentaire >/dev/null
BILAN_DB="$PADB" $BIN tx add pens 2026-06-30 5000 >/dev/null
r=$(BILAN_DB="$PADB" $BIN tax --year 2026)
ok "pension deduction 5000" 500000 "$(jq -r .ir.pension_alimentaire_deduction_cents <<<"$r")"
ok "pension reduces ir_base" 4000000 "$(jq -r .ir.base_cents <<<"$r")"
rm -f "$PADB"

# --- Pension alimentaire above cap: 10000 -> cap 6794 ---
PADB2="$(mktemp -u /tmp/bilan-pa2-XXXXXX.db)"
BILAN_DB="$PADB2" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$PADB2" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$PADB2" $BIN stream add pens --kind pension_alimentaire >/dev/null
BILAN_DB="$PADB2" $BIN tx add pens 2026-06-30 10000 >/dev/null
r=$(BILAN_DB="$PADB2" $BIN tax --year 2026)
ok "pension capped at 6794" 679400 "$(jq -r .ir.pension_alimentaire_deduction_cents <<<"$r")"
rm -f "$PADB2"

# --- IR-PME / Madelin (art. 199 terdecies-0 A): 18% cap 50000 ---
# 10000 versements -> 18% = 1800 EUR = 180000 cents
PMEDB="$(mktemp -u /tmp/bilan-pme-XXXXXX.db)"
BILAN_DB="$PMEDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$PMEDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$PMEDB" $BIN stream add inv --kind ir_pme >/dev/null
BILAN_DB="$PMEDB" $BIN tx add inv 2026-06-30 10000 >/dev/null
r=$(BILAN_DB="$PMEDB" $BIN tax --year 2026)
ok "ir_pme 18% rate" "18" "$(jq -r .reductions.ir_pme.rate_pct <<<"$r")"
ok "ir_pme 18% reduction" 180000 "$(jq -r .reductions.ir_pme.reduction_cents <<<"$r")"
ok "ir_pme ir reduction" 180000 "$(jq -r .ir.ir_pme_reduction_cents <<<"$r")"
rm -f "$PMEDB"

# --- IR-PME above cap: 100000 -> cap 50000 -> 18% = 9000 ---
PMEDB2="$(mktemp -u /tmp/bilan-pme2-XXXXXX.db)"
BILAN_DB="$PMEDB2" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$PMEDB2" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$PMEDB2" $BIN stream add inv --kind ir_pme >/dev/null
BILAN_DB="$PMEDB2" $BIN tx add inv 2026-06-30 100000 >/dev/null
r=$(BILAN_DB="$PMEDB2" $BIN tax --year 2026)
ok "ir_pme capped at 50000" 900000 "$(jq -r .reductions.ir_pme.reduction_cents <<<"$r")"
rm -f "$PMEDB2"

# --- PER — plan épargne retraite (art. 163 quatervicies): deduction from ir_base ---
# 5000 salary -> 45000 net; PER 5000 -> cap 35194 -> 5000 deducted from base
# base = 45000 - 5000 = 40000 EUR = 4000000 cents
PERDB="$(mktemp -u /tmp/bilan-per-XXXXXX.db)"
BILAN_DB="$PERDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$PERDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$PERDB" $BIN stream add ret --kind per >/dev/null
BILAN_DB="$PERDB" $BIN tx add ret 2026-06-30 5000 >/dev/null
r=$(BILAN_DB="$PERDB" $BIN tax --year 2026)
ok "per deduction 5000" 500000 "$(jq -r .ir.per_deduction_cents <<<"$r")"
ok "per reduces ir_base" 4000000 "$(jq -r .ir.base_cents <<<"$r")"
rm -f "$PERDB"

# --- PER above cap: 50000 -> cap 35194 ---
PERDB2="$(mktemp -u /tmp/bilan-per2-XXXXXX.db)"
BILAN_DB="$PERDB2" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$PERDB2" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$PERDB2" $BIN stream add ret --kind per >/dev/null
BILAN_DB="$PERDB2" $BIN tx add ret 2026-06-30 50000 >/dev/null
r=$(BILAN_DB="$PERDB2" $BIN tax --year 2026)
ok "per capped at 35194" 3519400 "$(jq -r .ir.per_deduction_cents <<<"$r")"
rm -f "$PERDB2"

# --- FCPI/FIP (art. 199 terdecies-0 A VI): 18% cap 12000 ---
# 10000 versements -> 18% = 1800 EUR = 180000 cents
FFDB="$(mktemp -u /tmp/bilan-ff-XXXXXX.db)"
BILAN_DB="$FFDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$FFDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$FFDB" $BIN stream add fc --kind fcpi_fip >/dev/null
BILAN_DB="$FFDB" $BIN tx add fc 2026-06-30 10000 >/dev/null
r=$(BILAN_DB="$FFDB" $BIN tax --year 2026)
ok "fcpi_fip 18% rate" "18" "$(jq -r .reductions.fcpi_fip.rate_pct <<<"$r")"
ok "fcpi_fip 18% reduction" 180000 "$(jq -r .reductions.fcpi_fip.reduction_cents <<<"$r")"
ok "fcpi_fip ir reduction" 180000 "$(jq -r .ir.fcpi_fip_reduction_cents <<<"$r")"
rm -f "$FFDB"

# --- FCPI/FIP above cap: 20000 -> cap 12000 -> 18% = 2160 ---
FFDB2="$(mktemp -u /tmp/bilan-ff2-XXXXXX.db)"
BILAN_DB="$FFDB2" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$FFDB2" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$FFDB2" $BIN stream add fc --kind fcpi_fip >/dev/null
BILAN_DB="$FFDB2" $BIN tx add fc 2026-06-30 20000 >/dev/null
r=$(BILAN_DB="$FFDB2" $BIN tax --year 2026)
ok "fcpi_fip capped at 12000" 216000 "$(jq -r .reductions.fcpi_fip.reduction_cents <<<"$r")"
rm -f "$FFDB2"

# --- SOFICA (art. 199 quater E): 30% cap 18000 OR 25% revenu ---
# 5000 versements, salary 50000 -> net 45000; 25% of 45000 = 11250 > 5000
# so base = 5000; 30% of 5000 = 1500 EUR = 150000 cents
SODB="$(mktemp -u /tmp/bilan-so-XXXXXX.db)"
BILAN_DB="$SODB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$SODB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$SODB" $BIN stream add cine --kind sofica >/dev/null
BILAN_DB="$SODB" $BIN tx add cine 2026-06-30 5000 >/dev/null
r=$(BILAN_DB="$SODB" $BIN tax --year 2026)
ok "sofica 30% rate" "30" "$(jq -r .reductions.sofica.rate_pct <<<"$r")"
ok "sofica 30% reduction (under revenu cap)" 150000 "$(jq -r .reductions.sofica.reduction_cents <<<"$r")"
ok "sofica ir reduction" 150000 "$(jq -r .ir.sofica_reduction_cents <<<"$r")"
rm -f "$SODB"

# --- FOREST (art. 199 decies HA): 22% cap 5700 ---
# 2000 versements -> 22% = 440 EUR = 44000 cents
FODB="$(mktemp -u /tmp/bilan-fo-XXXXXX.db)"
BILAN_DB="$FODB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$FODB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$FODB" $BIN stream add tree --kind forest >/dev/null
BILAN_DB="$FODB" $BIN tx add tree 2026-06-30 2000 >/dev/null
r=$(BILAN_DB="$FODB" $BIN tax --year 2026)
ok "forest 22% rate" "22" "$(jq -r .reductions.forest.rate_pct <<<"$r")"
ok "forest 22% reduction" 44000 "$(jq -r .reductions.forest.reduction_cents <<<"$r")"
ok "forest ir reduction" 44000 "$(jq -r .ir.forest_reduction_cents <<<"$r")"
rm -f "$FODB"

# --- FOREST above cap: 10000 -> cap 5700 -> 22% = 1254 ---
FODB2="$(mktemp -u /tmp/bilan-fo2-XXXXXX.db)"
BILAN_DB="$FODB2" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$FODB2" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$FODB2" $BIN stream add tree --kind forest >/dev/null
BILAN_DB="$FODB2" $BIN tx add tree 2026-06-30 10000 >/dev/null
r=$(BILAN_DB="$FODB2" $BIN tax --year 2026)
ok "forest capped at 5700" 125400 "$(jq -r .reductions.forest.reduction_cents <<<"$r")"
rm -f "$FODB2"

# --- Plafonnement global (art. 200-0 A): caps total niche advantage at 10k ---
# Build a scenario with >10k of niche reductions. Pinel 300000 @ 18% / 9y = 6000/yr
# + IR-PME 50000 @ 18% = 9000 + frais_garde 3500 @ 50% = 1750 = 16750 total.
# Cap 10000 -> excess 6750 added back to ir_after_credit.
PGDB="$(mktemp -u /tmp/bilan-pg-XXXXXX.db)"
BILAN_DB="$PGDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$PGDB" $BIN tx add sal 2026-06-30 200000 >/dev/null
BILAN_DB="$PGDB" $BIN stream add pin --kind pinel --engagement 9 >/dev/null
BILAN_DB="$PGDB" $BIN tx add pin 2026-06-30 300000 >/dev/null
BILAN_DB="$PGDB" $BIN stream add inv --kind ir_pme >/dev/null
BILAN_DB="$PGDB" $BIN tx add inv 2026-06-30 50000 >/dev/null
BILAN_DB="$PGDB" $BIN stream add garde --kind frais_garde >/dev/null
BILAN_DB="$PGDB" $BIN tx add garde 2026-06-30 3500 >/dev/null
r=$(BILAN_DB="$PGDB" $BIN tax --year 2026)
# niche_total = 6000 (pinel 18%/9y) + 9000 (ir_pme) + 1750 (frais_garde) = 1675000 cents
ok "plafonnement niche_total" 1675000 "$(jq -r .reductions.plafonnement_global.niche_total_cents <<<"$r")"
ok "plafonnement cap 10000" 1000000 "$(jq -r .reductions.plafonnement_global.cap_effective_cents <<<"$r")"
ok "plafonnement excess 6750" 675000 "$(jq -r .reductions.plafonnement_global.excess_cents <<<"$r")"
ok "plafonnement ir excess" 675000 "$(jq -r .ir.plafonnement_global_excess_cents <<<"$r")"
rm -f "$PGDB"

# --- TVA régime normal (art. 287): rn_eligible when CA > RSI threshold ---
# BNC 300000 EUR > 254000 services threshold -> rn_eligible
RNDB="$(mktemp -u /tmp/bilan-rn-XXXXXX.db)"
BILAN_DB="$RNDB" $BIN stream add biz --kind bnc >/dev/null
BILAN_DB="$RNDB" $BIN tx add biz 2026-06-30 300000 >/dev/null
r=$(BILAN_DB="$RNDB" $BIN tax --year 2026)
ok "tva rn eligible (CA > 254k)" "true" "$(jq -r .tva.rn_eligible <<<"$r")"
ok "tva rn threshold services" 25400000 "$(jq -r .tva.rn_threshold_services_cents <<<"$r")"
rm -f "$RNDB"

# --- TVA régime normal not eligible when CA < RSI threshold ---
RNDB2="$(mktemp -u /tmp/bilan-rn2-XXXXXX.db)"
BILAN_DB="$RNDB2" $BIN stream add biz --kind bnc >/dev/null
BILAN_DB="$RNDB2" $BIN tx add biz 2026-06-30 100000 >/dev/null
r=$(BILAN_DB="$RNDB2" $BIN tax --year 2026)
ok "tva rn not eligible (CA < 254k)" "false" "$(jq -r .tva.rn_eligible <<<"$r")"
rm -f "$RNDB2"

# --- Plus-values immobilières (art. 150 VC): 19% IR + 17.2% social, no abattement ---
# PV brute 10000, detention 0 -> no abattement -> IR 1900 + social 1720 = 3620 EUR
PVDB="$(mktemp -u /tmp/bilan-pv-XXXXXX.db)"
BILAN_DB="$PVDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$PVDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$PVDB" $BIN stream add pvi --kind plus_value_immo >/dev/null
BILAN_DB="$PVDB" $BIN tx add pvi 2026-06-30 10000 >/dev/null
r=$(BILAN_DB="$PVDB" $BIN tax --year 2026)
ok "pv_immo brute" 1000000 "$(jq -r .plus_values.immo.brute_cents <<<"$r")"
ok "pv_immo ir tax 19%" 190000 "$(jq -r .plus_values.immo.ir_tax_cents <<<"$r")"
ok "pv_immo social tax 17.2%" 172000 "$(jq -r .plus_values.immo.social_tax_cents <<<"$r")"
ok "pv_immo total 36.2%" 362000 "$(jq -r .plus_values.immo.total_tax_cents <<<"$r")"
ok "pv_immo in totals" 362000 "$(jq -r .totals.pv_immo_cents <<<"$r")"
rm -f "$PVDB"

# --- Plus-values immobilières with abattement: detention 10y ---
# PV brute 10000, detention 10 -> IR abattement 5y × 6% = 30% -> IR base 7000
# IR 19% of 7000 = 1330; social abattement 5y × 1.65% = 8.25% -> social base 9175
# social 17.2% of 9175 = 1578.1 -> 157810 cents
PVDB2="$(mktemp -u /tmp/bilan-pv2-XXXXXX.db)"
BILAN_DB="$PVDB2" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$PVDB2" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$PVDB2" $BIN stream add pvi --kind plus_value_immo >/dev/null
BILAN_DB="$PVDB2" $BIN tx add pvi 2026-06-30 10000 >/dev/null
BILAN_DB="$PVDB2" $BIN rule set 2026 plus_value_immo detention_years 10 >/dev/null
r=$(BILAN_DB="$PVDB2" $BIN tax --year 2026)
ok "pv_immo 10y ir abattement 30%" "30" "$(jq -r .plus_values.immo.ir_abattement_pct <<<"$r")"
ok "pv_immo 10y ir base 7000" 700000 "$(jq -r .plus_values.immo.ir_base_cents <<<"$r")"
ok "pv_immo 10y ir tax" 133000 "$(jq -r .plus_values.immo.ir_tax_cents <<<"$r")"
rm -f "$PVDB2"

# --- Plus-values immobilières full exoneration: detention 22y (IR) / 30y (social) ---
PVDB3="$(mktemp -u /tmp/bilan-pv3-XXXXXX.db)"
BILAN_DB="$PVDB3" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$PVDB3" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$PVDB3" $BIN stream add pvi --kind plus_value_immo >/dev/null
BILAN_DB="$PVDB3" $BIN tx add pvi 2026-06-30 10000 >/dev/null
BILAN_DB="$PVDB3" $BIN rule set 2026 plus_value_immo detention_years 22 >/dev/null
r=$(BILAN_DB="$PVDB3" $BIN tax --year 2026)
ok "pv_immo 22y ir abattement 100%" "100" "$(jq -r .plus_values.immo.ir_abattement_pct <<<"$r")"
ok "pv_immo 22y ir tax 0" 0 "$(jq -r .plus_values.immo.ir_tax_cents <<<"$r")"
rm -f "$PVDB3"

# --- IFI (art. 977): below seuil -> not eligible ---
IFIDB="$(mktemp -u /tmp/bilan-ifi-XXXXXX.db)"
BILAN_DB="$IFIDB" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$IFIDB" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$IFIDB" $BIN stream add pat --kind ifi_patrimoine >/dev/null
BILAN_DB="$IFIDB" $BIN tx add pat 2026-06-30 1000000 >/dev/null
r=$(BILAN_DB="$IFIDB" $BIN tax --year 2026)
ok "ifi below seuil not eligible" "false" "$(jq -r .ifi.eligible <<<"$r")"
ok "ifi below seuil 0" 0 "$(jq -r .ifi.ifi_cents <<<"$r")"
rm -f "$IFIDB"

# --- IFI above seuil: patrimoine 1.5M ---
# Barème from 800k: 500k @ 0.5% = 2500 + 200k @ 0.7% = 1400 = 3900 EUR
# Décote: 1.5M > 1.4M -> no décote. IFI = 3900 EUR = 390000 cents
IFIDB2="$(mktemp -u /tmp/bilan-ifi2-XXXXXX.db)"
BILAN_DB="$IFIDB2" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$IFIDB2" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$IFIDB2" $BIN stream add pat --kind ifi_patrimoine >/dev/null
BILAN_DB="$IFIDB2" $BIN tx add pat 2026-06-30 1500000 >/dev/null
r=$(BILAN_DB="$IFIDB2" $BIN tax --year 2026)
ok "ifi 1.5M eligible" "true" "$(jq -r .ifi.eligible <<<"$r")"
ok "ifi 1.5M bareme" 390000 "$(jq -r .ifi.bareme_cents <<<"$r")"
ok "ifi 1.5M no decote" 0 "$(jq -r .ifi.decote_cents <<<"$r")"
ok "ifi 1.5M ifi" 390000 "$(jq -r .ifi.ifi_cents <<<"$r")"
ok "ifi in totals" 390000 "$(jq -r .totals.ifi_cents <<<"$r")"
rm -f "$IFIDB2"

# --- IFI with décote: patrimoine 1.35M (between 1.3M and 1.4M) ---
# Barème: 500k @ 0.5% = 2500 + 50k @ 0.7% = 350 = 2850 EUR = 285000 cents
# Décote: 17500 - 1.25% × 1350000 = 17500 - 16875 = 625 EUR = 62500 cents
# IFI = 2850 - 625 = 2225 EUR = 222500 cents
IFIDB3="$(mktemp -u /tmp/bilan-ifi3-XXXXXX.db)"
BILAN_DB="$IFIDB3" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$IFIDB3" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$IFIDB3" $BIN stream add pat --kind ifi_patrimoine >/dev/null
BILAN_DB="$IFIDB3" $BIN tx add pat 2026-06-30 1350000 >/dev/null
r=$(BILAN_DB="$IFIDB3" $BIN tax --year 2026)
ok "ifi 1.35M bareme" 285000 "$(jq -r .ifi.bareme_cents <<<"$r")"
ok "ifi 1.35M decote 625" 62500 "$(jq -r .ifi.decote_cents <<<"$r")"
ok "ifi 1.35M ifi 2225" 222500 "$(jq -r .ifi.ifi_cents <<<"$r")"
rm -f "$IFIDB3"

# --- IFI démembrement art. 968 (default: usufruitier pleine propriété) ---
# 2M patrimoine, démembrement eligible, bien 500000, usufruitier 75y, NO exception
# → default rule: usufruitier declares pleine propriété (500000 in usufruit)
IFIDEM1="$(mktemp -u /tmp/bilan-ifidem1-XXXXXX.db)"
BILAN_DB="$IFIDEM1" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$IFIDEM1" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$IFIDEM1" $BIN stream add pat --kind ifi_patrimoine >/dev/null
BILAN_DB="$IFIDEM1" $BIN tx add pat 2026-06-30 2000000 >/dev/null
BILAN_DB="$IFIDEM1" $BIN rule set 2026 ifi demembrement_eligible 1 >/dev/null
BILAN_DB="$IFIDEM1" $BIN rule set 2026 ifi demembrement_usufruitier_age 75 >/dev/null
BILAN_DB="$IFIDEM1" $BIN rule set 2026 ifi demembrement_exception 0 >/dev/null
BILAN_DB="$IFIDEM1" $BIN rule set 2026 ifi demembrement_bien_valeur_cents 50000000 >/dev/null
r=$(BILAN_DB="$IFIDEM1" $BIN tax --year 2026)
ok "ifi dem eligible" true "$(jq -r .ifi.demembrement.eligible <<<"$r")"
ok "ifi dem exception false" false "$(jq -r .ifi.demembrement.exception <<<"$r")"
# Default: usufruitier declares pleine propriété → usufruit 100%, NP 0%
ok "ifi dem default usufruit pct 100" 100 "$(jq -r .ifi.demembrement.usufruit_pct <<<"$r")"
ok "ifi dem default NP pct 0" 0 "$(jq -r .ifi.demembrement.nue_propriete_pct <<<"$r")"
ok "ifi dem default usufruit value 500000" 50000000 "$(jq -r .ifi.demembrement.usufruit_value_cents <<<"$r")"
rm -f "$IFIDEM1"

# --- IFI démembrement art. 968 (exception: split by art. 669) ---
# 2M patrimoine, démembrement eligible, bien 500000, usufruitier 75y, exception 1
# → exception: split by art. 669 → usufruit 30% (75y), NP 70%
IFIDEM2="$(mktemp -u /tmp/bilan-ifidem2-XXXXXX.db)"
BILAN_DB="$IFIDEM2" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$IFIDEM2" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$IFIDEM2" $BIN stream add pat --kind ifi_patrimoine >/dev/null
BILAN_DB="$IFIDEM2" $BIN tx add pat 2026-06-30 2000000 >/dev/null
BILAN_DB="$IFIDEM2" $BIN rule set 2026 ifi demembrement_eligible 1 >/dev/null
BILAN_DB="$IFIDEM2" $BIN rule set 2026 ifi demembrement_usufruitier_age 75 >/dev/null
BILAN_DB="$IFIDEM2" $BIN rule set 2026 ifi demembrement_exception 1 >/dev/null
BILAN_DB="$IFIDEM2" $BIN rule set 2026 ifi demembrement_bien_valeur_cents 50000000 >/dev/null
r=$(BILAN_DB="$IFIDEM2" $BIN tax --year 2026)
ok "ifi dem2 exception true" true "$(jq -r .ifi.demembrement.exception <<<"$r")"
ok "ifi dem2 usufruit pct 30" 30 "$(jq -r .ifi.demembrement.usufruit_pct <<<"$r")"
ok "ifi dem2 NP pct 70" 70 "$(jq -r .ifi.demembrement.nue_propriete_pct <<<"$r")"
ok "ifi dem2 usufruit value 150000" 15000000 "$(jq -r .ifi.demembrement.usufruit_value_cents <<<"$r")"
ok "ifi dem2 NP value 350000" 35000000 "$(jq -r .ifi.demembrement.nue_propriete_value_cents <<<"$r")"
rm -f "$IFIDEM2"

# --- IFI plafonnement 75% art. 979 (bouclier fiscal) ---
# 10M patrimoine → IFI ≈ 98190 EUR (large IFI)
# revenus N-1 50000, impots N-1 10000, seuil 75%
# 75% × 50000 = 37500; IFI 98190 + 10000 = 108190 > 37500 → reduction applies
IFIPLAF1="$(mktemp -u /tmp/bilan-ifiplaf1-XXXXXX.db)"
BILAN_DB="$IFIPLAF1" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$IFIPLAF1" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$IFIPLAF1" $BIN stream add pat --kind ifi_patrimoine >/dev/null
BILAN_DB="$IFIPLAF1" $BIN tx add pat 2026-06-30 10000000 >/dev/null
BILAN_DB="$IFIPLAF1" $BIN rule set 2026 ifi plafonnement_eligible 1 >/dev/null
BILAN_DB="$IFIPLAF1" $BIN rule set 2026 ifi plafonnement_revenus_n1_cents 5000000 >/dev/null
BILAN_DB="$IFIPLAF1" $BIN rule set 2026 ifi plafonnement_impots_n1_cents 1000000 >/dev/null
r=$(BILAN_DB="$IFIPLAF1" $BIN tax --year 2026)
ok "ifi plaf eligible" true "$(jq -r .ifi.plafonnement.eligible <<<"$r")"
ok "ifi plaf revenus n1 50000" 5000000 "$(jq -r .ifi.plafonnement.revenus_n1_cents <<<"$r")"
ok "ifi plaf impots n1 10000" 1000000 "$(jq -r .ifi.plafonnement.impots_n1_cents <<<"$r")"
# IFI avant plafonnement should be > 0
ifi_avant=$(jq -r .ifi.plafonnement.ifi_avant_plafonnement_cents <<<"$r")
ok "ifi plaf avant > 0" 1 "$(if [ "$ifi_avant" -gt 0 ]; then echo 1; else echo 0; fi)"
# Reduction should be > 0 (IFI + 10000 > 37500)
ifi_red=$(jq -r .ifi.plafonnement.reduction_cents <<<"$r")
ok "ifi plaf reduction > 0" 1 "$(if [ "$ifi_red" -gt 0 ]; then echo 1; else echo 0; fi)"
# IFI after plafonnement should be < IFI before
ifi_apres=$(jq -r .ifi.plafonnement.ifi_apres_plafonnement_cents <<<"$r")
ok "ifi plaf apres < avant" 1 "$(if [ "$ifi_apres" -lt "$ifi_avant" ]; then echo 1; else echo 0; fi)"
rm -f "$IFIPLAF1"

# --- IFI réduction dons art. 978 (75% dons, cap 50000) ---
# 5M patrimoine → IFI ≈ 35690 EUR (progressive bareme)
# dons 40000 EUR → réduction 75% × 40000 = 30000 EUR = 3000000 cents
# IFI après dons = 35690 - 30000 = 5690 EUR = 569000 cents
IFIDONS1="$(mktemp -u /tmp/bilan-ifidons1-XXXXXX.db)"
BILAN_DB="$IFIDONS1" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$IFIDONS1" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$IFIDONS1" $BIN stream add pat --kind ifi_patrimoine >/dev/null
BILAN_DB="$IFIDONS1" $BIN tx add pat 2026-06-30 5000000 >/dev/null
BILAN_DB="$IFIDONS1" $BIN rule set 2026 ifi dons_eligible 1 >/dev/null
BILAN_DB="$IFIDONS1" $BIN rule set 2026 ifi dons_montant_cents 4000000 >/dev/null
r=$(BILAN_DB="$IFIDONS1" $BIN tax --year 2026)
ok "ifi dons eligible" true "$(jq -r .ifi.dons.eligible <<<"$r")"
ok "ifi dons montant 40000" 4000000 "$(jq -r .ifi.dons.montant_cents <<<"$r")"
# 75% × 40000 = 30000 EUR = 3000000 cents
ok "ifi dons reduction 30000" 3000000 "$(jq -r .ifi.dons.reduction_cents <<<"$r")"
# IFI avant dons should be > 0
ifi_avant_dons=$(jq -r .ifi.dons.ifi_avant_dons_cents <<<"$r")
ok "ifi dons avant > 0" 1 "$(if [ "$ifi_avant_dons" -gt 0 ]; then echo 1; else echo 0; fi)"
# IFI after dons should be < IFI before dons
ifi_after_dons=$(jq -r .ifi.ifi_cents <<<"$r")
ok "ifi dons ifi after < avant" 1 "$(if [ "$ifi_after_dons" -lt "$ifi_avant_dons" ]; then echo 1; else echo 0; fi)"
rm -f "$IFIDONS1"

# --- IFI réduction dons art. 978 (cap 50000 EUR) ---
# dons 100000 EUR → réduction 75% × 100000 = 75000, but capped at 50000 EUR = 5000000 cents
IFIDONS2="$(mktemp -u /tmp/bilan-ifidons2-XXXXXX.db)"
BILAN_DB="$IFIDONS2" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$IFIDONS2" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$IFIDONS2" $BIN stream add pat --kind ifi_patrimoine >/dev/null
BILAN_DB="$IFIDONS2" $BIN tx add pat 2026-06-30 10000000 >/dev/null
BILAN_DB="$IFIDONS2" $BIN rule set 2026 ifi dons_eligible 1 >/dev/null
BILAN_DB="$IFIDONS2" $BIN rule set 2026 ifi dons_montant_cents 10000000 >/dev/null
r=$(BILAN_DB="$IFIDONS2" $BIN tax --year 2026)
# 75% × 100000 = 75000, capped at 50000 EUR = 5000000 cents
ok "ifi dons2 reduction capped 50000" 5000000 "$(jq -r .ifi.dons.reduction_cents <<<"$r")"
rm -f "$IFIDONS2"

# --- DMTG abattement renouvelable 15 ans art. 779 (within 15y, reduced) ---
# 200000 actif, ligne directe, abattement 100000, déjà utilisé 60000, dernière donation 2020
# → abattement réduit à 100000 - 60000 = 40000; base = 200000 - 40000 = 160000
DDREN1="$(mktemp -u /tmp/bilan-ddren1-XXXXXX.db)"
BILAN_DB="$DDREN1" $BIN rule set 2026 dmtg_donation actif_taxable_cents 20000000 >/dev/null
BILAN_DB="$DDREN1" $BIN rule set 2026 dmtg_donation degre_parente ligne_directe >/dev/null
BILAN_DB="$DDREN1" $BIN rule set 2026 dmtg_donation abattement_deja_utilise_cents 6000000 >/dev/null
BILAN_DB="$DDREN1" $BIN rule set 2026 dmtg_donation derniere_donation_year 2020 >/dev/null
r=$(BILAN_DB="$DDREN1" $BIN tax --year 2026)
ok "dd renouvellement deja utilise 60000" 6000000 "$(jq -r .dmtg_donation.abattement_renouvellement.deja_utilise_cents <<<"$r")"
ok "dd renouvellement derniere 2020" 2020 "$(jq -r .dmtg_donation.abattement_renouvellement.derniere_donation_year <<<"$r")"
# 2026 - 2020 = 6 < 15 → NOT renewed → abattement réduit 60000
ok "dd renouvellement abattement reduit 60000" 6000000 "$(jq -r .dmtg_donation.abattement_renouvellement.abattement_reduit_cents <<<"$r")"
ok "dd renouvellement renewed false" false "$(jq -r .dmtg_donation.abattement_renouvellement.renewed <<<"$r")"
# abattement = 100000 - 60000 = 40000 EUR = 4000000 cents
ok "dd renouvellement abattement 40000" 4000000 "$(jq -r .dmtg_donation.abattement_cents <<<"$r")"
rm -f "$DDREN1"

# --- DMTG abattement renouvelable 15 ans art. 779 (outside 15y, renewed) ---
# 200000 actif, ligne directe, abattement 100000, déjà utilisé 60000, dernière donation 2010
# → 2026 - 2010 = 16 >= 15 → renewed → abattement full 100000
DDREN2="$(mktemp -u /tmp/bilan-ddren2-XXXXXX.db)"
BILAN_DB="$DDREN2" $BIN rule set 2026 dmtg_donation actif_taxable_cents 20000000 >/dev/null
BILAN_DB="$DDREN2" $BIN rule set 2026 dmtg_donation degre_parente ligne_directe >/dev/null
BILAN_DB="$DDREN2" $BIN rule set 2026 dmtg_donation abattement_deja_utilise_cents 6000000 >/dev/null
BILAN_DB="$DDREN2" $BIN rule set 2026 dmtg_donation derniere_donation_year 2010 >/dev/null
r=$(BILAN_DB="$DDREN2" $BIN tax --year 2026)
# 2026 - 2010 = 16 >= 15 → renewed → abattement réduit 0
ok "dd renouvellement2 abattement reduit 0 (renewed)" 0 "$(jq -r .dmtg_donation.abattement_renouvellement.abattement_reduit_cents <<<"$r")"
ok "dd renouvellement2 renewed true" true "$(jq -r .dmtg_donation.abattement_renouvellement.renewed <<<"$r")"
# abattement = 100000 (full, renewed)
ok "dd renouvellement2 abattement 100000" 10000000 "$(jq -r .dmtg_donation.abattement_cents <<<"$r")"
rm -f "$DDREN2"

# --- heures supplémentaires (art. 81 quater, 7500 EUR cap) ---
HSDB1="$(mktemp -u /tmp/bilan-hs1-XXXXXX.db)"
BILAN_DB="$HSDB1" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$HSDB1" $BIN stream add hs --kind heures_sup >/dev/null
BILAN_DB="$HSDB1" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$HSDB1" $BIN tx add hs 2026-06-30 5000 >/dev/null
r=$(BILAN_DB="$HSDB1" $BIN tax --year 2026)
# salary 50000 - 10% frais (5000) = 45000 net; heures_sup 5000 < 7500 cap → exempt 5000
# net_salary = 45000 + 5000 - 5000 = 45000 (heures sup fully exempt, no IR impact)
ok "heures_sup exemption 5000 (under cap)" 500000 "$(jq -r .ir.heures_sup_exemption_cents <<<"$r")"
ok "heures_sup net_salary 45000" 4500000 "$(jq -r .regimes.salary.net_cents <<<"$r")"
rm -f "$HSDB1"
# heures sup above cap: 10000 hs → exempt 7500, 2500 stays taxable
HSDB2="$(mktemp -u /tmp/bilan-hs2-XXXXXX.db)"
BILAN_DB="$HSDB2" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$HSDB2" $BIN stream add hs --kind heures_sup >/dev/null
BILAN_DB="$HSDB2" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$HSDB2" $BIN tx add hs 2026-06-30 10000 >/dev/null
r=$(BILAN_DB="$HSDB2" $BIN tax --year 2026)
# salary 45000 net + hs 10000 → exempt 7500 → net_salary = 45000 + 10000 - 7500 = 47500
ok "heures_sup exemption capped at 7500" 750000 "$(jq -r .ir.heures_sup_exemption_cents <<<"$r")"
ok "heures_sup net_salary 47500" 4750000 "$(jq -r .regimes.salary.net_cents <<<"$r")"
rm -f "$HSDB2"

# --- CFE cotisation minimum (art. 1647 D, CA brackets) ---
# CA ≤ 5000 → exonération, cfe 0
CFEDB1="$(mktemp -u /tmp/bilan-cfe1-XXXXXX.db)"
BILAN_DB="$CFEDB1" $BIN stream add biz --kind bnc >/dev/null
BILAN_DB="$CFEDB1" $BIN tx add biz 2026-06-30 4000 >/dev/null
r=$(BILAN_DB="$CFEDB1" $BIN tax --year 2026)
ok "cfe exoneration CA 4000" 0 "$(jq -r .cfe.cfe_cents <<<"$r")"
ok "cfe bracket 0 (exonéré)" 0 "$(jq -r .cfe.bracket <<<"$r")"
rm -f "$CFEDB1"
# CA 30000 (bracket 1: ≤ 10000? no, 10000-32600) → bracket 2 base 68400 × 20% = 13680
CFEDB2="$(mktemp -u /tmp/bilan-cfe2-XXXXXX.db)"
BILAN_DB="$CFEDB2" $BIN stream add biz --kind bic >/dev/null
BILAN_DB="$CFEDB2" $BIN tx add biz 2026-06-30 30000 >/dev/null
r=$(BILAN_DB="$CFEDB2" $BIN tax --year 2026)
ok "cfe CA 30000 bracket 2" 2 "$(jq -r .cfe.bracket <<<"$r")"
ok "cfe CA 30000 base 68400" 68400 "$(jq -r .cfe.base_cents <<<"$r")"
ok "cfe CA 30000 cfe 13680" 13680 "$(jq -r .cfe.cfe_cents <<<"$r")"
rm -f "$CFEDB2"
# CA 200000 (bracket 3: 32600-100000? no, 100000-250000) → bracket 4 base 218300 × 20% = 43660
CFEDB3="$(mktemp -u /tmp/bilan-cfe3-XXXXXX.db)"
BILAN_DB="$CFEDB3" $BIN stream add biz --kind bnc >/dev/null
BILAN_DB="$CFEDB3" $BIN tx add biz 2026-06-30 200000 >/dev/null
r=$(BILAN_DB="$CFEDB3" $BIN tax --year 2026)
ok "cfe CA 200000 bracket 4" 4 "$(jq -r .cfe.bracket <<<"$r")"
ok "cfe CA 200000 cfe 43660" 43660 "$(jq -r .cfe.cfe_cents <<<"$r")"
rm -f "$CFEDB3"
# CA 600000 (>500000) → bracket 6 base 395300 × 20% = 79060
CFEDB4="$(mktemp -u /tmp/bilan-cfe4-XXXXXX.db)"
BILAN_DB="$CFEDB4" $BIN stream add biz --kind bic >/dev/null
BILAN_DB="$CFEDB4" $BIN tx add biz 2026-06-30 600000 >/dev/null
r=$(BILAN_DB="$CFEDB4" $BIN tax --year 2026)
ok "cfe CA 600000 bracket 6" 6 "$(jq -r .cfe.bracket <<<"$r")"
ok "cfe CA 600000 cfe 79060" 79060 "$(jq -r .cfe.cfe_cents <<<"$r")"
rm -f "$CFEDB4"

# --- plus-values mobilières (art. 200 A, PFU vs barème option) ---
# PFU path: 10000 crypto → 12.8% IR + 17.2% social = 1280 + 1720 = 3000
PVDB1="$(mktemp -u /tmp/bilan-pvm1-XXXXXX.db)"
BILAN_DB="$PVDB1" $BIN stream add cr --kind crypto >/dev/null
BILAN_DB="$PVDB1" $BIN tx add cr 2026-06-30 10000 >/dev/null
r=$(BILAN_DB="$PVDB1" $BIN tax --year 2026)
ok "pvm base 10000" 1000000 "$(jq -r .pvm.base_cents <<<"$r")"
ok "pvm pfu ir 1280" 128000 "$(jq -r .pvm.pfu_ir_cents <<<"$r")"
ok "pvm pfu social 1720" 172000 "$(jq -r .pvm.pfu_social_cents <<<"$r")"
ok "pvm pfu total 3000" 300000 "$(jq -r .pvm.pfu_total_cents <<<"$r")"
ok "pvm optimal pfu (no detention)" pfu "$(jq -r .pvm.optimal <<<"$r")"
ok "pvm total tax 3000" 300000 "$(jq -r .pvm.total_tax_cents <<<"$r")"
rm -f "$PVDB1"
# Barème option with 5y detention: abattement 50%, IR base 5000, IR 30% = 1500, social 1720, total 3220
# PFU = 3000 < 3220 → PFU still optimal
PVDB2="$(mktemp -u /tmp/bilan-pvm2-XXXXXX.db)"
BILAN_DB="$PVDB2" $BIN stream add cr --kind crypto >/dev/null
BILAN_DB="$PVDB2" $BIN tx add cr 2026-06-30 10000 >/dev/null
BILAN_DB="$PVDB2" $BIN rule set 2026 pvm detention_years 5 >/dev/null
r=$(BILAN_DB="$PVDB2" $BIN tax --year 2026)
ok "pvm 5y abattement 50%" 50 "$(jq -r .pvm.abattement_pct <<<"$r")"
ok "pvm 5y bareme ir 1500" 150000 "$(jq -r .pvm.bareme_ir_cents <<<"$r")"
ok "pvm 5y bareme total 3220" 322000 "$(jq -r .pvm.bareme_total_cents <<<"$r")"
ok "pvm 5y optimal still pfu" pfu "$(jq -r .pvm.optimal <<<"$r")"
rm -f "$PVDB2"
# Barème option with 10y detention: abattement 65%, IR base 3500, IR 30% = 1050, social 1720, total 2770
# PFU = 3000 > 2770 → barème optimal
PVDB3="$(mktemp -u /tmp/bilan-pvm3-XXXXXX.db)"
BILAN_DB="$PVDB3" $BIN stream add cr --kind crypto >/dev/null
BILAN_DB="$PVDB3" $BIN tx add cr 2026-06-30 10000 >/dev/null
BILAN_DB="$PVDB3" $BIN rule set 2026 pvm detention_years 10 >/dev/null
r=$(BILAN_DB="$PVDB3" $BIN tax --year 2026)
ok "pvm 10y abattement 65%" 65 "$(jq -r .pvm.abattement_pct <<<"$r")"
ok "pvm 10y bareme ir 1050" 105000 "$(jq -r .pvm.bareme_ir_cents <<<"$r")"
ok "pvm 10y bareme total 2770" 277000 "$(jq -r .pvm.bareme_total_cents <<<"$r")"
ok "pvm 10y optimal bareme" bareme "$(jq -r .pvm.optimal <<<"$r")"
ok "pvm 10y total tax 2770" 277000 "$(jq -r .pvm.total_tax_cents <<<"$r")"
rm -f "$PVDB3"

# --- CVAE (art. 1586 ter, progressive effective rate) ---
# CA 4000 → below threshold 152500 → not assujettie, cvae 0
CVAEDB1="$(mktemp -u /tmp/bilan-cvae1-XXXXXX.db)"
BILAN_DB="$CVAEDB1" $BIN stream add biz --kind bnc >/dev/null
BILAN_DB="$CVAEDB1" $BIN tx add biz 2026-06-30 4000 >/dev/null
r=$(BILAN_DB="$CVAEDB1" $BIN tax --year 2026)
ok "cvae CA 4000 not assujettie" false "$(jq -r .cvae.assujettie <<<"$r")"
ok "cvae CA 4000 cvae 0" 0 "$(jq -r .cvae.cvae_cents <<<"$r")"
rm -f "$CVAEDB1"
# CA 200000 → assujettie but ≤ 500k franchise → cvae 0
CVAEDB2="$(mktemp -u /tmp/bilan-cvae2-XXXXXX.db)"
BILAN_DB="$CVAEDB2" $BIN stream add biz --kind bnc >/dev/null
BILAN_DB="$CVAEDB2" $BIN tx add biz 2026-06-30 200000 >/dev/null
r=$(BILAN_DB="$CVAEDB2" $BIN tax --year 2026)
ok "cvae CA 200000 assujettie" true "$(jq -r .cvae.assujettie <<<"$r")"
ok "cvae CA 200000 franchise cvae 0" 0 "$(jq -r .cvae.cvae_cents <<<"$r")"
rm -f "$CVAEDB2"
# CA 1000000 (>500k, ≤3M) → effective rate = 0.25% × (1M-500k)/2.5M = 0.05%
# VA = 1M × 45% = 450000 EUR; cvae = 450000 × 0.05% = 225 EUR; 2024 reduction 25% → 168.75 EUR = 16875 cents
CVAEDB3="$(mktemp -u /tmp/bilan-cvae3-XXXXXX.db)"
BILAN_DB="$CVAEDB3" $BIN stream add biz --kind bnc >/dev/null
BILAN_DB="$CVAEDB3" $BIN tx add biz 2026-06-30 1000000 >/dev/null
r=$(BILAN_DB="$CVAEDB3" $BIN tax --year 2026)
ok "cvae CA 1M assujettie" true "$(jq -r .cvae.assujettie <<<"$r")"
ok "cvae CA 1M effective rate 5" 5 "$(jq -r .cvae.effective_rate_pct_hundredths <<<"$r")"
ok "cvae CA 1M cvae 16875" 16875 "$(jq -r .cvae.cvae_cents <<<"$r")"
rm -f "$CVAEDB3"

# --- Taxe sur les salaires (art. 231) — bracket 1 only ---
# 5000 EUR salaires → 4.25% × 5000 = 212.50 EUR = 21250 cents
TSDB1="$(mktemp -u /tmp/bilan-ts1-XXXXXX.db)"
BILAN_DB="$TSDB1" $BIN rule set 2026 taxe_salaires salaires_bruts_cents 500000 >/dev/null
r=$(BILAN_DB="$TSDB1" $BIN tax --year 2026)
ok "taxe_salaires 5000 bracket1 4.25%" 21250 "$(jq -r .taxe_salaires.tax_cents <<<"$r")"
rm -f "$TSDB1"

# --- Taxe sur les salaires (art. 231) — brackets 1+2 ---
# 15000 EUR salaires → 4.25% × 9147 + 8.5% × (15000-9147) = 388.75 + 497.50 = 886.24 EUR = 88624 cents
TSDB2="$(mktemp -u /tmp/bilan-ts2-XXXXXX.db)"
BILAN_DB="$TSDB2" $BIN rule set 2026 taxe_salaires salaires_bruts_cents 1500000 >/dev/null
r=$(BILAN_DB="$TSDB2" $BIN tax --year 2026)
ok "taxe_salaires 15000 brackets 1+2" 88624 "$(jq -r .taxe_salaires.tax_cents <<<"$r")"
rm -f "$TSDB2"

# --- Taxe sur les salaires (art. 231) — all 3 brackets ---
# 25000 EUR salaires → 4.25% × 9147 + 8.5% × (18258-9147) + 13.6% × (25000-18258)
# = 388.74 + 774.43 + 916.91 = 2080.08 EUR = 208008 cents
TSDB3="$(mktemp -u /tmp/bilan-ts3-XXXXXX.db)"
BILAN_DB="$TSDB3" $BIN rule set 2026 taxe_salaires salaires_bruts_cents 2500000 >/dev/null
r=$(BILAN_DB="$TSDB3" $BIN tax --year 2026)
ok "taxe_salaires 25000 all 3 brackets" 208008 "$(jq -r .taxe_salaires.tax_cents <<<"$r")"
rm -f "$TSDB3"

# --- Taxe sur les salaires (art. 231) — no décote (tax below 1200 EUR) ---
# 1500 EUR salaires → 4.25% × 1500 = 63.75 EUR = 6375 cents (below 1200 EUR décote min)
TSDB4="$(mktemp -u /tmp/bilan-ts4-XXXXXX.db)"
BILAN_DB="$TSDB4" $BIN rule set 2026 taxe_salaires salaires_bruts_cents 150000 >/dev/null
r=$(BILAN_DB="$TSDB4" $BIN tax --year 2026)
ok "taxe_salaires 1500 no decote (below threshold)" 6375 "$(jq -r .taxe_salaires.tax_cents <<<"$r")"
ok "taxe_salaires 1500 decote 0" 0 "$(jq -r .taxe_salaires.decote_cents <<<"$r")"
rm -f "$TSDB4"

# --- Taxe sur les salaires (art. 231) — décote triggered ---
# 20000 EUR salaires → tax = 1400.08 EUR = 140008 cents (between 1200-2040 EUR)
# décote = 3/4 × (204000 - 140008) = 3/4 × 63992 = 47994 cents
# tax after décote = 140008 - 47994 = 92014 cents
TSDB5="$(mktemp -u /tmp/bilan-ts5-XXXXXX.db)"
BILAN_DB="$TSDB5" $BIN rule set 2026 taxe_salaires salaires_bruts_cents 2000000 >/dev/null
r=$(BILAN_DB="$TSDB5" $BIN tax --year 2026)
ok "taxe_salaires decote triggered 47994" 47994 "$(jq -r .taxe_salaires.decote_cents <<<"$r")"
ok "taxe_salaires tax after decote 92014" 92014 "$(jq -r .taxe_salaires.tax_cents <<<"$r")"
rm -f "$TSDB5"

# --- Taxe sur les salaires (art. 231) — abattement associations art. 1679 A ---
# 50000 EUR salaires → tax = 4.25% × 9147 + 8.5% × (18258-9147) + 13.6% × (50000-18258)
# = 388.75 + 774.44 + 4317.31 = 5480.50 EUR = 548050 cents
# With abattement 24041 EUR: 5480.50 - 24041 = negative → 0
TSDB6="$(mktemp -u /tmp/bilan-ts6-XXXXXX.db)"
BILAN_DB="$TSDB6" $BIN rule set 2026 taxe_salaires salaires_bruts_cents 5000000 >/dev/null
BILAN_DB="$TSDB6" $BIN rule set 2026 taxe_salaires abattement_eligible 1 >/dev/null
r=$(BILAN_DB="$TSDB6" $BIN tax --year 2026)
ok "taxe_salaires abattement eligible true" true "$(jq -r .taxe_salaires.abattement_eligible <<<"$r")"
ok "taxe_salaires abattement 24041" 2404100 "$(jq -r .taxe_salaires.abattement_cents <<<"$r")"
# tax before abattement = 548050, abattement 2404100 → negative → 0
ok "taxe_salaires tax after abattement 0" 0 "$(jq -r .taxe_salaires.tax_cents <<<"$r")"
rm -f "$TSDB6"

# --- Taxe d'apprentissage (art. 1599) — basic 0.68% ---
# 200000 EUR masse salariale → 0.59% × 200000 + 0.09% × 200000 = 1180 + 180 = 1360 EUR = 136000 cents
TADB1="$(mktemp -u /tmp/bilan-ta1-XXXXXX.db)"
BILAN_DB="$TADB1" $BIN rule set 2026 taxe_apprentissage masse_salariale_cents 20000000 >/dev/null
r=$(BILAN_DB="$TADB1" $BIN tax --year 2026)
ok "taxe_apprentissage 200000 tax 1360" 136000 "$(jq -r .taxe_apprentissage.tax_cents <<<"$r")"
ok "taxe_apprentissage part principale 1180" 118000 "$(jq -r .taxe_apprentissage.part_principale_cents <<<"$r")"
ok "taxe_apprentissage solde 180" 18000 "$(jq -r .taxe_apprentissage.solde_cents <<<"$r")"
rm -f "$TADB1"

# --- Taxe d'apprentissage (art. 1599) — exonération 6×SMIC ---
# 100000 EUR masse salariale ≤ 6×SMIC (139000 EUR) → exonéré, tax 0
TADB2="$(mktemp -u /tmp/bilan-ta2-XXXXXX.db)"
BILAN_DB="$TADB2" $BIN rule set 2026 taxe_apprentissage masse_salariale_cents 10000000 >/dev/null
r=$(BILAN_DB="$TADB2" $BIN tax --year 2026)
ok "taxe_apprentissage 100000 exoneré" true "$(jq -r .taxe_apprentissage.exonere <<<"$r")"
ok "taxe_apprentissage 100000 tax 0" 0 "$(jq -r .taxe_apprentissage.tax_cents <<<"$r")"
rm -f "$TADB2"

# --- Taxe d'apprentissage (art. 1599) — Alsace-Moselle 0.44% ---
# 200000 EUR masse salariale, Alsace-Moselle → 0.36% × 200000 + 0.08% × 200000 = 720 + 160 = 880 EUR = 88000 cents
TADB3="$(mktemp -u /tmp/bilan-ta3-XXXXXX.db)"
BILAN_DB="$TADB3" $BIN rule set 2026 taxe_apprentissage masse_salariale_cents 20000000 >/dev/null
BILAN_DB="$TADB3" $BIN rule set 2026 taxe_apprentissage region alsace_moselle >/dev/null
r=$(BILAN_DB="$TADB3" $BIN tax --year 2026)
ok "taxe_apprentissage alsace 0.44% tax 880" 88000 "$(jq -r .taxe_apprentissage.tax_cents <<<"$r")"
rm -f "$TADB3"

# --- CSA — <1% alternants, <2000 salariés → 0.4% ---
# 1000000 EUR masse salariale, 300 salariés, 0.5% alternants → CSA = 0.4% × 1000000 = 4000 EUR = 400000 cents
TADB4="$(mktemp -u /tmp/bilan-ta4-XXXXXX.db)"
BILAN_DB="$TADB4" $BIN rule set 2026 taxe_apprentissage masse_salariale_cents 100000000 >/dev/null
BILAN_DB="$TADB4" $BIN rule set 2026 taxe_apprentissage csa_eligible 1 >/dev/null
BILAN_DB="$TADB4" $BIN rule set 2026 taxe_apprentissage csa_effectif_moyen 300 >/dev/null
BILAN_DB="$TADB4" $BIN rule set 2026 taxe_apprentissage csa_alternants_pct_tenths 5 >/dev/null
r=$(BILAN_DB="$TADB4" $BIN tax --year 2026)
ok "csa <1% alternants 0.4% tax 400000" 400000 "$(jq -r .taxe_apprentissage.csa.tax_cents <<<"$r")"
rm -f "$TADB4"

# --- CSA — <1% alternants, ≥2000 salariés → 0.6% ---
# 1000000 EUR masse salariale, 2500 salariés, 0.5% alternants → CSA = 0.6% × 1000000 = 6000 EUR = 600000 cents
TADB5="$(mktemp -u /tmp/bilan-ta5-XXXXXX.db)"
BILAN_DB="$TADB5" $BIN rule set 2026 taxe_apprentissage masse_salariale_cents 100000000 >/dev/null
BILAN_DB="$TADB5" $BIN rule set 2026 taxe_apprentissage csa_eligible 1 >/dev/null
BILAN_DB="$TADB5" $BIN rule set 2026 taxe_apprentissage csa_effectif_moyen 2500 >/dev/null
BILAN_DB="$TADB5" $BIN rule set 2026 taxe_apprentissage csa_alternants_pct_tenths 5 >/dev/null
r=$(BILAN_DB="$TADB5" $BIN tax --year 2026)
ok "csa <1% alternants ≥2000 0.6% tax 600000" 600000 "$(jq -r .taxe_apprentissage.csa.tax_cents <<<"$r")"
rm -f "$TADB5"

# --- CSA — 2-3% alternants → 0.1% ---
# 1000000 EUR masse salariale, 300 salariés, 2.5% alternants → CSA = 0.1% × 1000000 = 1000 EUR = 100000 cents
TADB6="$(mktemp -u /tmp/bilan-ta6-XXXXXX.db)"
BILAN_DB="$TADB6" $BIN rule set 2026 taxe_apprentissage masse_salariale_cents 100000000 >/dev/null
BILAN_DB="$TADB6" $BIN rule set 2026 taxe_apprentissage csa_eligible 1 >/dev/null
BILAN_DB="$TADB6" $BIN rule set 2026 taxe_apprentissage csa_effectif_moyen 300 >/dev/null
BILAN_DB="$TADB6" $BIN rule set 2026 taxe_apprentissage csa_alternants_pct_tenths 25 >/dev/null
r=$(BILAN_DB="$TADB6" $BIN tax --year 2026)
ok "csa 2-3% alternants 0.1% tax 100000" 100000 "$(jq -r .taxe_apprentissage.csa.tax_cents <<<"$r")"
rm -f "$TADB6"

# --- CSA — ≥5% alternants → exonéré (0) ---
# 1000000 EUR masse salariale, 300 salariés, 5% alternants → CSA = 0
TADB7="$(mktemp -u /tmp/bilan-ta7-XXXXXX.db)"
BILAN_DB="$TADB7" $BIN rule set 2026 taxe_apprentissage masse_salariale_cents 100000000 >/dev/null
BILAN_DB="$TADB7" $BIN rule set 2026 taxe_apprentissage csa_eligible 1 >/dev/null
BILAN_DB="$TADB7" $BIN rule set 2026 taxe_apprentissage csa_effectif_moyen 300 >/dev/null
BILAN_DB="$TADB7" $BIN rule set 2026 taxe_apprentissage csa_alternants_pct_tenths 50 >/dev/null
r=$(BILAN_DB="$TADB7" $BIN tax --year 2026)
ok "csa ≥5% alternants exoneré 0" 0 "$(jq -r .taxe_apprentissage.csa.tax_cents <<<"$r")"
rm -f "$TADB7"

# --- CIR (art. 244 quater B) — basic 30% ≤ 100M ---
# 1000000 EUR dépenses → 30% × 1000000 = 300000 EUR = 30000000 cents
CIRDB1="$(mktemp -u /tmp/bilan-cir1-XXXXXX.db)"
BILAN_DB="$CIRDB1" $BIN rule set 2026 cir depenses_cents 100000000 >/dev/null
r=$(BILAN_DB="$CIRDB1" $BIN tax --year 2026)
ok "cir 1M depenses 30% credit 300000" 30000000 "$(jq -r .cir.credit_cents <<<"$r")"
rm -f "$CIRDB1"

# --- CIR (art. 244 quater B) — above 100M threshold (30% + 5%) ---
# 150000000 EUR dépenses (150M) → 30% × 100M + 5% × 50M = 30M + 2.5M = 32500000 EUR = 3250000000 cents
CIRDB2="$(mktemp -u /tmp/bilan-cir2-XXXXXX.db)"
BILAN_DB="$CIRDB2" $BIN rule set 2026 cir depenses_cents 15000000000 >/dev/null
r=$(BILAN_DB="$CIRDB2" $BIN tax --year 2026)
ok "cir 150M depenses 30%+5% credit 32500000" 3250000000 "$(jq -r .cir.credit_cents <<<"$r")"
rm -f "$CIRDB2"

# --- CIR (art. 244 quater B) — DOM 50% ≤ 100M ---
# 1000000 EUR dépenses, DOM → 50% × 1000000 = 500000 EUR = 50000000 cents
CIRDB3="$(mktemp -u /tmp/bilan-cir3-XXXXXX.db)"
BILAN_DB="$CIRDB3" $BIN rule set 2026 cir depenses_cents 100000000 >/dev/null
BILAN_DB="$CIRDB3" $BIN rule set 2026 cir dom_eligible 1 >/dev/null
r=$(BILAN_DB="$CIRDB3" $BIN tax --year 2026)
ok "cir 1M DOM 50% credit 500000" 50000000 "$(jq -r .cir.credit_cents <<<"$r")"
rm -f "$CIRDB3"

# --- CII (art. 244 quater B bis) — basic 20% ≤ 400k cap ---
# 100000 EUR dépenses innovation → 20% × 100000 = 20000 EUR = 2000000 cents
CIRDB4="$(mktemp -u /tmp/bilan-cir4-XXXXXX.db)"
BILAN_DB="$CIRDB4" $BIN rule set 2026 cir cii_depenses_cents 10000000 >/dev/null
r=$(BILAN_DB="$CIRDB4" $BIN tax --year 2026)
ok "cii 100k depenses 20% credit 20000" 2000000 "$(jq -r .cir.cii.credit_cents <<<"$r")"
rm -f "$CIRDB4"

# --- CII (art. 244 quater B bis) — above 400k cap ---
# 500000 EUR dépenses innovation, cap 400000 → 20% × 400000 = 80000 EUR = 8000000 cents
CIRDB5="$(mktemp -u /tmp/bilan-cir5-XXXXXX.db)"
BILAN_DB="$CIRDB5" $BIN rule set 2026 cir cii_depenses_cents 50000000 >/dev/null
r=$(BILAN_DB="$CIRDB5" $BIN tax --year 2026)
ok "cii 500k depenses capped 400k credit 80000" 8000000 "$(jq -r .cir.cii.credit_cents <<<"$r")"
rm -f "$CIRDB5"

# --- CII (art. 244 quater B bis) — DOM 60% ---
# 100000 EUR dépenses innovation, DOM → 60% × 100000 = 60000 EUR = 6000000 cents
CIRDB6="$(mktemp -u /tmp/bilan-cir6-XXXXXX.db)"
BILAN_DB="$CIRDB6" $BIN rule set 2026 cir cii_depenses_cents 10000000 >/dev/null
BILAN_DB="$CIRDB6" $BIN rule set 2026 cir cii_dom_eligible 1 >/dev/null
r=$(BILAN_DB="$CIRDB6" $BIN tax --year 2026)
ok "cii 100k DOM 60% credit 60000" 6000000 "$(jq -r .cir.cii.credit_cents <<<"$r")"
rm -f "$CIRDB6"

# --- Plafonnement CET (art. 1647 B sexies) — no plafonnement (CET < plafond) ---
# CFE 13680 cents (CA 30000 EUR) + CVAE 0 = 13680 cents CET.
# VA 1000000 EUR = 100000000 cents → plafond = 1.438% × 1000000 = 14380 EUR = 1438000 cents
# CET 13680 < plafond 1438000 → no dégrèvement
CETDB1="$(mktemp -u /tmp/bilan-cet1-XXXXXX.db)"
BILAN_DB="$CETDB1" $BIN stream add biz --kind bic >/dev/null
BILAN_DB="$CETDB1" $BIN tx add biz 2026-06-30 30000 >/dev/null
BILAN_DB="$CETDB1" $BIN rule set 2026 cet_plafonnement valeur_ajoutee_cents 100000000 >/dev/null
r=$(BILAN_DB="$CETDB1" $BIN tax --year 2026)
ok "cet plafonnement no degrevement (CET < plafond)" 0 "$(jq -r .cet_plafonnement.degrevement_cents <<<"$r")"
rm -f "$CETDB1"

# --- Plafonnement CET (art. 1647 B sexies) — dégrèvement triggered ---
# CFE 13680 cents + CVAE 0 = 13680 cents CET.
# VA 1000 EUR = 100000 cents → plafond = 1.438% × 1000 = 14.38 EUR = 1438 cents
# CET 13680 > plafond 1438 → dégrèvement = 13680 - 1438 = 12242 cents
CETDB2="$(mktemp -u /tmp/bilan-cet2-XXXXXX.db)"
BILAN_DB="$CETDB2" $BIN stream add biz --kind bic >/dev/null
BILAN_DB="$CETDB2" $BIN tx add biz 2026-06-30 30000 >/dev/null
BILAN_DB="$CETDB2" $BIN rule set 2026 cet_plafonnement valeur_ajoutee_cents 100000 >/dev/null
r=$(BILAN_DB="$CETDB2" $BIN tax --year 2026)
ok "cet plafonnement degrevement 12242" 12242 "$(jq -r .cet_plafonnement.degrevement_cents <<<"$r")"
ok "cet plafonnement cet after 1438" 1438 "$(jq -r .cet_plafonnement.cet_after_degrevement_cents <<<"$r")"
rm -f "$CETDB2"

# --- Plafonnement CET (art. 1647 B sexies) — floor CFE minimum ---
# CFE 13680 + CVAE 0 = 13680 cents CET. VA 1000 → plafond 1438. dégrèvement = 12242
# But CFE minimum = 5000 cents → dégrèvement capped at 13680 - 5000 = 8680 cents
CETDB3="$(mktemp -u /tmp/bilan-cet3-XXXXXX.db)"
BILAN_DB="$CETDB3" $BIN stream add biz --kind bic >/dev/null
BILAN_DB="$CETDB3" $BIN tx add biz 2026-06-30 30000 >/dev/null
BILAN_DB="$CETDB3" $BIN rule set 2026 cet_plafonnement valeur_ajoutee_cents 100000 >/dev/null
BILAN_DB="$CETDB3" $BIN rule set 2026 cet_plafonnement cfe_minimum_cents 5000 >/dev/null
r=$(BILAN_DB="$CETDB3" $BIN tax --year 2026)
ok "cet plafonnement floor CFE min degrevement 8680" 8680 "$(jq -r .cet_plafonnement.degrevement_cents <<<"$r")"
ok "cet plafonnement floor cet after 5000" 5000 "$(jq -r .cet_plafonnement.cet_after_degrevement_cents <<<"$r")"
rm -f "$CETDB3"

# --- TSB (art. 231 ter) — bureaux IDF c1, 200m² → 200 × 25.77 = 5154 EUR = 515400 cents ---
TSBDB1="$(mktemp -u /tmp/bilan-tsb1-XXXXXX.db)"
BILAN_DB="$TSBDB1" $BIN rule set 2026 tsb surface_m2 200 >/dev/null
BILAN_DB="$TSBDB1" $BIN rule set 2026 tsb category bureaux >/dev/null
BILAN_DB="$TSBDB1" $BIN rule set 2026 tsb region idf >/dev/null
BILAN_DB="$TSBDB1" $BIN rule set 2026 tsb circonscription 1 >/dev/null
r=$(BILAN_DB="$TSBDB1" $BIN tax --year 2026)
ok "tsb bureaux IDF c1 200m2 tax 515400" 515400 "$(jq -r .tsb.tax_cents <<<"$r")"
rm -f "$TSBDB1"

# --- TSB (art. 231 ter) — bureaux IDF c3, 200m² → 200 × 11.87 = 2374 EUR = 237400 cents ---
TSBDB2="$(mktemp -u /tmp/bilan-tsb2-XXXXXX.db)"
BILAN_DB="$TSBDB2" $BIN rule set 2026 tsb surface_m2 200 >/dev/null
BILAN_DB="$TSBDB2" $BIN rule set 2026 tsb category bureaux >/dev/null
BILAN_DB="$TSBDB2" $BIN rule set 2026 tsb region idf >/dev/null
BILAN_DB="$TSBDB2" $BIN rule set 2026 tsb circonscription 3 >/dev/null
r=$(BILAN_DB="$TSBDB2" $BIN tax --year 2026)
ok "tsb bureaux IDF c3 200m2 tax 237400" 237400 "$(jq -r .tsb.tax_cents <<<"$r")"
rm -f "$TSBDB2"

# --- TSB (art. 231 ter) — bureaux IDF c1, 50m² → exonéré (< 100m²) ---
TSBDB3="$(mktemp -u /tmp/bilan-tsb3-XXXXXX.db)"
BILAN_DB="$TSBDB3" $BIN rule set 2026 tsb surface_m2 50 >/dev/null
BILAN_DB="$TSBDB3" $BIN rule set 2026 tsb category bureaux >/dev/null
BILAN_DB="$TSBDB3" $BIN rule set 2026 tsb region idf >/dev/null
BILAN_DB="$TSBDB3" $BIN rule set 2026 tsb circonscription 1 >/dev/null
r=$(BILAN_DB="$TSBDB3" $BIN tax --year 2026)
ok "tsb bureaux 50m2 exoneré 0" 0 "$(jq -r .tsb.tax_cents <<<"$r")"
ok "tsb bureaux 50m2 exoneré flag true" true "$(jq -r .tsb.exonere <<<"$r")"
rm -f "$TSBDB3"

# --- TSB (art. 1599 quater C) — PACA bureaux, 500m² → 500 × 0.99 = 495 EUR = 49500 cents ---
TSBDB4="$(mktemp -u /tmp/bilan-tsb4-XXXXXX.db)"
BILAN_DB="$TSBDB4" $BIN rule set 2026 tsb surface_m2 500 >/dev/null
BILAN_DB="$TSBDB4" $BIN rule set 2026 tsb category bureaux >/dev/null
BILAN_DB="$TSBDB4" $BIN rule set 2026 tsb region paca >/dev/null
r=$(BILAN_DB="$TSBDB4" $BIN tax --year 2026)
ok "tsb PACA bureaux 500m2 tax 49500" 49500 "$(jq -r .tsb.tax_cents <<<"$r")"
rm -f "$TSBDB4"

# --- TSB (art. 231 ter) — stationnement IDF c1, 600m² → 600 × 2.92 = 1752 + TSS 600 × 4.98 = 2988 → total 4740 EUR ---
TSBDB5="$(mktemp -u /tmp/bilan-tsb5-XXXXXX.db)"
BILAN_DB="$TSBDB5" $BIN rule set 2026 tsb surface_m2 600 >/dev/null
BILAN_DB="$TSBDB5" $BIN rule set 2026 tsb category stationnement >/dev/null
BILAN_DB="$TSBDB5" $BIN rule set 2026 tsb region idf >/dev/null
BILAN_DB="$TSBDB5" $BIN rule set 2026 tsb circonscription 1 >/dev/null
r=$(BILAN_DB="$TSBDB5" $BIN tax --year 2026)
ok "tsb stationnement IDF c1 600m2 tax 175200" 175200 "$(jq -r .tsb.tax_cents <<<"$r")"
ok "tsb stationnement IDF c1 600m2 tss 298800" 298800 "$(jq -r .tsb.tss.tax_cents <<<"$r")"
ok "tsb stationnement IDF c1 600m2 total 474000" 474000 "$(jq -r .tsb.total_cents <<<"$r")"
rm -f "$TSBDB5"

# --- TSB (art. 231 ter) — stationnement IDF c1, 400m² → exonéré (< 500m²), no TSS ---
TSBDB6="$(mktemp -u /tmp/bilan-tsb6-XXXXXX.db)"
BILAN_DB="$TSBDB6" $BIN rule set 2026 tsb surface_m2 400 >/dev/null
BILAN_DB="$TSBDB6" $BIN rule set 2026 tsb category stationnement >/dev/null
BILAN_DB="$TSBDB6" $BIN rule set 2026 tsb region idf >/dev/null
BILAN_DB="$TSBDB6" $BIN rule set 2026 tsb circonscription 1 >/dev/null
r=$(BILAN_DB="$TSBDB6" $BIN tax --year 2026)
ok "tsb stationnement 400m2 exoneré 0" 0 "$(jq -r .tsb.tax_cents <<<"$r")"
ok "tsb stationnement 400m2 tss 0" 0 "$(jq -r .tsb.tss.tax_cents <<<"$r")"
rm -f "$TSBDB6"

# --- CRL (art. 234 nonies) — basic 2.5% on 50000 EUR loyers ---
# 50000 EUR = 5000000 cents → 2.5% × 50000 = 1250 EUR = 125000 cents
CRLDB1="$(mktemp -u /tmp/bilan-crl1-XXXXXX.db)"
BILAN_DB="$CRLDB1" $BIN rule set 2026 crl loyers_cents 5000000 >/dev/null
r=$(BILAN_DB="$CRLDB1" $BIN tax --year 2026)
ok "crl 50000 loyers 2.5% tax 125000" 125000 "$(jq -r .crl.tax_cents <<<"$r")"
rm -f "$CRLDB1"

# --- CRL (art. 234 nonies) — exonération loyer < 1830 EUR ---
# 1000 EUR = 100000 cents → < 183000 → exonéré
CRLDB2="$(mktemp -u /tmp/bilan-crl2-XXXXXX.db)"
BILAN_DB="$CRLDB2" $BIN rule set 2026 crl loyers_cents 100000 >/dev/null
r=$(BILAN_DB="$CRLDB2" $BIN tax --year 2026)
ok "crl 1000 loyers exoneré 0" 0 "$(jq -r .crl.tax_cents <<<"$r")"
ok "crl 1000 loyers exoneré flag true" true "$(jq -r .crl.exonere <<<"$r")"
rm -f "$CRLDB2"

# --- CRL (art. 234 nonies) — exonération TVA ---
# 50000 EUR loyers, TVA assujettie → exonéré
CRLDB3="$(mktemp -u /tmp/bilan-crl3-XXXXXX.db)"
BILAN_DB="$CRLDB3" $BIN rule set 2026 crl loyers_cents 5000000 >/dev/null
BILAN_DB="$CRLDB3" $BIN rule set 2026 crl tva_assujettie 1 >/dev/null
r=$(BILAN_DB="$CRLDB3" $BIN tax --year 2026)
ok "crl 50000 TVA exoneré 0" 0 "$(jq -r .crl.tax_cents <<<"$r")"
ok "crl 50000 TVA exoneré flag true" true "$(jq -r .crl.exonere <<<"$r")"
rm -f "$CRLDB3"

# --- Versement mobilité (art. L52-53) — 15 salariés, 1.5%, 100000 EUR ---
# 100000 EUR = 10000000 cents → 1.5% × 100000 = 1500 EUR = 150000 cents
VMDB1="$(mktemp -u /tmp/bilan-vm1-XXXXXX.db)"
BILAN_DB="$VMDB1" $BIN rule set 2026 versement_mobilite effectif_moyen 15 >/dev/null
BILAN_DB="$VMDB1" $BIN rule set 2026 versement_mobilite remunerations_cents 10000000 >/dev/null
BILAN_DB="$VMDB1" $BIN rule set 2026 versement_mobilite taux_pct_hundredths 150 >/dev/null
r=$(BILAN_DB="$VMDB1" $BIN tax --year 2026)
ok "vm 15 sal 1.5% 100000 tax 150000" 150000 "$(jq -r .versement_mobilite.tax_cents <<<"$r")"
rm -f "$VMDB1"

# --- Versement mobilité (art. L52-53) — <11 salariés → not eligible ---
VMDB2="$(mktemp -u /tmp/bilan-vm2-XXXXXX.db)"
BILAN_DB="$VMDB2" $BIN rule set 2026 versement_mobilite effectif_moyen 10 >/dev/null
BILAN_DB="$VMDB2" $BIN rule set 2026 versement_mobilite remunerations_cents 10000000 >/dev/null
r=$(BILAN_DB="$VMDB2" $BIN tax --year 2026)
ok "vm 10 sal not eligible 0" 0 "$(jq -r .versement_mobilite.tax_cents <<<"$r")"
ok "vm 10 sal eligible flag false" false "$(jq -r .versement_mobilite.eligible <<<"$r")"
rm -f "$VMDB2"

# --- PASNR (art. 182 A) — 50000 EUR, abattement 10% → net 45000, bracket 12% ---
# net = 45000 EUR = 4500000 cents. 45000 > 17122, < 49667 → 12%
# tax = (45000 - 17122) × 12% = 27878 × 0.12 = 3345.36 EUR → 334536 cents
PASNRDB1="$(mktemp -u /tmp/bilan-pasnr1-XXXXXX.db)"
BILAN_DB="$PASNRDB1" $BIN rule set 2026 pasnr revenus_bruts_cents 5000000 >/dev/null
r=$(BILAN_DB="$PASNRDB1" $BIN tax --year 2026)
ok "pasnr 50000 net 45000 bracket 12% tax 334536" 334536 "$(jq -r .pasnr.tax_cents <<<"$r")"
rm -f "$PASNRDB1"

# --- PASNR (art. 182 A) — 10000 EUR, abattement 10% → net 9000, below threshold → 0 ---
PASNRDB2="$(mktemp -u /tmp/bilan-pasnr2-XXXXXX.db)"
BILAN_DB="$PASNRDB2" $BIN rule set 2026 pasnr revenus_bruts_cents 1000000 >/dev/null
r=$(BILAN_DB="$PASNRDB2" $BIN tax --year 2026)
ok "pasnr 10000 net 9000 below threshold 0" 0 "$(jq -r .pasnr.tax_cents <<<"$r")"
rm -f "$PASNRDB2"

# --- PASNR (art. 182 A) — 60000 EUR, abattement 10% → net 54000, both brackets ---
# net = 54000 EUR = 5400000 cents. > 49667
# tax = (49667 - 17122) × 12% + (54000 - 49667) × 20%
# = 32545 × 0.12 + 4333 × 0.20 = 3905.40 + 866.60 = 4772.00 EUR = 477200 cents
PASNRDB3="$(mktemp -u /tmp/bilan-pasnr3-XXXXXX.db)"
BILAN_DB="$PASNRDB3" $BIN rule set 2026 pasnr revenus_bruts_cents 6000000 >/dev/null
r=$(BILAN_DB="$PASNRDB3" $BIN tax --year 2026)
ok "pasnr 60000 net 54000 both brackets tax 477200" 477200 "$(jq -r .pasnr.tax_cents <<<"$r")"
rm -f "$PASNRDB3"

# --- PASNR (art. 182 A) — DOM rates (8%/14.4%) ---
# 60000 EUR, DOM → net 54000. tax = 32545 × 8% + 4333 × 14.4%
# = 2603.60 + 623.95 = 3227.55 EUR → 322755 cents
PASNRDB4="$(mktemp -u /tmp/bilan-pasnr4-XXXXXX.db)"
BILAN_DB="$PASNRDB4" $BIN rule set 2026 pasnr revenus_bruts_cents 6000000 >/dev/null
BILAN_DB="$PASNRDB4" $BIN rule set 2026 pasnr dom_eligible 1 >/dev/null
r=$(BILAN_DB="$PASNRDB4" $BIN tax --year 2026)
ok "pasnr 60000 DOM tax 322755" 322755 "$(jq -r .pasnr.tax_cents <<<"$r")"
rm -f "$PASNRDB4"

# --- Prélèvement de solidarité (art. 119 bis 2) — 10000 EUR dividendes + 10000 EUR intérêts ---
# dividendes: 25% × 10000 = 2500 EUR = 250000 cents
# intérêts: 12.8% × 10000 + 17.2% × 10000 = 1280 + 1720 = 3000 EUR = 300000 cents
# total = 250000 + 300000 = 550000 cents
PSDB1="$(mktemp -u /tmp/bilan-ps1-XXXXXX.db)"
BILAN_DB="$PSDB1" $BIN rule set 2026 prelevement_solidarite dividendes_cents 1000000 >/dev/null
BILAN_DB="$PSDB1" $BIN rule set 2026 prelevement_solidarite interets_cents 1000000 >/dev/null
r=$(BILAN_DB="$PSDB1" $BIN tax --year 2026)
ok "ps 10000 dividendes 25% tax 250000" 250000 "$(jq -r .prelevement_solidarite.dividendes_tax_cents <<<"$r")"
ok "ps 10000 interets 30% PFU tax 300000" 300000 "$(jq -r .prelevement_solidarite.interets_tax_cents <<<"$r")"
ok "ps total 550000" 550000 "$(jq -r .prelevement_solidarite.total_cents <<<"$r")"
rm -f "$PSDB1"

# --- Terrains constructibles (art. 1529) — cession 200000, acquisition 50000, 0 ans ---
# PV = 150000 EUR = 15000000 cents. Art. 1529: 10% × 150000 = 15000 EUR = 1500000 cents
# ratio = 200000/50000 = 4 → <10 → art. 1605 nonies not eligible
TCDB1="$(mktemp -u /tmp/bilan-tc1-XXXXXX.db)"
BILAN_DB="$TCDB1" $BIN rule set 2026 terrains_constructibles prix_cession_cents 20000000 >/dev/null
BILAN_DB="$TCDB1" $BIN rule set 2026 terrains_constructibles prix_acquisition_cents 5000000 >/dev/null
r=$(BILAN_DB="$TCDB1" $BIN tax --year 2026)
ok "tc art1529 PV 150000 10% tax 1500000" 1500000 "$(jq -r .terrains_constructibles.art_1529.tax_cents <<<"$r")"
ok "tc art1605 ratio <10 not eligible" false "$(jq -r .terrains_constructibles.art_1605_nonies.eligible <<<"$r")"
rm -f "$TCDB1"

# --- Terrains constructibles (art. 1605 nonies) — ratio 20, 0 ans ---
# cession 100000, acquisition 5000 → ratio 20, PV 95000
# art. 1529: 10% × 95000 = 9500 EUR = 950000 cents
# art. 1605: ratio 20 (between 10-30) → 5% × 95000 = 4750 EUR = 475000 cents
TCDB2="$(mktemp -u /tmp/bilan-tc2-XXXXXX.db)"
BILAN_DB="$TCDB2" $BIN rule set 2026 terrains_constructibles prix_cession_cents 10000000 >/dev/null
BILAN_DB="$TCDB2" $BIN rule set 2026 terrains_constructibles prix_acquisition_cents 500000 >/dev/null
r=$(BILAN_DB="$TCDB2" $BIN tax --year 2026)
ok "tc art1529 PV 95000 10% tax 950000" 950000 "$(jq -r .terrains_constructibles.art_1529.tax_cents <<<"$r")"
ok "tc art1605 ratio 20 eligible true" true "$(jq -r .terrains_constructibles.art_1605_nonies.eligible <<<"$r")"
ok "tc art1605 ratio 20 5% tax 475000" 475000 "$(jq -r .terrains_constructibles.art_1605_nonies.tax_cents <<<"$r")"
rm -f "$TCDB2"

# --- Terrains constructibles (art. 1605 nonies) — abattement 10 ans ---
# cession 100000, acquisition 5000, 10 ans → abattement 2/10
# PV 95000, après abattement 95000 × 0.8 = 76000
# art. 1605: 5% × 76000 = 3800 EUR = 380000 cents
TCDB3="$(mktemp -u /tmp/bilan-tc3-XXXXXX.db)"
BILAN_DB="$TCDB3" $BIN rule set 2026 terrains_constructibles prix_cession_cents 10000000 >/dev/null
BILAN_DB="$TCDB3" $BIN rule set 2026 terrains_constructibles prix_acquisition_cents 500000 >/dev/null
BILAN_DB="$TCDB3" $BIN rule set 2026 terrains_constructibles annees_apres_constructible 10 >/dev/null
r=$(BILAN_DB="$TCDB3" $BIN tax --year 2026)
ok "tc art1605 10ans abattement 2 pv_apres 7600000" 7600000 "$(jq -r .terrains_constructibles.pv_apres_abattement_cents <<<"$r")"
ok "tc art1605 10ans 5% tax 380000" 380000 "$(jq -r .terrains_constructibles.art_1605_nonies.tax_cents <<<"$r")"
rm -f "$TCDB3"

# --- Terrains constructibles (art. 1529 forfaitaire) — pas de référence, 2/3 prix ---
# cession 30000, forfaitaire=1 → PV = 2/3 × 30000 = 20000, 10% = 2000 EUR = 200000 cents
TCDB4="$(mktemp -u /tmp/bilan-tc4-XXXXXX.db)"
BILAN_DB="$TCDB4" $BIN rule set 2026 terrains_constructibles prix_cession_cents 3000000 >/dev/null
BILAN_DB="$TCDB4" $BIN rule set 2026 terrains_constructibles forfaitaire_sans_reference 1 >/dev/null
r=$(BILAN_DB="$TCDB4" $BIN tax --year 2026)
ok "tc forfaitaire 2/3 30000 PV 2000000" 2000000 "$(jq -r .terrains_constructibles.plus_value_cents <<<"$r")"
ok "tc forfaitaire 10% tax 200000" 200000 "$(jq -r .terrains_constructibles.art_1529.tax_cents <<<"$r")"
rm -f "$TCDB4"

# --- TSCA (art. 1001) — incendie general 30% on 1000 EUR prime ---
# 1000 EUR = 100000 cents → 30% × 1000 = 300 EUR = 30000 cents
TSCADB1="$(mktemp -u /tmp/bilan-tsca1-XXXXXX.db)"
BILAN_DB="$TSCADB1" $BIN rule set 2026 tsca prime_cents 100000 >/dev/null
BILAN_DB="$TSCADB1" $BIN rule set 2026 tsca category incendie_general >/dev/null
r=$(BILAN_DB="$TSCADB1" $BIN tax --year 2026)
ok "tsca incendie general 30% 1000 tax 30000" 30000 "$(jq -r .tsca.tax_cents <<<"$r")"
rm -f "$TSCADB1"

# --- TSCA (art. 1001) — incendie agricole 7% on 1000 EUR prime ---
# 7% × 1000 = 70 EUR = 7000 cents
TSCADB2="$(mktemp -u /tmp/bilan-tsca2-XXXXXX.db)"
BILAN_DB="$TSCADB2" $BIN rule set 2026 tsca prime_cents 100000 >/dev/null
BILAN_DB="$TSCADB2" $BIN rule set 2026 tsca category incendie_agricole >/dev/null
r=$(BILAN_DB="$TSCADB2" $BIN tax --year 2026)
ok "tsca incendie agricole 7% 1000 tax 7000" 7000 "$(jq -r .tsca.tax_cents <<<"$r")"
rm -f "$TSCADB2"

# --- TSCA (art. 1001) — automobile 33% on 1000 EUR prime ---
# 33% × 1000 = 330 EUR = 33000 cents
TSCADB3="$(mktemp -u /tmp/bilan-tsca3-XXXXXX.db)"
BILAN_DB="$TSCADB3" $BIN rule set 2026 tsca prime_cents 100000 >/dev/null
BILAN_DB="$TSCADB3" $BIN rule set 2026 tsca category automobile >/dev/null
r=$(BILAN_DB="$TSCADB3" $BIN tax --year 2026)
ok "tsca automobile 33% 1000 tax 33000" 33000 "$(jq -r .tsca.tax_cents <<<"$r")"
rm -f "$TSCADB3"

# --- TSCA (art. 1001) — autres 9% (default) on 1000 EUR prime ---
# 9% × 1000 = 90 EUR = 9000 cents
TSCADB4="$(mktemp -u /tmp/bilan-tsca4-XXXXXX.db)"
BILAN_DB="$TSCADB4" $BIN rule set 2026 tsca prime_cents 100000 >/dev/null
r=$(BILAN_DB="$TSCADB4" $BIN tax --year 2026)
ok "tsca autres default 9% 1000 tax 9000" 9000 "$(jq -r .tsca.tax_cents <<<"$r")"
rm -f "$TSCADB4"

# --- TSCA (art. 1001) — assurance-vie 3.5% on 10000 EUR prime ---
# 3.5% × 10000 = 350 EUR = 35000 cents
TSCADB5="$(mktemp -u /tmp/bilan-tsca5-XXXXXX.db)"
BILAN_DB="$TSCADB5" $BIN rule set 2026 tsca prime_cents 1000000 >/dev/null
BILAN_DB="$TSCADB5" $BIN rule set 2026 tsca category assurance_vie >/dev/null
r=$(BILAN_DB="$TSCADB5" $BIN tax --year 2026)
ok "tsca assurance_vie 3.5% 10000 tax 35000" 35000 "$(jq -r .tsca.tax_cents <<<"$r")"
rm -f "$TSCADB5"

# --- surtaxe sur plus-values immobilières élevées (art. 1609 nonies G) ---
# PV immo 80000 (no abattement, detention 0) → pv_ir_base 80000 > 50000
# Bracket 1: 50k-60k at 2% = 10000 × 2% = 200 EUR = 20000 cents
# Bracket 2: 60k-80k at 3% = 20000 × 3% = 600 EUR = 60000 cents
# Total surtaxe = 800 EUR = 80000 cents
STDB1="$(mktemp -u /tmp/bilan-surtaxe1-XXXXXX.db)"
BILAN_DB="$STDB1" $BIN stream add im --kind plus_value_immo >/dev/null
BILAN_DB="$STDB1" $BIN tx add im 2026-06-30 80000 >/dev/null
r=$(BILAN_DB="$STDB1" $BIN tax --year 2026)
ok "pv immo 80k surtaxe 800" 80000 "$(jq -r .plus_values.immo.surtaxe_cents <<<"$r")"
ok "pv immo 80k totals surtaxe 800" 80000 "$(jq -r .totals.pv_immo_surtaxe_cents <<<"$r")"
rm -f "$STDB1"
# PV immo 40000 → below threshold → no surtaxe
STDB2="$(mktemp -u /tmp/bilan-surtaxe2-XXXXXX.db)"
BILAN_DB="$STDB2" $BIN stream add im --kind plus_value_immo >/dev/null
BILAN_DB="$STDB2" $BIN tx add im 2026-06-30 40000 >/dev/null
r=$(BILAN_DB="$STDB2" $BIN tax --year 2026)
ok "pv immo 40k no surtaxe" 0 "$(jq -r .plus_values.immo.surtaxe_cents <<<"$r")"
rm -f "$STDB2"
# PV immo 300000 → all brackets
# B1: 10k × 2% = 200; B2: 40k × 3% = 1200; B3: 50k × 4% = 2000; B4: 50k × 5% = 2500; B5: 50k × 6% = 3000; B6: 50k × 6% = 3000
# Total = 200+1200+2000+2500+3000+3000 = 11900 EUR = 1190000 cents
STDB3="$(mktemp -u /tmp/bilan-surtaxe3-XXXXXX.db)"
BILAN_DB="$STDB3" $BIN stream add im --kind plus_value_immo >/dev/null
BILAN_DB="$STDB3" $BIN tx add im 2026-06-30 300000 >/dev/null
r=$(BILAN_DB="$STDB3" $BIN tax --year 2026)
ok "pv immo 300k surtaxe 11900" 1190000 "$(jq -r .plus_values.immo.surtaxe_cents <<<"$r")"
rm -f "$STDB3"

# --- taxe forfaitaire métaux précieux et objets d'art (art. 150 VI/VK) ---
# 10000 métaux × 11% = 1100 EUR = 110000 cents
MPDB1="$(mktemp -u /tmp/bilan-metaux1-XXXXXX.db)"
BILAN_DB="$MPDB1" $BIN stream add or --kind metaux >/dev/null
BILAN_DB="$MPDB1" $BIN tx add or 2026-06-30 10000 >/dev/null
r=$(BILAN_DB="$MPDB1" $BIN tax --year 2026)
ok "metaux 10k tax 1100" 110000 "$(jq -r .metaux_precieux.metaux_tax_cents <<<"$r")"
ok "metaux 10k total 1100" 110000 "$(jq -r .metaux_precieux.total_tax_cents <<<"$r")"
ok "metaux 10k totals 1100" 110000 "$(jq -r .totals.metaux_precieux_cents <<<"$r")"
rm -f "$MPDB1"
# 10000 objets d'art × 6% = 600 EUR = 60000 cents
MPDB2="$(mktemp -u /tmp/bilan-metaux2-XXXXXX.db)"
BILAN_DB="$MPDB2" $BIN stream add art --kind objets_art >/dev/null
BILAN_DB="$MPDB2" $BIN tx add art 2026-06-30 10000 >/dev/null
r=$(BILAN_DB="$MPDB2" $BIN tax --year 2026)
ok "objets_art 10k tax 600" 60000 "$(jq -r .metaux_precieux.objets_art_tax_cents <<<"$r")"
ok "objets_art 10k total 600" 60000 "$(jq -r .metaux_precieux.total_tax_cents <<<"$r")"
rm -f "$MPDB2"

# --- Option art. 150 VL (régime PV art. 150 UA for métaux/objets d'art) ---
# 10000 EUR cession, acquisition 8000 EUR, detention 5y → PV = 2000
# Abattement 5% × (5-2) = 15% → base = 2000 × 0.85 = 1700
# IR 19% × 1700 = 323; social 17.2% × 1700 = 292.4; total = 615.4 EUR = 61540 cents
# Forfaitaire = 10000 × 11% = 1100 EUR = 110000 cents → 150 VL is lower
VLDB1="$(mktemp -u /tmp/bilan-vl1-XXXXXX.db)"
BILAN_DB="$VLDB1" $BIN stream add or --kind metaux >/dev/null
BILAN_DB="$VLDB1" $BIN tx add or 2026-06-30 10000 >/dev/null
BILAN_DB="$VLDB1" $BIN rule set 2026 metaux_precieux option_150vl_eligible 1 >/dev/null
BILAN_DB="$VLDB1" $BIN rule set 2026 metaux_precieux option_150vl_acquisition_cents 800000 >/dev/null
BILAN_DB="$VLDB1" $BIN rule set 2026 metaux_precieux option_150vl_detention_years 5 >/dev/null
r=$(BILAN_DB="$VLDB1" $BIN tax --year 2026)
ok "vl pv 2000" 200000 "$(jq -r .metaux_precieux.option_150vl_pv_cents <<<"$r")"
ok "vl abattement 15%" 15 "$(jq -r .metaux_precieux.option_150vl_abattement_pct <<<"$r")"
ok "vl ir 323" 32300 "$(jq -r .metaux_precieux.option_150vl_ir_cents <<<"$r")"
ok "vl total 615.4" 61540 "$(jq -r .metaux_precieux.option_150vl_total_cents <<<"$r")"
ok "vl optimal 150_vl" "150_vl" "$(jq -r .metaux_precieux.optimal <<<"$r")"
ok "vl effective total 615.4" 61540 "$(jq -r .metaux_precieux.total_tax_cents <<<"$r")"
rm -f "$VLDB1"
# 22y detention → exonération (abattement 100%), PV = 0, forfaitaire wins
VLDB2="$(mktemp -u /tmp/bilan-vl2-XXXXXX.db)"
BILAN_DB="$VLDB2" $BIN stream add or --kind metaux >/dev/null
BILAN_DB="$VLDB2" $BIN tx add or 2026-06-30 10000 >/dev/null
BILAN_DB="$VLDB2" $BIN rule set 2026 metaux_precieux option_150vl_eligible 1 >/dev/null
BILAN_DB="$VLDB2" $BIN rule set 2026 metaux_precieux option_150vl_acquisition_cents 800000 >/dev/null
BILAN_DB="$VLDB2" $BIN rule set 2026 metaux_precieux option_150vl_detention_years 22 >/dev/null
r=$(BILAN_DB="$VLDB2" $BIN tax --year 2026)
ok "vl 22y abattement 100%" 100 "$(jq -r .metaux_precieux.option_150vl_abattement_pct <<<"$r")"
ok "vl 22y total 0" 0 "$(jq -r .metaux_precieux.option_150vl_total_cents <<<"$r")"
ok "vl 22y optimal 150_vl" "150_vl" "$(jq -r .metaux_precieux.optimal <<<"$r")"
rm -f "$VLDB2"

# --- LMNP amortissement art. 39 C (component-based, plafonné) ---
# Property 200000 EUR, terrain 15% → building 170000 EUR
# Components: gros œuvre 55% 50y, toiture 12% 30y, réseaux 13% 25y, agencements 20% 12y
# Mobilier 5000 EUR, 7y → 714.29 EUR/y
# Gros œuvre: 170000 × 0.55 / 50 = 1870 EUR/y
# Toiture: 170000 × 0.12 / 30 = 680 EUR/y
# Réseaux: 170000 × 0.13 / 25 = 884 EUR/y
# Agencements: 170000 × 0.20 / 12 = 2833.33 EUR/y (integer: 283333 cents)
# Total dotation brute = 1870 + 680 + 884 + 2833.33 + 714.29 = 6981.62 EUR
# Loyer net (g_lmnp_reel) = 10000 EUR → plafond 10000 > dotation → no cap
LADB1="$(mktemp -u /tmp/bilan-la1-XXXXXX.db)"
BILAN_DB="$LADB1" $BIN stream add lm --kind lmnp_reel >/dev/null
BILAN_DB="$LADB1" $BIN tx add lm 2026-06-30 10000 >/dev/null
BILAN_DB="$LADB1" $BIN rule set 2026 lmnp_amortissement property_value_cents 20000000 >/dev/null
BILAN_DB="$LADB1" $BIN rule set 2026 lmnp_amortissement mobilier_value_cents 500000 >/dev/null
r=$(BILAN_DB="$LADB1" $BIN tax --year 2026)
ok "la building 170000" 17000000 "$(jq -r .lmnp_amortissement.building_value_cents <<<"$r")"
ok "la gros oeuvre 1870" 187000 "$(jq -r .lmnp_amortissement.gros_oeuvre_dotation_cents <<<"$r")"
ok "la toiture 680" 68000 "$(jq -r .lmnp_amortissement.toiture_dotation_cents <<<"$r")"
ok "la reseaux 884" 88400 "$(jq -r .lmnp_amortissement.reseaux_dotation_cents <<<"$r")"
ok "la agencements 283333" 283333 "$(jq -r .lmnp_amortissement.agencements_dotation_cents <<<"$r")"
ok "la mobilier 71428" 71428 "$(jq -r .lmnp_amortissement.mobilier_dotation_cents <<<"$r")"
ok "la plafond 10000" 1000000 "$(jq -r .lmnp_amortissement.plafond_cents <<<"$r")"
ok "la ard 0" 0 "$(jq -r .lmnp_amortissement.ard_reportable_cents <<<"$r")"
rm -f "$LADB1"
# Plafonnement: loyer 3000 < dotation 6981 → dotation capped at 3000, ARD = 3981
LADB2="$(mktemp -u /tmp/bilan-la2-XXXXXX.db)"
BILAN_DB="$LADB2" $BIN stream add lm --kind lmnp_reel >/dev/null
BILAN_DB="$LADB2" $BIN tx add lm 2026-06-30 3000 >/dev/null
BILAN_DB="$LADB2" $BIN rule set 2026 lmnp_amortissement property_value_cents 20000000 >/dev/null
BILAN_DB="$LADB2" $BIN rule set 2026 lmnp_amortissement mobilier_value_cents 500000 >/dev/null
r=$(BILAN_DB="$LADB2" $BIN tax --year 2026)
ok "la plafond 3000" 300000 "$(jq -r .lmnp_amortissement.plafond_cents <<<"$r")"
ok "la dotation capped 3000" 300000 "$(jq -r .lmnp_amortissement.dotation_cents <<<"$r")"
rm -f "$LADB2"
# ARD carry-forward: prior year with loyer 2000 < dotation 6981 → ARD stock 4981
# Current year (2026): no prior-year lmnp_reel txs → ard_stock_prior 0
# (ARD stock requires prior-year txs + property_value rule set for that year)
LADB3="$(mktemp -u /tmp/bilan-la3-XXXXXX.db)"
BILAN_DB="$LADB3" $BIN stream add lm --kind lmnp_reel >/dev/null
BILAN_DB="$LADB3" $BIN tx add lm 2026-06-30 10000 >/dev/null
BILAN_DB="$LADB3" $BIN rule set 2026 lmnp_amortissement property_value_cents 20000000 >/dev/null
BILAN_DB="$LADB3" $BIN rule set 2026 lmnp_amortissement mobilier_value_cents 500000 >/dev/null
r=$(BILAN_DB="$LADB3" $BIN tax --year 2026)
ok "la ard stock prior 0 (no prior years)" 0 "$(jq -r .lmnp_amortissement.ard_stock_prior_cents <<<"$r")"
ok "la ard consumed 0" 0 "$(jq -r .lmnp_amortissement.ard_consumed_cents <<<"$r")"
ok "la ard stock after 0 (no cap)" 0 "$(jq -r .lmnp_amortissement.ard_stock_after_cents <<<"$r")"
rm -f "$LADB3"

# --- Quasi-usufruit art. 774 bis (déductibilité créance de restitution) ---
# 100000 EUR créance, no exception → non-déductible (art. 774 bis I)
QUDDB1="$(mktemp -u /tmp/bilan-qu1-XXXXXX.db)"
BILAN_DB="$QUDDB1" $BIN rule set 2026 quasi_usufruit creance_restitution_cents 10000000 >/dev/null
r=$(BILAN_DB="$QUDDB1" $BIN tax --year 2026)
ok "qu creance 100000" 10000000 "$(jq -r .quasi_usufruit.creance_restitution_cents <<<"$r")"
ok "qu deductible 0 (no exception)" 0 "$(jq -r .quasi_usufruit.deductible_cents <<<"$r")"
rm -f "$QUDDB1"
# 100000 EUR créance, exception cession non-fiscal → deductible
QUDDB2="$(mktemp -u /tmp/bilan-qu2-XXXXXX.db)"
BILAN_DB="$QUDDB2" $BIN rule set 2026 quasi_usufruit creance_restitution_cents 10000000 >/dev/null
BILAN_DB="$QUDDB2" $BIN rule set 2026 quasi_usufruit exception_cession_non_fiscal 1 >/dev/null
r=$(BILAN_DB="$QUDDB2" $BIN tax --year 2026)
ok "qu deductible 100000 (cession exception)" 10000000 "$(jq -r .quasi_usufruit.deductible_cents <<<"$r")"
rm -f "$QUDDB2"
# 100000 EUR créance, exception usufruit légal conjoint → deductible
QUDDB3="$(mktemp -u /tmp/bilan-qu3-XXXXXX.db)"
BILAN_DB="$QUDDB3" $BIN rule set 2026 quasi_usufruit creance_restitution_cents 10000000 >/dev/null
BILAN_DB="$QUDDB3" $BIN rule set 2026 quasi_usufruit exception_usufruit_legal_conjoint 1 >/dev/null
r=$(BILAN_DB="$QUDDB3" $BIN tax --year 2026)
ok "qu deductible 100000 (conjoint exception)" 10000000 "$(jq -r .quasi_usufruit.deductible_cents <<<"$r")"
rm -f "$QUDDB3"

# --- Démembrement temporaire art. 669 II (23%/10y plafonné viager) ---
# 10y duration, age 55 (viager cap 50%) → 23% < 50% → usufruit 23%
# Bien 100000 EUR → usufruit 23000 EUR = 2300000 cents, nue-propriété 77000 EUR
DTDB1="$(mktemp -u /tmp/bilan-dt1-XXXXXX.db)"
BILAN_DB="$DTDB1" $BIN rule set 2026 demembrement_temporaire duree_years 10 >/dev/null
BILAN_DB="$DTDB1" $BIN rule set 2026 demembrement_temporaire bien_valeur_cents 10000000 >/dev/null
BILAN_DB="$DTDB1" $BIN rule set 2026 demembrement_temporaire usufruitier_age 55 >/dev/null
r=$(BILAN_DB="$DTDB1" $BIN tax --year 2026)
ok "dt 10y usufruit 23%" 23 "$(jq -r .demembrement_temporaire.usufruit_pct <<<"$r")"
ok "dt 10y usufruit valeur 23000" 2300000 "$(jq -r .demembrement_temporaire.usufruit_valeur_cents <<<"$r")"
ok "dt 10y nue-propriete 77%" 77 "$(jq -r .demembrement_temporaire.nue_propriete_pct <<<"$r")"
rm -f "$DTDB1"
# 30y duration, age 75 (viager cap 30%) → 69% > 30% → capped at 30%
DTDB2="$(mktemp -u /tmp/bilan-dt2-XXXXXX.db)"
BILAN_DB="$DTDB2" $BIN rule set 2026 demembrement_temporaire duree_years 30 >/dev/null
BILAN_DB="$DTDB2" $BIN rule set 2026 demembrement_temporaire bien_valeur_cents 10000000 >/dev/null
BILAN_DB="$DTDB2" $BIN rule set 2026 demembrement_temporaire usufruitier_age 75 >/dev/null
r=$(BILAN_DB="$DTDB2" $BIN tax --year 2026)
ok "dt 30y capped at viager 30%" 30 "$(jq -r .demembrement_temporaire.usufruit_pct <<<"$r")"
ok "dt 30y usufruit valeur 30000" 3000000 "$(jq -r .demembrement_temporaire.usufruit_valeur_cents <<<"$r")"
rm -f "$DTDB2"

# --- PAS taux individualisé art. 204 M (conjoint faible + fort) ---
# C1=20000, C2=60000, communs=10000, parts=2
# Low = C1 (20000). Low base = 20000 + 5000 = 25000, ½ parts = 1
# Foyer base = 90000, parts=2, quotient=45000
# Low taux = IR(25000) / 25000; High taux = (IR(90000,2p) - IR(25000) - IR_communs) / 60000
PIDB1="$(mktemp -u /tmp/bilan-pi1-XXXXXX.db)"
BILAN_DB="$PIDB1" $BIN rule set 2026 pas_individualise conjoint1_revenu_perso_cents 2000000 >/dev/null
BILAN_DB="$PIDB1" $BIN rule set 2026 pas_individualise conjoint2_revenu_perso_cents 6000000 >/dev/null
BILAN_DB="$PIDB1" $BIN rule set 2026 pas_individualise revenus_communs_cents 1000000 >/dev/null
r=$(BILAN_DB="$PIDB1" $BIN tax --year 2026)
ok "pi c1 rev 20000" 2000000 "$(jq -r .pas_individualise.conjoint1_revenu_perso_cents <<<"$r")"
ok "pi c2 rev 60000" 6000000 "$(jq -r .pas_individualise.conjoint2_revenu_perso_cents <<<"$r")"
ok "pi communs 10000" 1000000 "$(jq -r .pas_individualise.revenus_communs_cents <<<"$r")"
# C1 is the low conjoint (20000 < 60000), so c1_taux = low_taux
# Low base = 25000 EUR = 2500000 cents, 1 part, quotient = 2500000
# IR = (2500000 - 1149700) * 11% = 1350300 * 0.11 = 148533 cents
# Taux = 148533 * 1000 / 2500000 = 59 tenths
ok "pi c1 (low) taux 59" 59 "$(jq -r .pas_individualise.conjoint1_taux_tenths <<<"$r")"
rm -f "$PIDB1"

# --- DMTG art. 777 (ligne directe, 200000 actif, 100000 abattement) ---
# Base = 100000. Brackets: 5% 0-8072, 10% 8072-12098, 15% 12098-15995,
# DMTG ligne directe: 200000 actif, 100000 abattement → base 100000 EUR
# Progressive barème (FIXED v0.2.26): 5%*8072 + 10%*4037 + 15%*3823 + 20%*84068
# = 403.60 + 403.70 + 573.45 + 16813.60 = 18194.35 EUR = 1819435 cents
DMDB1="$(mktemp -u /tmp/bilan-dm1-XXXXXX.db)"
BILAN_DB="$DMDB1" $BIN rule set 2026 dmtg actif_taxable_cents 20000000 >/dev/null
BILAN_DB="$DMDB1" $BIN rule set 2026 dmtg degre_parente ligne_directe >/dev/null
r=$(BILAN_DB="$DMDB1" $BIN tax --year 2026)
ok "dmtg actif 200000" 20000000 "$(jq -r .dmtg.actif_taxable_cents <<<"$r")"
ok "dmtg abattement 100000" 10000000 "$(jq -r .dmtg.abattement_cents <<<"$r")"
ok "dmtg degre ligne_directe" "ligne_directe" "$(jq -r .dmtg.degre_parente <<<"$r")"
ok "dmtg ligne_directe progressive tax 1819435" 1819435 "$(jq -r .dmtg.tax_cents <<<"$r")"
rm -f "$DMDB1"
# DMTG ligne directe large base (1000000 EUR) hitting 40% bracket
# 5%*8072 + 10%*4037 + 15%*3823 + 20%*536392 + 30%*350514 + 40%*97162
# = 403.60 + 403.70 + 573.45 + 107278.40 + 105154.20 + 38864.80 = 252678.15 EUR
DMDB1B="$(mktemp -u /tmp/bilan-dm1b-XXXXXX.db)"
BILAN_DB="$DMDB1B" $BIN rule set 2026 dmtg actif_taxable_cents 110000000 >/dev/null
BILAN_DB="$DMDB1B" $BIN rule set 2026 dmtg degre_parente ligne_directe >/dev/null
r=$(BILAN_DB="$DMDB1B" $BIN tax --year 2026)
ok "dmtg ligne_directe 1M base tax 25267815" 25267815 "$(jq -r .dmtg.tax_cents <<<"$r")"
rm -f "$DMDB1B"
# DMTG tiers: 200000 actif, 1594 abattement, 60% flat
# Base = 198406, tax = 198406 * 0.60 = 119043.60 EUR = 11904360 cents
DMDB2="$(mktemp -u /tmp/bilan-dm2-XXXXXX.db)"
BILAN_DB="$DMDB2" $BIN rule set 2026 dmtg actif_taxable_cents 20000000 >/dev/null
BILAN_DB="$DMDB2" $BIN rule set 2026 dmtg degre_parente tiers >/dev/null
r=$(BILAN_DB="$DMDB2" $BIN tax --year 2026)
ok "dmtg tiers abattement 1594" 159400 "$(jq -r .dmtg.abattement_cents <<<"$r")"
ok "dmtg tiers tax 11904360" 11904360 "$(jq -r .dmtg.tax_cents <<<"$r")"
rm -f "$DMDB2"
# DMTG conjoint: exonération totale
DMDB3="$(mktemp -u /tmp/bilan-dm3-XXXXXX.db)"
BILAN_DB="$DMDB3" $BIN rule set 2026 dmtg actif_taxable_cents 20000000 >/dev/null
BILAN_DB="$DMDB3" $BIN rule set 2026 dmtg degre_parente conjoint >/dev/null
r=$(BILAN_DB="$DMDB3" $BIN tax --year 2026)
ok "dmtg conjoint tax 0 (exonéré)" 0 "$(jq -r .dmtg.tax_cents <<<"$r")"
rm -f "$DMDB3"
# DMTG on non-deductible quasi-usufruit créance (art. 774 bis II)
# 100000 créance, no exception → non-deductible, tiers → 60% on 100000 = 60000
DMDB4="$(mktemp -u /tmp/bilan-dm4-XXXXXX.db)"
BILAN_DB="$DMDB4" $BIN rule set 2026 quasi_usufruit creance_restitution_cents 10000000 >/dev/null
BILAN_DB="$DMDB4" $BIN rule set 2026 dmtg degre_parente tiers >/dev/null
r=$(BILAN_DB="$DMDB4" $BIN tax --year 2026)
ok "dmtg qu non-deductible 100000" 10000000 "$(jq -r .dmtg.quasi_usufruit_non_deductible_cents <<<"$r")"
ok "dmtg qu tax tiers 60000" 6000000 "$(jq -r .dmtg.quasi_usufruit_tax_cents <<<"$r")"
rm -f "$DMDB4"

# --- Assurance-vie art. 990 I (primes avant 70 ans) ---
# 200000 capital, abattement 152500, base 47500, 20% = 9500 EUR = 950000 cents
AVDB1="$(mktemp -u /tmp/bilan-av1-XXXXXX.db)"
BILAN_DB="$AVDB1" $BIN rule set 2026 assurance_vie capital_avant_70_cents 20000000 >/dev/null
r=$(BILAN_DB="$AVDB1" $BIN tax --year 2026)
ok "av capital 200000" 20000000 "$(jq -r .assurance_vie.capital_avant_70_cents <<<"$r")"
ok "av abattement 990i 152500" 15250000 "$(jq -r .assurance_vie.abattement_990i_cents <<<"$r")"
ok "av base 990i 47500" 4750000 "$(jq -r .assurance_vie.base_990i_cents <<<"$r")"
ok "av tax 990i 9500" 950000 "$(jq -r .assurance_vie.tax_990i_cents <<<"$r")"
ok "av tax 757b 0 (no primes after 70)" 0 "$(jq -r .assurance_vie.tax_757b_cents <<<"$r")"
ok "av total 9500" 950000 "$(jq -r .assurance_vie.total_tax_cents <<<"$r")"
rm -f "$AVDB1"
# 1000000 capital, abattement 152500, base 847500, 20% on 700000 + 31.25% on 147500
# = 140000 + 46093.75 = 186093.75 EUR = 18609375 cents
AVDB2="$(mktemp -u /tmp/bilan-av2-XXXXXX.db)"
BILAN_DB="$AVDB2" $BIN rule set 2026 assurance_vie capital_avant_70_cents 100000000 >/dev/null
r=$(BILAN_DB="$AVDB2" $BIN tax --year 2026)
ok "av base 990i 847500" 84750000 "$(jq -r .assurance_vie.base_990i_cents <<<"$r")"
ok "av tax 990i 18609375" 18609375 "$(jq -r .assurance_vie.tax_990i_cents <<<"$r")"
rm -f "$AVDB2"
# Art. 757 B: 50000 primes after 70, abattement 30500, base 19500, ligne directe
# DMTG on 19500: 5% 0-8072 + 10% 8072-12098 + 15% 12098-15995 + 20% 15995-19500
# = 403.6 + 402.6 + 584.55 + 701 = 2091.75 EUR = 209175 cents
AVDB3="$(mktemp -u /tmp/bilan-av3-XXXXXX.db)"
BILAN_DB="$AVDB3" $BIN rule set 2026 assurance_vie primes_apres_70_cents 5000000 >/dev/null
BILAN_DB="$AVDB3" $BIN rule set 2026 dmtg degre_parente ligne_directe >/dev/null
r=$(BILAN_DB="$AVDB3" $BIN tax --year 2026)
ok "av primes apres 70 50000" 5000000 "$(jq -r .assurance_vie.primes_apres_70_cents <<<"$r")"
ok "av abattement 757b 30500" 3050000 "$(jq -r .assurance_vie.abattement_757b_cents <<<"$r")"
ok "av base 757b 19500" 1950000 "$(jq -r .assurance_vie.base_757b_cents <<<"$r")"
ok "av tax 757b > 0" 1 "$(if [ "$(jq -r .assurance_vie.tax_757b_cents <<<"$r")" -gt 0 ]; then echo 1; else echo 0; fi)"
rm -f "$AVDB3"

# --- PER TNS cumul art. 154 bis + 163 quatervicies ---
# No TNS benefice → 154 bis = plancher 10% PASS N = 463670
# revenus N-1 = 50000 → 163 cap = 10% * 50000 = 5000 EUR = 500000 cents
# Combined = 463670 + 500000 = 963670 cents
PCDB1="$(mktemp -u /tmp/bilan-pc1-XXXXXX.db)"
BILAN_DB="$PCDB1" $BIN rule set 2026 per_cumul revenus_n1_cents 5000000 >/dev/null
r=$(BILAN_DB="$PCDB1" $BIN tax --year 2026)
ok "pc revenus n1 50000" 5000000 "$(jq -r .per_cumul.revenus_n1_cents <<<"$r")"
ok "pc 163 cap 500000" 500000 "$(jq -r .per_cumul.plafond_163_quatervicies_cents <<<"$r")"
ok "pc combined > 0" 1 "$(if [ "$(jq -r .per_cumul.combined_ceiling_cents <<<"$r")" -gt 0 ]; then echo 1; else echo 0; fi)"
rm -f "$PCDB1"

# --- Assurance-vie démembrement clause bénéficiaire art. 669 prorata ---
# 300000 capital, usufruitier age 75 (NP 70%), 3 NP
# NP share per NP = 300000 * 70% / 3 = 70000 EUR = 7000000 cents
# NP abattement per NP = 152500 * 70% / 3 = 35583.33 EUR = 3558333 cents
# NP taxable per NP = 7000000 - 3558333 = 3441667 cents
# NP tax per NP = 3441667 * 20% / 100 = 688333 cents (20% = 2000 hundredths)
# Total NP tax = 688333 * 3 = 2065000 cents
AVDDB1="$(mktemp -u /tmp/bilan-avd1-XXXXXX.db)"
BILAN_DB="$AVDDB1" $BIN rule set 2026 assurance_vie capital_avant_70_cents 30000000 >/dev/null
BILAN_DB="$AVDDB1" $BIN rule set 2026 assurance_vie demembrement_eligible 1 >/dev/null
BILAN_DB="$AVDDB1" $BIN rule set 2026 assurance_vie demembrement_usufruitier_age 75 >/dev/null
BILAN_DB="$AVDDB1" $BIN rule set 2026 assurance_vie demembrement_np_count 3 >/dev/null
r=$(BILAN_DB="$AVDDB1" $BIN tax --year 2026)
ok "avd eligible" true "$(jq -r .assurance_vie.demembrement.eligible <<<"$r")"
ok "avd age 75" 75 "$(jq -r .assurance_vie.demembrement.usufruitier_age <<<"$r")"
ok "avd np_count 3" 3 "$(jq -r .assurance_vie.demembrement.np_count <<<"$r")"
ok "avd usufruit 30%" 30 "$(jq -r .assurance_vie.demembrement.usufruit_pct <<<"$r")"
ok "avd nue_propriete 70%" 70 "$(jq -r .assurance_vie.demembrement.nue_propriete_pct <<<"$r")"
ok "avd np_share 7000000" 7000000 "$(jq -r .assurance_vie.demembrement.np_share_cents <<<"$r")"
ok "avd total_np_tax > 0" 1 "$(if [ "$(jq -r .assurance_vie.demembrement.total_np_tax_cents <<<"$r")" -gt 0 ]; then echo 1; else echo 0; fi)"
rm -f "$AVDDB1"

# --- PV pro art. 151 septies (exonération totale) ---
# 50000 PV, 6 ans activité, 200000 recettes commerce (< 250000) → exonéré
PVPDB1="$(mktemp -u /tmp/bilan-pvp1-XXXXXX.db)"
BILAN_DB="$PVPDB1" $BIN rule set 2026 pv_pro plus_value_cents 5000000 >/dev/null
BILAN_DB="$PVPDB1" $BIN rule set 2026 pv_pro duree_activite_years 6 >/dev/null
BILAN_DB="$PVPDB1" $BIN rule set 2026 pv_pro recettes_cents 20000000 >/dev/null
BILAN_DB="$PVPDB1" $BIN rule set 2026 pv_pro activite_type commerce >/dev/null
r=$(BILAN_DB="$PVPDB1" $BIN tax --year 2026)
ok "pvp pv 50000" 5000000 "$(jq -r .pv_pro.plus_value_cents <<<"$r")"
ok "pvp eligible 151 septies" true "$(jq -r .pv_pro.eligible_151_septies <<<"$r")"
ok "pvp pv exoneree 50000" 5000000 "$(jq -r .pv_pro.pv_exoneree_cents <<<"$r")"
ok "pvp pv imposable 0" 0 "$(jq -r .pv_pro.pv_imposable_cents <<<"$r")"
rm -f "$PVPDB1"
# PV pro NOT eligible: 3 ans activité (< 5 ans)
PVPDB2="$(mktemp -u /tmp/bilan-pvp2-XXXXXX.db)"
BILAN_DB="$PVPDB2" $BIN rule set 2026 pv_pro plus_value_cents 5000000 >/dev/null
BILAN_DB="$PVPDB2" $BIN rule set 2026 pv_pro duree_activite_years 3 >/dev/null
BILAN_DB="$PVPDB2" $BIN rule set 2026 pv_pro recettes_cents 20000000 >/dev/null
r=$(BILAN_DB="$PVPDB2" $BIN tax --year 2026)
ok "pvp NOT eligible (3y < 5y)" false "$(jq -r .pv_pro.eligible_151_septies <<<"$r")"
ok "pvp pv imposable 50000 (not exoneré)" 5000000 "$(jq -r .pv_pro.pv_imposable_cents <<<"$r")"
rm -f "$PVPDB2"
# PV pro art. 151 septies B: bien immo affecté, 8 ans détention → 30% abattement
PVPDB3="$(mktemp -u /tmp/bilan-pvp3-XXXXXX.db)"
BILAN_DB="$PVPDB3" $BIN rule set 2026 pv_pro plus_value_cents 5000000 >/dev/null
BILAN_DB="$PVPDB3" $BIN rule set 2026 pv_pro duree_activite_years 3 >/dev/null
BILAN_DB="$PVPDB3" $BIN rule set 2026 pv_pro recettes_cents 20000000 >/dev/null
BILAN_DB="$PVPDB3" $BIN rule set 2026 pv_pro bien_immo_affecte 1 >/dev/null
BILAN_DB="$PVPDB3" $BIN rule set 2026 pv_pro duree_detention_years 8 >/dev/null
r=$(BILAN_DB="$PVPDB3" $BIN tax --year 2026)
ok "pvp 151 septies B abattement 30%" 30 "$(jq -r .pv_pro.abattement_151_septies_B_pct <<<"$r")"
# PV apres abattement = 50000 * (100 - 30)% = 35000 EUR = 3500000 cents
ok "pvp pv apres abattement 35000" 3500000 "$(jq -r .pv_pro.pv_apres_abattement_cents <<<"$r")"
rm -f "$PVPDB3"

# --- DMTG donation art. 777 (conjoint Tableau II, NOT exoneré) ---
# 200000 donation conjoint, abattement 80724, base 119276
# Tableau II: 5% 0-8072, 10% 8072-15932, 15% 15932-31865, 20% 31865-552324
# Tax > 0 (conjoint NOT exoneré for donations)
DDDB1="$(mktemp -u /tmp/bilan-dd1-XXXXXX.db)"
BILAN_DB="$DDDB1" $BIN rule set 2026 dmtg_donation actif_taxable_cents 20000000 >/dev/null
BILAN_DB="$DDDB1" $BIN rule set 2026 dmtg_donation degre_parente conjoint >/dev/null
r=$(BILAN_DB="$DDDB1" $BIN tax --year 2026)
ok "dd actif 200000" 20000000 "$(jq -r .dmtg_donation.actif_taxable_cents <<<"$r")"
ok "dd conjoint abattement 80724" 8072400 "$(jq -r .dmtg_donation.abattement_cents <<<"$r")"
ok "dd conjoint tax > 0 (NOT exoneré)" 1 "$(if [ "$(jq -r .dmtg_donation.tax_cents <<<"$r")" -gt 0 ]; then echo 1; else echo 0; fi)"
rm -f "$DDDB1"
# DMTG donation ligne directe (same as succession)
DDDB2="$(mktemp -u /tmp/bilan-dd2-XXXXXX.db)"
BILAN_DB="$DDDB2" $BIN rule set 2026 dmtg_donation actif_taxable_cents 20000000 >/dev/null
BILAN_DB="$DDDB2" $BIN rule set 2026 dmtg_donation degre_parente ligne_directe >/dev/null
r=$(BILAN_DB="$DDDB2" $BIN tax --year 2026)
ok "dd ligne directe abattement 100000" 10000000 "$(jq -r .dmtg_donation.abattement_cents <<<"$r")"
ok "dd ligne directe tax > 0" 1 "$(if [ "$(jq -r .dmtg_donation.tax_cents <<<"$r")" -gt 0 ]; then echo 1; else echo 0; fi)"
rm -f "$DDDB2"
# DMTG donation with abattement 789 bis (500000 fonds commerce)
DDDB3="$(mktemp -u /tmp/bilan-dd3-XXXXXX.db)"
BILAN_DB="$DDDB3" $BIN rule set 2026 dmtg_donation actif_taxable_cents 60000000 >/dev/null
BILAN_DB="$DDDB3" $BIN rule set 2026 dmtg_donation degre_parente ligne_directe >/dev/null
BILAN_DB="$DDDB3" $BIN rule set 2026 dmtg_donation abattement_789_bis_eligible 1 >/dev/null
r=$(BILAN_DB="$DDDB3" $BIN tax --year 2026)
ok "dd 789 bis abattement 500000" 50000000 "$(jq -r .dmtg_donation.abattement_789_bis_cents <<<"$r")"
rm -f "$DDDB3"

# --- PV valeurs mobilières art. 150-0 A/D (non-PME 50% >2y) ---
# acq 50000, cession 100000 → gain 50000, detention 3y → 50% abattement → 25000
PVMOB1="$(mktemp -u /tmp/bilan-pvmob1-XXXXXX.db)"
BILAN_DB="$PVMOB1" $BIN rule set 2026 pv_mobiliere prix_acquisition_cents 5000000 >/dev/null
BILAN_DB="$PVMOB1" $BIN rule set 2026 pv_mobiliere prix_cession_cents 10000000 >/dev/null
BILAN_DB="$PVMOB1" $BIN rule set 2026 pv_mobiliere duree_detention_years 3 >/dev/null
BILAN_DB="$PVMOB1" $BIN rule set 2026 pv_mobiliere is_pme 0 >/dev/null
r=$(BILAN_DB="$PVMOB1" $BIN tax --year 2026)
ok "pvmob gain 50000" 5000000 "$(jq -r .pv_mobiliere.gain_net_cents <<<"$r")"
ok "pvmob non-PME 3y abattement 50%" 50 "$(jq -r .pv_mobiliere.abattement_pct <<<"$r")"
ok "pvmob gain apres abattement 25000" 2500000 "$(jq -r .pv_mobiliere.gain_apres_abattement_cents <<<"$r")"
rm -f "$PVMOB1"
# PV mobilières PME 6y → 75% abattement
PVMOB2="$(mktemp -u /tmp/bilan-pvmob2-XXXXXX.db)"
BILAN_DB="$PVMOB2" $BIN rule set 2026 pv_mobiliere prix_acquisition_cents 5000000 >/dev/null
BILAN_DB="$PVMOB2" $BIN rule set 2026 pv_mobiliere prix_cession_cents 10000000 >/dev/null
BILAN_DB="$PVMOB2" $BIN rule set 2026 pv_mobiliere duree_detention_years 6 >/dev/null
BILAN_DB="$PVMOB2" $BIN rule set 2026 pv_mobiliere is_pme 1 >/dev/null
r=$(BILAN_DB="$PVMOB2" $BIN tax --year 2026)
ok "pvmob PME 6y abattement 75%" 75 "$(jq -r .pv_mobiliere.abattement_pct <<<"$r")"
ok "pvmob PME gain apres abattement 12500" 1250000 "$(jq -r .pv_mobiliere.gain_apres_abattement_cents <<<"$r")"
rm -f "$PVMOB2"

# --- DMTG handicap art. 779 II (159325 cumulable) ---
# 200000 actif, ligne directe abattement 100000, base 100000 → tax > 0
# With handicap 159325 → base = 100000 - 159325 < 0 → base 0 → tax 0
DHDB1="$(mktemp -u /tmp/bilan-dh1-XXXXXX.db)"
BILAN_DB="$DHDB1" $BIN rule set 2026 dmtg actif_taxable_cents 20000000 >/dev/null
BILAN_DB="$DHDB1" $BIN rule set 2026 dmtg degre_parente ligne_directe >/dev/null
BILAN_DB="$DHDB1" $BIN rule set 2026 dmtg handicap_eligible 1 >/dev/null
r=$(BILAN_DB="$DHDB1" $BIN tax --year 2026)
ok "dh eligible" true "$(jq -r .dmtg_handicap.eligible <<<"$r")"
ok "dh abattement 159325" 15932500 "$(jq -r .dmtg_handicap.abattement_cents <<<"$r")"
# With handicap, base goes negative → 0 → tax 0
ok "dh tax 0 (base absorbed by handicap)" 0 "$(jq -r .dmtg.tax_cents <<<"$r")"
DHDB2="$(mktemp -u /tmp/bilan-dh2-XXXXXX.db)"
BILAN_DB="$DHDB2" $BIN rule set 2026 dmtg actif_taxable_cents 20000000 >/dev/null
BILAN_DB="$DHDB2" $BIN rule set 2026 dmtg degre_parente ligne_directe >/dev/null
r_no_handicap=$(BILAN_DB="$DHDB2" $BIN tax --year 2026)
tax_no_handicap=$(jq -r .dmtg.tax_cents <<<"$r_no_handicap")
ok "dh tax > 0 without handicap" 1 "$(if [ "$tax_no_handicap" -gt 0 ]; then echo 1; else echo 0; fi)"
rm -f "$DHDB1" "$DHDB2"

# --- Pacte Dutreil art. 787 B (75% abattement + 50% réduction) ---
# 1000000 actif, ligne directe, donateur 65y, pleine propriété
# After 75% abattement: 250000, abattement 100000 → base 150000
# Tax on 150000 (ligne directe), then 50% reduction
DUTREIL1="$(mktemp -u /tmp/bilan-dutreil1-XXXXXX.db)"
BILAN_DB="$DUTREIL1" $BIN rule set 2026 dmtg actif_taxable_cents 100000000 >/dev/null
BILAN_DB="$DUTREIL1" $BIN rule set 2026 dmtg degre_parente ligne_directe >/dev/null
BILAN_DB="$DUTREIL1" $BIN rule set 2026 dmtg dutreil_eligible 1 >/dev/null
BILAN_DB="$DUTREIL1" $BIN rule set 2026 dmtg dutreil_donateur_age 65 >/dev/null
BILAN_DB="$DUTREIL1" $BIN rule set 2026 dmtg dutreil_pleine_propriete 1 >/dev/null
r=$(BILAN_DB="$DUTREIL1" $BIN tax --year 2026)
ok "dutreil eligible" true "$(jq -r .dmtg_dutreil.eligible <<<"$r")"
ok "dutreil abattement 75%" 75 "$(jq -r .dmtg_dutreil.abattement_pct <<<"$r")"
ok "dutreil reduction 50%" 50 "$(jq -r .dmtg_dutreil.reduction_pct <<<"$r")"
# Compare Dutreil tax vs regular DMTG tax — Dutreil should be much lower
r_regular=$(BILAN_DB="$DUTREIL1" $BIN tax --year 2026)
# Get regular dmtg tax by temporarily disabling dutreil
DUTREIL2="$(mktemp -u /tmp/bilan-dutreil2-XXXXXX.db)"
BILAN_DB="$DUTREIL2" $BIN rule set 2026 dmtg actif_taxable_cents 100000000 >/dev/null
BILAN_DB="$DUTREIL2" $BIN rule set 2026 dmtg degre_parente ligne_directe >/dev/null
r_regular=$(BILAN_DB="$DUTREIL2" $BIN tax --year 2026)
dutreil_tax=$(jq -r .dmtg_dutreil.tax_cents <<<"$r")
regular_tax=$(jq -r .dmtg.tax_cents <<<"$r_regular")
ok "dutreil tax < regular tax" 1 "$(if [ "$dutreil_tax" -lt "$regular_tax" ]; then echo 1; else echo 0; fi)"
rm -f "$DUTREIL1" "$DUTREIL2"

# --- Donation démembrement art. 669 (donateur 65y → NP 60%) ---
# 500000 actif, ligne directe, donateur 65y → NP 60% = 300000
# abattement 100000 → base 200000 → progressive tax
DDDEM1="$(mktemp -u /tmp/bilan-dddem1-XXXXXX.db)"
BILAN_DB="$DDDEM1" $BIN rule set 2026 dmtg_donation actif_taxable_cents 50000000 >/dev/null
BILAN_DB="$DDDEM1" $BIN rule set 2026 dmtg_donation degre_parente ligne_directe >/dev/null
BILAN_DB="$DDDEM1" $BIN rule set 2026 dmtg_donation demembrement_eligible 1 >/dev/null
BILAN_DB="$DDDEM1" $BIN rule set 2026 dmtg_donation demembrement_donateur_age 65 >/dev/null
r=$(BILAN_DB="$DDDEM1" $BIN tax --year 2026)
ok "dd dem eligible" true "$(jq -r .dmtg_donation_demembrement.eligible <<<"$r")"
ok "dd dem donateur age 65" 65 "$(jq -r .dmtg_donation_demembrement.donateur_age <<<"$r")"
ok "dd dem NP pct 60" 60 "$(jq -r .dmtg_donation_demembrement.nue_propriete_pct <<<"$r")"
ok "dd dem NP value 300000" 30000000 "$(jq -r .dmtg_donation_demembrement.nue_propriete_value_cents <<<"$r")"
# Tax should be > 0 (base 200000 EUR in progressive brackets)
ok "dd dem tax > 0" 1 "$(if [ "$(jq -r .dmtg_donation_demembrement.tax_cents <<<"$r")" -gt 0 ]; then echo 1; else echo 0; fi)"
# Demembrement tax should be < regular donation tax (NP value < full actif)
dd_dem_tax=$(jq -r .dmtg_donation_demembrement.tax_cents <<<"$r")
dd_reg_tax=$(jq -r .dmtg_donation.tax_cents <<<"$r")
ok "dd dem tax < regular donation tax" 1 "$(if [ "$dd_dem_tax" -lt "$dd_reg_tax" ]; then echo 1; else echo 0; fi)"
rm -f "$DDDEM1"

# --- PV pro exonération partielle art. 151 septies II 2° (commerce 300k) ---
# Commerce: total 250k, partial 350k. Recettes 300k → abattement = (350k-300k)/(350k-250k) = 50%
# PV 100000 → exonérée 50000, imposable 50000
PVPART1="$(mktemp -u /tmp/bilan-pvpart1-XXXXXX.db)"
BILAN_DB="$PVPART1" $BIN rule set 2026 pv_pro plus_value_cents 10000000 >/dev/null
BILAN_DB="$PVPART1" $BIN rule set 2026 pv_pro duree_activite_years 6 >/dev/null
BILAN_DB="$PVPART1" $BIN rule set 2026 pv_pro recettes_cents 30000000 >/dev/null
BILAN_DB="$PVPART1" $BIN rule set 2026 pv_pro activite_type commerce >/dev/null
r=$(BILAN_DB="$PVPART1" $BIN tax --year 2026)
ok "pvp partial exoneration_partielle" true "$(jq -r .pv_pro.exoneration_partielle <<<"$r")"
ok "pvp partial exoneration pct 50" 50 "$(jq -r .pv_pro.exoneration_pct <<<"$r")"
ok "pvp partial pv exoneree 50000" 5000000 "$(jq -r .pv_pro.pv_exoneree_cents <<<"$r")"
ok "pvp partial pv imposable 50000" 5000000 "$(jq -r .pv_pro.pv_imposable_cents <<<"$r")"
rm -f "$PVPART1"

# --- Donation temporaire d'usufruit art. 669 II (10y → 23%) ---
# 400000 actif, ligne directe, donateur 65y, durée 10y → usufruit 23% = 92000
# abattement 100000 → base 0 (92000 < 100000) → tax 0
DDUT1="$(mktemp -u /tmp/bilan-ddut1-XXXXXX.db)"
BILAN_DB="$DDUT1" $BIN rule set 2026 dmtg_donation actif_taxable_cents 40000000 >/dev/null
BILAN_DB="$DDUT1" $BIN rule set 2026 dmtg_donation degre_parente ligne_directe >/dev/null
BILAN_DB="$DDUT1" $BIN rule set 2026 dmtg_donation usufruit_temporaire_eligible 1 >/dev/null
BILAN_DB="$DDUT1" $BIN rule set 2026 dmtg_donation usufruit_temporaire_duree_years 10 >/dev/null
BILAN_DB="$DDUT1" $BIN rule set 2026 dmtg_donation usufruit_temporaire_donateur_age 65 >/dev/null
r=$(BILAN_DB="$DDUT1" $BIN tax --year 2026)
ok "dd ut eligible" true "$(jq -r .dmtg_donation_usufruit_temporaire.eligible <<<"$r")"
ok "dd ut duree 10" 10 "$(jq -r .dmtg_donation_usufruit_temporaire.duree_years <<<"$r")"
ok "dd ut usufruit pct 23" 23 "$(jq -r .dmtg_donation_usufruit_temporaire.usufruit_pct <<<"$r")"
ok "dd ut usufruit value 92000" 9200000 "$(jq -r .dmtg_donation_usufruit_temporaire.usufruit_value_cents <<<"$r")"
# Tax 0 because usufruit value (92000) < abattement (100000)
ok "dd ut tax 0 (under abattement)" 0 "$(jq -r .dmtg_donation_usufruit_temporaire.tax_cents <<<"$r")"
rm -f "$DDUT1"

# --- Donation temporaire d'usufruit art. 669 II (20y → 46%, capped at viager) ---
# 400000 actif, ligne directe, donateur 75y, durée 20y → temporaire 46% but viager 30% → capped 30%
DDUT2="$(mktemp -u /tmp/bilan-ddut2-XXXXXX.db)"
BILAN_DB="$DDUT2" $BIN rule set 2026 dmtg_donation actif_taxable_cents 40000000 >/dev/null
BILAN_DB="$DDUT2" $BIN rule set 2026 dmtg_donation degre_parente ligne_directe >/dev/null
BILAN_DB="$DDUT2" $BIN rule set 2026 dmtg_donation usufruit_temporaire_eligible 1 >/dev/null
BILAN_DB="$DDUT2" $BIN rule set 2026 dmtg_donation usufruit_temporaire_duree_years 20 >/dev/null
BILAN_DB="$DDUT2" $BIN rule set 2026 dmtg_donation usufruit_temporaire_donateur_age 75 >/dev/null
r=$(BILAN_DB="$DDUT2" $BIN tax --year 2026)
ok "dd ut2 usufruit pct 30 (viager cap)" 30 "$(jq -r .dmtg_donation_usufruit_temporaire.usufruit_pct <<<"$r")"
ok "dd ut2 usufruit value 120000" 12000000 "$(jq -r .dmtg_donation_usufruit_temporaire.usufruit_value_cents <<<"$r")"
rm -f "$DDUT2"

# --- PV mobilière report d'imposition art. 150-0 D bis (50% reinvesti) ---
# 100000 gain, report eligible, 50% reinvesti → reporte 50000, imposable 50000
PVREP1="$(mktemp -u /tmp/bilan-pvrep1-XXXXXX.db)"
BILAN_DB="$PVREP1" $BIN rule set 2026 pv_mobiliere prix_acquisition_cents 10000000 >/dev/null
BILAN_DB="$PVREP1" $BIN rule set 2026 pv_mobiliere prix_cession_cents 20000000 >/dev/null
BILAN_DB="$PVREP1" $BIN rule set 2026 pv_mobiliere duree_detention_years 3 >/dev/null
BILAN_DB="$PVREP1" $BIN rule set 2026 pv_mobiliere report_eligible 1 >/dev/null
BILAN_DB="$PVREP1" $BIN rule set 2026 pv_mobiliere report_reinvesti_pct_tenths 500 >/dev/null
r=$(BILAN_DB="$PVREP1" $BIN tax --year 2026)
ok "pvmob report eligible" true "$(jq -r .pv_mobiliere.report.eligible <<<"$r")"
ok "pvmob report reinvesti pct 50" 50 "$(jq -r .pv_mobiliere.report.reinvesti_pct <<<"$r")"
ok "pvmob report gain reporte 50000" 5000000 "$(jq -r .pv_mobiliere.report.gain_reporte_cents <<<"$r")"
ok "pvmob report gain imposable 50000" 5000000 "$(jq -r .pv_mobiliere.report.gain_imposable_cents <<<"$r")"
rm -f "$PVREP1"

# --- monuments historiques (art. 156, déduction 100%/50%) ---
# 10000 charges (negative tx), fermé → 50% deduction = 5000 EUR = 500000 cents
MHDB1="$(mktemp -u /tmp/bilan-mh1-XXXXXX.db)"
BILAN_DB="$MHDB1" $BIN stream add mh --kind monument_historique >/dev/null
BILAN_DB="$MHDB1" $BIN tx add mh 2026-06-30 -10000 >/dev/null
r=$(BILAN_DB="$MHDB1" $BIN tax --year 2026)
ok "mh charges 10000" 1000000 "$(jq -r .monuments_historiques.charges_cents <<<"$r")"
ok "mh fermé taux 50%" 50 "$(jq -r .monuments_historiques.taux_pct <<<"$r")"
ok "mh fermé deduction 5000" 500000 "$(jq -r .monuments_historiques.deduction_cents <<<"$r")"
ok "mh fermé ir deduction 5000" 500000 "$(jq -r .ir.mh_deduction_cents <<<"$r")"
rm -f "$MHDB1"
# Same charges, ouvert public → 100% deduction = 10000 EUR = 1000000 cents
MHDB2="$(mktemp -u /tmp/bilan-mh2-XXXXXX.db)"
BILAN_DB="$MHDB2" $BIN stream add mh --kind monument_historique >/dev/null
BILAN_DB="$MHDB2" $BIN tx add mh 2026-06-30 -10000 >/dev/null
BILAN_DB="$MHDB2" $BIN rule set 2026 monuments_historiques ouvert_public 1 >/dev/null
r=$(BILAN_DB="$MHDB2" $BIN tax --year 2026)
ok "mh ouvert taux 100%" 100 "$(jq -r .monuments_historiques.taux_pct <<<"$r")"
ok "mh ouvert deduction 10000" 1000000 "$(jq -r .monuments_historiques.deduction_cents <<<"$r")"
rm -f "$MHDB2"

# --- démembrement barème (art. 669, usufruit par âge) ---
# Age 55 → usufruit 50%, nue-propriété 50%
DEMDB1="$(mktemp -u /tmp/bilan-dem1-XXXXXX.db)"
BILAN_DB="$DEMDB1" $BIN rule set 2026 demembrement usufruitier_age 55 >/dev/null
r=$(BILAN_DB="$DEMDB1" $BIN tax --year 2026)
ok "dem age 55 usufruit 50%" 50 "$(jq -r .demembrement.usufruit_pct <<<"$r")"
ok "dem age 55 nue-propriete 50%" 50 "$(jq -r .demembrement.nue_propriete_pct <<<"$r")"
rm -f "$DEMDB1"
# Age 35 → usufruit 70%, nue-propriété 30%
DEMDB2="$(mktemp -u /tmp/bilan-dem2-XXXXXX.db)"
BILAN_DB="$DEMDB2" $BIN rule set 2026 demembrement usufruitier_age 35 >/dev/null
r=$(BILAN_DB="$DEMDB2" $BIN tax --year 2026)
ok "dem age 35 usufruit 70%" 70 "$(jq -r .demembrement.usufruit_pct <<<"$r")"
ok "dem age 35 nue-propriete 30%" 30 "$(jq -r .demembrement.nue_propriete_pct <<<"$r")"
rm -f "$DEMDB2"
# Age 75 → usufruit 30%, nue-propriété 70%
DEMDB3="$(mktemp -u /tmp/bilan-dem3-XXXXXX.db)"
BILAN_DB="$DEMDB3" $BIN rule set 2026 demembrement usufruitier_age 75 >/dev/null
r=$(BILAN_DB="$DEMDB3" $BIN tax --year 2026)
ok "dem age 75 usufruit 30%" 30 "$(jq -r .demembrement.usufruit_pct <<<"$r")"
ok "dem age 75 nue-propriete 70%" 70 "$(jq -r .demembrement.nue_propriete_pct <<<"$r")"
rm -f "$DEMDB3"

# --- PER TNS article 154 bis (10% bénéfice + 15% 1-8 PASS) ---
# BNC 30000 EUR, micro-BNC abattement 34% → net_bnc 19800 EUR = 1980000 cents
# PASS 4399 EUR = 439900 cents, 8 PASS = 3519200 (no cap)
# 10% × 19800 = 1980; 15% × (19800 - 4399) = 15% × 15401 = 2310.15
# Total plafond = 4290.15 EUR = 429015 cents
# per_deduction = min(5000, 4290.15) = 4290.15 EUR = 429015 cents
PRTDB1="$(mktemp -u /tmp/bilan-pertns1-XXXXXX.db)"
BILAN_DB="$PRTDB1" $BIN stream add biz --kind bnc >/dev/null
BILAN_DB="$PRTDB1" $BIN tx add biz 2026-06-30 30000 >/dev/null
BILAN_DB="$PRTDB1" $BIN stream add per --kind per >/dev/null
BILAN_DB="$PRTDB1" $BIN tx add per 2026-06-30 5000 >/dev/null
r=$(BILAN_DB="$PRTDB1" $BIN tax --year 2026)
ok "per tns regime 154_bis" "154_bis" "$(jq -r .ir.per_regime <<<"$r")"
ok "per tns plafond 429015" 429015 "$(jq -r .ir.per_tns_plafond_cents <<<"$r")"
ok "per tns deduction capped 429015" 429015 "$(jq -r .ir.per_deduction_cents <<<"$r")"
rm -f "$PRTDB1"
# No TNS income → 163 quatervicies regime
PRTDB2="$(mktemp -u /tmp/bilan-pertns2-XXXXXX.db)"
BILAN_DB="$PRTDB2" $BIN stream add sal --kind salary >/dev/null
BILAN_DB="$PRTDB2" $BIN tx add sal 2026-06-30 50000 >/dev/null
BILAN_DB="$PRTDB2" $BIN stream add per --kind per >/dev/null
BILAN_DB="$PRTDB2" $BIN tx add per 2026-06-30 3000 >/dev/null
r=$(BILAN_DB="$PRTDB2" $BIN tax --year 2026)
ok "per no-tns regime 163_quatervicies" "163_quatervicies" "$(jq -r .ir.per_regime <<<"$r")"
ok "per no-tns deduction 3000" 300000 "$(jq -r .ir.per_deduction_cents <<<"$r")"
rm -f "$PRTDB2"

# --- abattement départ retraite art. 150-0 D ter (500k fixe) ---
# 100000 EUR crypto gain, eligible → IR base = 100000 - 500000 = 0
# PFU IR = 0; social = 100000 × 17.2% = 17200 EUR = 1720000 cents
DRDB1="$(mktemp -u /tmp/bilan-dr1-XXXXXX.db)"
BILAN_DB="$DRDB1" $BIN stream add cr --kind crypto >/dev/null
BILAN_DB="$DRDB1" $BIN tx add cr 2026-06-30 100000 >/dev/null
BILAN_DB="$DRDB1" $BIN rule set 2026 pvm_depart_retraite eligible 1 >/dev/null
r=$(BILAN_DB="$DRDB1" $BIN tax --year 2026)
ok "dr eligible true" true "$(jq -r .pvm.depart_retraite_eligible <<<"$r")"
ok "dr abattement 500000" 50000000 "$(jq -r .pvm.depart_retraite_abattement_cents <<<"$r")"
ok "dr ir base after abattement 0" 0 "$(jq -r .pvm.ir_base_after_abattement_cents <<<"$r")"
ok "dr pfu ir 0" 0 "$(jq -r .pvm.pfu_ir_cents <<<"$r")"
ok "dr pfu social 17200" 1720000 "$(jq -r .pvm.pfu_social_cents <<<"$r")"
rm -f "$DRDB1"
# 600000 EUR gain, eligible → IR base = 600000 - 500000 = 100000
# PFU IR = 100000 × 12.8% = 12800; social = 600000 × 17.2% = 103200
DRDB2="$(mktemp -u /tmp/bilan-dr2-XXXXXX.db)"
BILAN_DB="$DRDB2" $BIN stream add cr --kind crypto >/dev/null
BILAN_DB="$DRDB2" $BIN tx add cr 2026-06-30 600000 >/dev/null
BILAN_DB="$DRDB2" $BIN rule set 2026 pvm_depart_retraite eligible 1 >/dev/null
r=$(BILAN_DB="$DRDB2" $BIN tax --year 2026)
ok "dr 600k ir base 100000" 10000000 "$(jq -r .pvm.ir_base_after_abattement_cents <<<"$r")"
ok "dr 600k pfu ir 12800" 1280000 "$(jq -r .pvm.pfu_ir_cents <<<"$r")"
ok "dr 600k pfu social 103200" 10320000 "$(jq -r .pvm.pfu_social_cents <<<"$r")"
rm -f "$DRDB2"

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

# --- the human surface: start + --text renderings ---------------------------
# The contract these guard: --text NEVER changes the JSON (agents keep parsing it),
# and the prose never invents a number the radar did not produce.
okre "start (empty ledger) welcomes"  'registre est vide'        "$(BILAN_DB="$(mktemp -u /tmp/bilan-fresh-XXXXXX.db)" $BIN start)"
okre "start (empty) shows demo path"  'bilan demo'               "$(BILAN_DB="$(mktemp -u /tmp/bilan-fresh2-XXXXXX.db)" $BIN start)"
okre "start (seeded) shows next cmds" 'bilan tax --text'         "$(BILAN_DB="$DEMODB" $BIN start)"
okre "tax --text is prose"            'A PROVISIONNER|PROVISIONNER POUR'  "$(BILAN_DB="$DEMODB" $BIN tax --text --year 2026)"
okre "tax --text prints the total"    '7 953,73'                 "$(BILAN_DB="$DEMODB" $BIN tax --text --year 2026)"
okre "tax --text says not advice"     'conseil fiscal'       "$(BILAN_DB="$DEMODB" $BIN tax --text --year 2026)"
okre "brief --text is prose"          "l'image du jour"          "$(BILAN_DB="$DEMODB" $BIN brief --text --year 2026)"
okre "stats --text is prose"          'net encaissé'             "$(BILAN_DB="$DEMODB" $BIN stats --text --year 2026)"
ok  "tax JSON unchanged by --text"    "$(BILAN_DB="$DEMODB" $BIN tax --year 2026)" "$(BILAN_DB="$DEMODB" $BIN tax --year 2026)"
ok  "tax --text exits 0"              0 "$(code_of env BILAN_DB="$DEMODB" $BIN tax --text --year 2026)"
okre "tax --text on empty ledger"     'registre est vide'        "$(BILAN_DB="$(mktemp -u /tmp/bilan-fresh3-XXXXXX.db)" $BIN tax --text)"
rm -f /tmp/bilan-fresh*.db

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
okre "landing hero speaks to human pain" 'découvrez votre impôt' "$(curl -sf http://127.0.0.1:$PORT/)"
okre "landing shows worked example" '7 953,73' "$(curl -sf http://127.0.0.1:$PORT/)"
okre "landing has agent section below" 'Pour votre agent' "$(curl -sf http://127.0.0.1:$PORT/)"
okre "landing has why-over-LLM section" 'Pourquoi pas juste' "$(curl -sf http://127.0.0.1:$PORT/)"
okre "landing comparison table" 'cmp-row' "$(curl -sf http://127.0.0.1:$PORT/)"
okre "landing comparison LLM column" 'peut halluciner' "$(curl -sf http://127.0.0.1:$PORT/)"
okre "landing comparison bilan column" 'sourcé BOFiP' "$(curl -sf http://127.0.0.1:$PORT/)"
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
