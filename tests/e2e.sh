#!/usr/bin/env bash
# Run against a kind cluster that has the images loaded (see the Makefile):
#
#   tests/e2e.sh
#
# Deploys the prod overlay, keeps a steady load on it, and then does the things that go wrong in real life,
# counting failed requests each time.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=rollout-prod
# shellcheck source=tests/lib.sh
source tests/lib.sh
trap 'diagnostics' ERR

step "deploy 1.0.0 (prod overlay: 3 replicas, PodDisruptionBudget, NetworkPolicy)"
kubectl apply -k k8s/overlays/prod
kc rollout status deployment/rollout-app --timeout=120s
expect "three replicas are ready" test "$(kc get deployment rollout-app -o jsonpath='{.status.readyReplicas}')" = 3
expect "the PodDisruptionBudget allows one pod to go at a time" \
  test "$(kc get poddisruptionbudget rollout-app -o jsonpath='{.status.disruptionsAllowed}')" = 1

step "start the load"
start_load
sleep 5
expect "no request fails before anything changes" test "$(failed_since 0)" = 0
expect "and 1.0.0 is the only version that answers" test "$(versions_since 0)" = "1.0.0 "

step "rolling update to 1.1.0 under load"
mark=$(load_total)
kc set image deployment/rollout-app app="${IMAGE_REPO}:1.1.0"
kc rollout status deployment/rollout-app --timeout=120s
sleep 3
note "rolling update: $(requests_since "$mark") requests, $(failed_since "$mark") failed, versions that answered: $(versions_since "$mark")"
expect "no request failed during the rollout" test "$(failed_since "$mark")" = 0
expect "the load saw both versions, so it really overlapped the rollout" \
  test "$(versions_since "$mark")" = "1.0.0 1.1.0 "
expect "three replicas of 1.1.0 are ready" \
  test "$(kc get deployment rollout-app -o jsonpath='{.status.readyReplicas}')" = 3

step "a release that never becomes ready is stopped, and rolled back"
mark=$(load_total)
kc set image deployment/rollout-app app="${IMAGE_REPO}:1.2.0-bad"
if kc rollout status deployment/rollout-app --timeout=120s; then
  bad "the rollout of a release that is never ready was reported as finished"
else
  ok "the rollout of a release that is never ready is reported as failed"
fi
expect "the Deployment says why: ProgressDeadlineExceeded" \
  test "$(kc get deployment rollout-app -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}')" = ProgressDeadlineExceeded
expect "the three working pods are still serving" \
  test "$(kc get deployment rollout-app -o jsonpath='{.status.availableReplicas}')" = 3
note "bad release: $(requests_since "$mark") requests while it was stuck, $(failed_since "$mark") failed"
expect "no request failed while the bad release was stuck" test "$(failed_since "$mark")" = 0
expect "the bad release never answered a request" test "$(versions_since "$mark")" = "1.1.0 "
kc rollout undo deployment/rollout-app
kc rollout status deployment/rollout-app --timeout=120s
expect "after the rollback the image is 1.1.0 again" \
  test "$(kc get deployment rollout-app -o jsonpath='{.spec.template.spec.containers[0].image}')" = "${IMAGE_REPO}:1.1.0"
expect "three replicas are ready again" test "$(kc get deployment rollout-app -o jsonpath='{.status.readyReplicas}')" = 3
expect "no request failed during the rollback either" test "$(failed_since "$mark")" = 0

step "draining a node respects the PodDisruptionBudget"
node=$(kc get pods -l app.kubernetes.io/name=rollout-app -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' |
  sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
note "draining $node, which runs $(kc get pods -l app.kubernetes.io/name=rollout-app --field-selector "spec.nodeName=$node" -o name | wc -l) of the 3 pods"
mark=$(load_total)
kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=240s
kc rollout status deployment/rollout-app --timeout=120s
expect "no app pod is left on the drained node" \
  test "$(kc get pods -l app.kubernetes.io/name=rollout-app --field-selector "spec.nodeName=$node" -o name | wc -l)" = 0
expect "three replicas are ready on the other nodes" \
  test "$(kc get deployment rollout-app -o jsonpath='{.status.readyReplicas}')" = 3
note "node drain: $(requests_since "$mark") requests, $(failed_since "$mark") failed"
expect "no request failed during the drain" test "$(failed_since "$mark")" = 0
kubectl uncordon "$node"

step "the NetworkPolicy lets clients in and keeps everyone else out"
probe() { # probe namespace [labels]: prints the HTTP status, or "blocked"
  local ns=$1 labels=${2:-}
  local ip
  ip=$(kc get service rollout-app -o jsonpath='{.spec.clusterIP}')
  kubectl -n "$ns" run "probe-$RANDOM" --rm -i --restart=Never --quiet \
    --image="${IMAGE_REPO}:1.0.0" --image-pull-policy=IfNotPresent ${labels:+--labels="$labels"} \
    --command -- python -c "
import urllib.request
try:
    print(urllib.request.urlopen('http://$ip/', timeout=4).status)
except Exception:
    print('blocked')
"
}
kubectl create namespace rollout-other --dry-run=client -o yaml | kubectl apply -f -
expect "a labelled client in the same namespace gets through" \
  test "$(probe "$NS" rollout-lab/access=client)" = 200
expect "an unlabelled pod in the same namespace is blocked" test "$(probe "$NS")" = blocked
expect "a labelled pod in another namespace is blocked" \
  test "$(probe rollout-other rollout-lab/access=client)" = blocked

step "the whole run"
note "whole run: $(load_total) requests, $(failed_since 0) failed"
expect "not one request failed in the whole run" test "$(failed_since 0)" = 0

trap - ERR
if ((FAILED)); then
  diagnostics
  echo
  echo "Some checks failed."
  exit 1
fi
echo
echo "All checks passed."
