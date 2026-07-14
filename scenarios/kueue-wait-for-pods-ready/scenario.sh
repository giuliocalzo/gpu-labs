#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="wait-ready"
QUEUE="wait-ready-queue"
CQ="wait-ready-cq"
JOB="never-ready"
WAIT_TIMEOUT="30s"       # must match waitForPodsReady.timeout in kueue-values.yaml
KUEUE_CHART="oci://registry.k8s.io/kueue/charts/kueue"
SCENARIO_VALUES="$SCENARIO_DIR/manifests/kueue-values.yaml"
BASE_VALUES="$REPO_ROOT/base/kueue-values.yaml"

describe() {
  echo "waitForPodsReady: an admitted gang whose pods never become Ready is evicted and requeued"
}

# _kueue_upgrade <values-file> - re-apply the Kueue Helm release with a given
# config and wait for the controller to roll out (config changes need a restart).
_kueue_upgrade() {
  helm_ctx upgrade kueue "$KUEUE_CHART" \
    --version="$KUEUE_VERSION" \
    --namespace kueue-system \
    -f "$1" \
    --wait --timeout 300s >/dev/null
  kubectl_ctx -n kueue-system rollout status deploy/kueue-controller-manager --timeout=180s
}

# pre_run: turn on waitForPodsReady (scenario-scoped; cleanup restores base).
pre_run() {
  step "Enabling Kueue waitForPodsReady (timeout ${WAIT_TIMEOUT}) via helm upgrade"
  _kueue_upgrade "$SCENARIO_VALUES"
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
  info "waiting for the ${WAIT_TIMEOUT} PodsReady timeout to evict + requeue the gang..."
  local i c
  for i in $(seq 1 45); do
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
  step "Restoring base Kueue config (disabling waitForPodsReady)"
  _kueue_upgrade "$BASE_VALUES"
}
