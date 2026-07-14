#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="wait-ready"
QUEUE="wait-ready-queue"
CQ="wait-ready-cq"
JOB="never-ready"
# waitForPodsReady (timeout 120s) is enabled cluster-wide in base/kueue-values.yaml,
# so this scenario just submits a gang that can never become Ready and observes
# the eviction/requeue. No per-scenario Kueue config changes are needed.
WAIT_TIMEOUT="120s"

describe() {
  echo "waitForPodsReady: an admitted gang whose pods never become Ready is evicted and requeued"
}

# _requeue_count - how many times Kueue has requeued the workload so far.
_requeue_count() {
  local wl
  wl=$(kubectl_ctx get workloads -n "$NS" -o name 2>/dev/null | head -n1)
  [ -z "$wl" ] && { echo 0; return; }
  kubectl_ctx get "$wl" -n "$NS" -o jsonpath='{.status.requeueState.count}' 2>/dev/null || echo 0
}

apply() {
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "Submitting a 2-pod gang whose pods never become Ready"
  apply_with_retry "$SCENARIO_DIR/manifests/job.yaml"

  info "workload is admitted immediately; its pods run but fail readiness..."
  info "waiting up to the ${WAIT_TIMEOUT} PodsReady timeout to evict + requeue the gang..."
  local i c
  for i in $(seq 1 60); do   # up to ~180s: enough to pass the 120s timeout
    c=$(_requeue_count)
    [ "${c:-0}" -ge 1 ] && { info "observed requeue #$c"; break; }
    sleep 3
  done
}

inspect() {
  inspect_workloads "$NS"
  echo
  echo "--- Workload conditions (PodsReady=False -> Evicted: PodsReadyTimeout) ---"
  local wl
  wl=$(kubectl_ctx get workloads -n "$NS" -o name 2>/dev/null | head -n1)
  if [ -n "$wl" ]; then
    kubectl_ctx get "$wl" -n "$NS" \
      -o jsonpath='{range .status.conditions[*]}{"    "}{.type}{"="}{.status}{" ("}{.reason}{")\n"}{end}' 2>/dev/null
    printf "    requeue count: %s\n" "$(_requeue_count)"
  fi
  echo
  echo "--- Eviction / requeue events ---"
  kubectl_ctx get events -n "$NS" --field-selector involvedObject.kind=Workload \
    -o custom-columns='REASON:.reason,COUNT:.count,MESSAGE:.message' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Pods (Running but READY 0/1: the failing readiness probe) ---"
  kubectl_ctx get pods -n "$NS" 2>/dev/null | sed 's/^/    /'
  echo
  info "waitForPodsReady turns 'admitted but never Ready' into an eviction after"
  info "${WAIT_TIMEOUT}: the whole gang's Workload is evicted (reason PodsReadyTimeout)"
  info "and requeued, freeing its quota instead of holding GPUs on a wedged job."
}

cleanup() {
  kubectl_ctx delete ns "$NS" --ignore-not-found
  kubectl_ctx delete clusterqueue "$CQ" --ignore-not-found
}
