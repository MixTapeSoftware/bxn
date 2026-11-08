#!/bin/bash
# tests/property_test.sh
# Property-based, stateful tests with Python Hypothesis. For now one state
# machine: the proxy generations in egress/boxen-egress-ctl, driven against
# the fake systemd (tests/property/test_egress_ctl.py says what it checks).
# Hypothesis is optional; without it this skips, so the suite needs nothing
# beyond Bash and Python.
#   BOXEN_PROPERTY_EXAMPLES  how many sequences to run (default 50)
#   BOXEN_PROPERTY_STEPS     the most steps in one sequence (default 20)
#   BOXEN_PROPERTY_SEED      unset: the same sequences every run; a number:
#                            that seed; random: new ones, and failures are
#                            kept in .hypothesis/ to replay
#   BOXEN_PROPERTY_SHRINK=0  report a failure as found, without shrinking it
#   BOXEN_PROPERTY_STATS=1   print how often each command and fault ran
# Needs flock and jq, so Linux.
# Run: bash tests/property_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec </dev/null

PY="${PYTHON:-python3}"
if ! "$PY" -c 'import hypothesis' 2>/dev/null; then
  echo "skip: needs Hypothesis (python3 -m pip install --user hypothesis)"
  exit 0
fi
for t in flock jq; do
  command -v "$t" >/dev/null || { echo "skip: needs $t"; exit 0; }
done

echo "egress-ctl proxy generations"
"$PY" "$SCRIPT_DIR/property/test_egress_ctl.py"
