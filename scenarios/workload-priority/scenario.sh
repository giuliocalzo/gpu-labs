#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

NS="priority"

describe() { echo "WorkloadPriorityClass: high-priority jobs admitted before low-priority when quota is scarce"; }

apply() {
  apply_with_retry "$SCENARIO_DIR/manifests/priorityclasses.yaml"
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "Submitting 4 low + 4 high priority jobs while the queue is Held (quota only fits 4 x 8 GPUs)"
  { for i in 1 2 3 4; do gpu_job "$NS" priority-queue "low-$i"  8 wp-low;  done
    for i in 1 2 3 4; do gpu_job "$NS" priority-queue "high-$i" 8 wp-high; done; } \
    | kubectl_ctx apply -f -
  info "waiting for all 8 workloads to be created (all pending, queue is Held)..."
  wait_for_count 8 workloads -n "$NS"

  step "Releasing the queue - Kueue now admits strictly by priority (high before low)"
  kubectl_ctx patch clusterqueue priority-cq --type=merge -p '{"spec":{"stopPolicy":"None"}}'
  info "letting admission settle..."
  sleep 15
}

inspect() {
  inspect_workloads "$NS"
  echo; inspect_clusterqueue_usage "priority-cq"
  echo
  info "Expect the 4 high-priority workloads Admitted=True and the 4 low-priority ones pending."
}

cleanup() {
  kubectl_ctx delete ns "$NS" --ignore-not-found
  kubectl_ctx delete clusterqueue priority-cq --ignore-not-found
  kubectl_ctx delete workloadpriorityclass wp-high wp-low --ignore-not-found
}
