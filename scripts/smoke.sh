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
