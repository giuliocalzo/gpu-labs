#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

NS="preemption"

describe() { echo "Preemption: running low-priority jobs are evicted to make room for high-priority ones"; }

apply() {
  apply_with_retry "$SCENARIO_DIR/manifests/priorityclasses.yaml"
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "Filling the queue with 4 low-priority jobs (4 x 8 = 32 GPUs = full quota)"
  { for i in 1 2 3 4; do gpu_job "$NS" preemption-queue "low-$i" 8 pe-low; done; } \
    | kubectl_ctx apply -f -
  info "waiting for the 4 low-priority jobs to be admitted..."
  for _ in $(seq 1 30); do
    [ "$(count_admitted "$NS")" -ge 4 ] && break
    sleep 2
  done

  step "Submitting 2 high-priority jobs - Kueue must preempt 2 low-priority jobs"
  { for i in 1 2; do gpu_job "$NS" preemption-queue "high-$i" 8 pe-high; done; } \
    | kubectl_ctx apply -f -
  info "waiting for preemption to happen..."
  sleep 25
}

inspect() {
  inspect_workloads "$NS"
  echo; inspect_clusterqueue_usage "preemption-cq"
  echo
  echo "--- Preempted workloads (evicted to make room) ---"
  kubectl_ctx get events -n "$NS" --field-selector reason=Preempted \
    -o custom-columns='WORKLOAD:.involvedObject.name,MESSAGE:.message' 2>/dev/null \
    | sed 's/ due to.*//' | sed 's/^/    /' || true
  echo
  info "Expect 2 high-priority workloads Admitted=True and 2 low-priority ones evicted/pending."
}

cleanup() {
  kubectl_ctx delete ns "$NS" --ignore-not-found
  kubectl_ctx delete clusterqueue preemption-cq --ignore-not-found
  kubectl_ctx delete workloadpriorityclass pe-high pe-low --ignore-not-found
}
