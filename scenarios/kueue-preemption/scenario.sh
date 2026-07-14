#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="preemption"             # namespace holding the workloads
QUEUE="preemption-queue"    # LocalQueue the jobs target
CQ="preemption-cq"          # ClusterQueue (nvidia.com/gpu: 32)
GPUS_PER_JOB=8              # each job claims a whole 8-GPU node
LOW_JOBS=4                 # 4 x 8 = 32 GPUs -> fills the quota
HIGH_JOBS=2                # must preempt LOW jobs to be admitted

describe() {
  echo "Preemption: running low-priority jobs are evicted to make room for high-priority ones"
}

# Poll until at least <count> workloads in the namespace are Admitted.
_wait_for_admitted() {
  local want="$1" attempt
  for attempt in $(seq 1 30); do
    [ "$(count_admitted "$NS")" -ge "$want" ] && return 0
    sleep 2
  done
}

apply() {
  apply_with_retry "$SCENARIO_DIR/manifests/priorityclasses.yaml"
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "Filling the queue with ${LOW_JOBS} low-priority jobs (${LOW_JOBS} x ${GPUS_PER_JOB} = full 32-GPU quota)"
  submit_gpu_jobs "$NS" "$QUEUE" low "$LOW_JOBS" "$GPUS_PER_JOB" pe-low
  info "waiting for the ${LOW_JOBS} low-priority jobs to be admitted..."
  _wait_for_admitted "$LOW_JOBS"

  step "Submitting ${HIGH_JOBS} high-priority jobs - Kueue must preempt low-priority ones"
  submit_gpu_jobs "$NS" "$QUEUE" high "$HIGH_JOBS" "$GPUS_PER_JOB" pe-high
  info "waiting for preemption to happen..."
  sleep 25
}

inspect() {
  inspect_workloads "$NS"
  echo
  inspect_clusterqueue_usage "$CQ"
  echo
  echo "--- Preempted workloads (evicted to make room) ---"
  kubectl_ctx get events -n "$NS" --field-selector reason=Preempted \
    -o custom-columns='WORKLOAD:.involvedObject.name,MESSAGE:.message' 2>/dev/null \
    | sed 's/ due to.*//' | sed 's/^/    /' || true
  echo
  info "Expect ${HIGH_JOBS} high-priority workloads Admitted=True and ${HIGH_JOBS} low-priority ones evicted/pending."
}

cleanup() {
  kubectl_ctx delete ns "$NS" --ignore-not-found
  kubectl_ctx delete clusterqueue "$CQ" --ignore-not-found
  kubectl_ctx delete workloadpriorityclass pe-high pe-low --ignore-not-found
}
