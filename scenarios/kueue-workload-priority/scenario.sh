#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="priority"            # namespace holding the workloads
QUEUE="priority-queue"   # LocalQueue the jobs target
CQ="priority-cq"         # ClusterQueue backing that LocalQueue
GPUS_PER_JOB=8           # each job claims a whole 8-GPU node
JOBS_PER_TIER=4          # 4 low + 4 high; the 32-GPU quota fits only 4

describe() {
  echo "WorkloadPriorityClass: high-priority jobs admitted before low-priority when quota is scarce"
}

apply() {
  apply_with_retry "$SCENARIO_DIR/manifests/priorityclasses.yaml"
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  # The ClusterQueue starts with stopPolicy: Hold, so nothing is admitted while
  # we submit. All jobs pile up as pending first, so the outcome depends on
  # priority rather than on which job happened to be created first.
  step "Submitting ${JOBS_PER_TIER} low- + ${JOBS_PER_TIER} high-priority jobs (queue is Held)"
  submit_gpu_jobs "$NS" "$QUEUE" low  "$JOBS_PER_TIER" "$GPUS_PER_JOB" wp-low
  submit_gpu_jobs "$NS" "$QUEUE" high "$JOBS_PER_TIER" "$GPUS_PER_JOB" wp-high

  local total=$(( JOBS_PER_TIER * 2 ))
  info "waiting for all ${total} workloads to exist (all pending, queue is Held)..."
  wait_for_count "$total" workloads -n "$NS"

  # Releasing the queue lets Kueue admit. With quota for only JOBS_PER_TIER jobs,
  # it admits the high-priority ones first.
  step "Releasing the queue (stopPolicy: None) - Kueue admits high priority first"
  kubectl_ctx patch clusterqueue "$CQ" --type=merge -p '{"spec":{"stopPolicy":"None"}}'
  info "letting admission settle..."
  sleep 15
}

inspect() {
  inspect_workloads "$NS"
  echo
  inspect_clusterqueue_usage "$CQ"
  echo
  info "Expect the ${JOBS_PER_TIER} high-priority workloads Admitted=True and the low-priority ones pending."
}

cleanup() {
  kubectl_ctx delete ns "$NS" --ignore-not-found
  kubectl_ctx delete clusterqueue "$CQ" --ignore-not-found
  kubectl_ctx delete workloadpriorityclass wp-high wp-low --ignore-not-found
}
