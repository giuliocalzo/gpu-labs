#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="partial-admission"     # namespace holding the Job
QUEUE="partial-queue"      # LocalQueue the Job targets
CQ="partial-cq"            # ClusterQueue (nvidia.com/gpu: 40 = 5 pods)
JOB="partial"              # the Job's name

GPU_PER_POD=8                                  # each pod claims a whole 8-GPU node
REQUESTED_PARALLELISM=8                         # 8 x 8 = 64 GPUs requested
MIN_PARALLELISM=2                               # Kueue may shrink no smaller than this
GPU_QUOTA=40                                    # ClusterQueue quota
EXPECT_PARALLELISM=$(( GPU_QUOTA / GPU_PER_POD ))   # 5 pods fit

describe() {
  echo "Partial admission: a Job that wants more GPUs than fit is admitted at a reduced parallelism instead of staying Pending"
}

# _job_parallelism - the Job's current spec.parallelism (Kueue patches this down
# to the admitted count on partial admission).
_job_parallelism() {
  kubectl_ctx get job "$JOB" -n "$NS" -o jsonpath='{.spec.parallelism}' 2>/dev/null || echo "?"
}

apply() {
  step "Applying queues (quota: nvidia.com/gpu = ${GPU_QUOTA} = ${EXPECT_PARALLELISM} pods)"
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "Submitting a Job: parallelism ${REQUESTED_PARALLELISM} x ${GPU_PER_POD} GPU = $(( REQUESTED_PARALLELISM * GPU_PER_POD )) GPU (min-parallelism ${MIN_PARALLELISM})"
  apply_with_retry "$SCENARIO_DIR/manifests/job.yaml"

  info "letting Kueue partially admit the Job (shrink to fit ${GPU_QUOTA} GPUs) and start its pods..."
  local i
  for i in $(seq 1 30); do
    [ "$(count_admitted "$NS")" -ge 1 ] && break
    sleep 2
  done
  sleep 5
}

inspect() {
  echo "--- Workload (admitted at reduced size) ---"
  inspect_workloads "$NS"
  echo
  inspect_clusterqueue_usage "$CQ"
  echo
  echo "--- Job parallelism: requested vs admitted ---"
  printf "    requested parallelism: %s (%s GPU)\n" "$REQUESTED_PARALLELISM" "$(( REQUESTED_PARALLELISM * GPU_PER_POD ))"
  printf "    min parallelism:       %s\n" "$MIN_PARALLELISM"
  printf "    current parallelism:   %s (Kueue shrank it to fit %s GPU)\n" "$(_job_parallelism)" "$GPU_QUOTA"
  echo
  echo "--- Pods (one per admitted parallel slot) ---"
  kubectl_ctx get pods -n "$NS" \
    -o custom-columns='POD:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  info "Expect the Job Admitted with parallelism ${EXPECT_PARALLELISM} (not ${REQUESTED_PARALLELISM}): Kueue shrank it"
  info "to the largest size that fits the ${GPU_QUOTA}-GPU quota, so ${EXPECT_PARALLELISM} pods run instead of the"
  info "whole Job staying Pending. ${CQ} shows nvidia.com/gpu=${GPU_QUOTA} fully reserved."
}

cleanup() {
  kubectl_ctx delete ns "$NS" --ignore-not-found
  kubectl_ctx delete clusterqueue "$CQ" --ignore-not-found
}
