#!/usr/bin/env bash
# Local functional suite. Each case gets a fresh Factorio process and a retained log.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p tmp/test-logs
failed=0

cases=0
run() {
  local name=$1
  cases=$((cases + 1))
  shift
  echo "test: $name"
  if "$ROOT/tools/factorio-test.sh" "$@"; then
    echo "test: $name passed"
  else
    echo "test: $name FAILED" >&2
    failed=1
  fi
  cp .factorio-test/last-write.log "tmp/test-logs/$name.log"
}

for name in sexp formulas editor window network settings recipes guard sheets history docs; do
  run "$name" mods logistic-formulas/test "$name" 1000
done
# Remove the old save so a failed save test cannot be masked by a prior run's file.
rm -f .factorio-test/write/saves/_autosave-logf-reload.zip
run save --save-scenario mods logistic-formulas/test logf-reload
run reload-graphics --graphics mods logf-reload 1
run reload --test-save mods logf-reload reload 1000
run playtest mods logistic-formulas/playtest smoke 60
run demo-factory mods logistic-formulas/playtest factory 4000
run demo-space mods logistic-formulas/playtest space 20000

if (( failed )); then echo "test: suite FAILED; logs in tmp/test-logs" >&2; exit 1; fi
echo "test: all $cases cases passed; logs in tmp/test-logs"
