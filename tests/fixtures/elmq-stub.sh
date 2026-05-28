#!/usr/bin/env bash
# elmq stub for unit tests. Ignores args and prints the canned NDJSON output
# from tests/fixtures/elmq-output.json. Real-binary behavior is covered by
# the smoke test gated on ELMQ_SMOKE=1.
set -euo pipefail
cat "$(dirname "$0")/elmq-output.json"
