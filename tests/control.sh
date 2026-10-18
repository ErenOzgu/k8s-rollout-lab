#!/usr/bin/env bash
# The control experiment. Run after e2e.sh, on the same cluster:
#
#   tests/control.sh
#
# The same service, deployed without a readiness probe, with a release that takes three seconds to start
# listening. Rolled out under load, it MUST drop requests. If it did not, "no request failed" in e2e.sh
# could mean that the load generator or the counting is blind.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=rollout-control
# shellcheck source=tests/lib.sh
source tests/lib.sh
trap 'diagnostics' ERR

step "deploy 1.0.0 without a readiness probe"
kubectl apply -k tests/control
kc rollout status deployment/rollout-app --timeout=120s
sleep 6 # the pods count as ready at once, but only listen after START_DELAY
start_load
expect "before the rollout every request succeeds" test "$(failed_since 0)" = 0

step "roll out 1.1.0 under load"
mark=$(load_total)
kc set image deployment/rollout-app app="${IMAGE_REPO}:1.1.0"
kc rollout status deployment/rollout-app --timeout=120s
sleep 5
failed=$(failed_since "$mark")
echo "requests during the rollout: $(requests_since "$mark"), failed: $failed"
expect "without a readiness probe the rollout drops requests (the load generator can see failures)" test "$failed" -gt 0

trap - ERR
if ((FAILED)); then
  diagnostics
  echo
  echo "The control did not behave as expected."
  exit 1
fi
echo
echo "The control behaved as expected."
