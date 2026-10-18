#!/usr/bin/env bash
# Helpers shared by e2e.sh and control.sh. Sourced, not run.
#
# The load generator is a pod inside the cluster that sends about twenty requests a second to the
# service's ClusterIP and logs one line per request: "<ms> <status or ERR> <version>". The tests count
# the lines that are not 200. The ClusterIP is used on purpose: a DNS pod being moved by a node drain
# is not the application's failure, and should not be counted as one.

IMAGE_REPO=${IMAGE_REPO:-rollout-lab}
export FAILED=0 # read by the scripts that source this file

# In GitHub Actions, every line below also goes to the run's summary page, and numbers become annotations.
summary() { # summary "markdown line"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY}"; fi
}

step() {
  printf '\n==> %s\n' "$*"
  summary ""
  summary "**$***"
}
ok() {
  printf '[PASS] %s\n' "$*"
  summary "- [x] $*"
}
bad() {
  printf '[FAIL] %s\n' "$*"
  summary "- [ ] **FAILED:** $*"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then printf '::error title=%s::%s\n' "$(basename "$0")" "$*"; fi
  FAILED=1
}
note() { # note "text": a measurement worth keeping
  printf '%s\n' "$*"
  summary "  - $*"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then printf '::notice title=%s::%s\n' "$(basename "$0")" "$*"; fi
}

# expect "description" command...   passes when the command succeeds
expect() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$description"; else bad "$description"; fi
}

kc() { kubectl -n "$NS" "$@"; }

wait_until() { # wait_until seconds command...
  local deadline=$((SECONDS + $1))
  shift
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then return 1; fi
    sleep 1
  done
}

# ---- the load generator

load_lines() { kc logs loadgen 2>/dev/null || true; }
load_total() { load_lines | wc -l; }
failed_since() { load_lines | tail -n +"$(($1 + 1))" | awk '$2 != "200"' | wc -l; }
requests_since() { load_lines | tail -n +"$(($1 + 1))" | wc -l; }
versions_since() { load_lines | tail -n +"$(($1 + 1))" | awk '$2 == "200" {print $3}' | sort -u | tr '\n' ' '; }
enough_requests() { (($(load_total) >= 20)); }

start_load() {
  local ip
  ip=$(kc get service rollout-app -o jsonpath='{.spec.clusterIP}')
  kc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: loadgen
  labels:
    rollout-lab/access: client
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  # On the control-plane node, so that draining a worker never moves the load generator.
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: loadgen
      image: ${IMAGE_REPO}:1.0.0
      imagePullPolicy: IfNotPresent
      command: ["python", "loadgen.py", "http://${ip}/", "0.05"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
YAML
  kc wait --for=condition=Ready pod/loadgen --timeout=90s
  wait_until 30 enough_requests
}

# ---- what to show when something failed

diagnostics() {
  echo
  echo "---- diagnostics for namespace $NS"
  kc get pods -o wide || true
  kc get events --sort-by=.lastTimestamp | tail -40 || true
  kc describe deployment rollout-app | tail -40 || true
  for p in $(kc get pods -l app.kubernetes.io/name=rollout-app -o name 2>/dev/null); do
    echo "---- logs of $p"
    kc logs "$p" --tail=20 || true
  done
  echo "---- failed requests (first 20)"
  load_lines | awk '$2 != "200"' | head -20
}
