#!/usr/bin/env bash
# All bilan tests: pure-core unit tests (machin test) + offline smoke (CLI + serve).
set -e
cd "$(dirname "$0")"
echo "── unit (src/core.src) ──"
machin test src/core.src test/core_test.src
echo "── smoke (CLI + serve, offline) ──"
[ -x ./bilan ] || ./build.sh
bash scripts/smoke.sh
