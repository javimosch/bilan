#!/usr/bin/env bash
# bilan — compose (encode/typecheck) then compile to one native binary.
set -e
cd "$(dirname "$0")"
mkdir -p build
machin encode framework/machweb.src src/core.src src/store.src src/hosted.src src/guide.src src/ledger.src src/serve.src src/main.src > build/bilan.mfl
machin build build/bilan.mfl -o bilan
echo "built ./bilan"
