#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
# One cohort, two ClusterQueues. borrow-a is the borrower, borrow-b the (idle)
# lender. Each nominally owns 16 GPUs; borrow-a may borrow 16 more (ceiling 32).
BORROWER_NS="borrow-a";  BORROWER_QUEUE="borrow-a-queue";  BORROWER_CQ="borrow-a-cq"
LENDER_NS="borrow-b";    LENDER_CQ="borrow-b-cq"

GPUS_PER_JOB=8           # each job claims a whole 8-GPU node
NOMINAL_GPUS=16          # borrow-a's own quota (2 jobs)
BORROWING_LIMIT=16       # extra GPUs borrow-a may take from the cohort (2 jobs)
CEILING_GPUS=$(( NOMINAL_GPUS + BORROWING_LIMIT ))   # 32 GPUs = 4 jobs
EXPECT_ADMITTED=$(( CEILING_GPUS / GPUS_PER_JOB ))   # 4
BORROWER_JOBS=5          # 5 x 8 = 40 GPUs requested -> 1 job over the ceiling

describe() {
  echo "Borrowing/lending: one queue borrows an idle peer's quota up to borrowingLimit, no further"
}

apply() {
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "borrow-a submits ${BORROWER_JOBS} GPU jobs (${BORROWER_JOBS}x${GPUS_PER_JOB}=$(( BORROWER_JOBS * GPUS_PER_JOB )) GPUs); borrow-b stays idle"
  submit_gpu_jobs "$BORROWER_NS" "$BORROWER_QUEUE" a "$BORROWER_JOBS" "$GPUS_PER_JOB"
  info "waiting for admission to settle (borrow up to the ${CEILING_GPUS}-GPU ceiling)..."
  sleep 15
}

inspect() {
  inspect_workloads "$BORROWER_NS"
  echo
  inspect_clusterqueue_usage "$BORROWER_CQ"
  echo
  inspect_clusterqueue_usage "$LENDER_CQ"
  echo
  printf "    borrow-a admitted: %s / %s jobs (ceiling %s GPUs = nominal %s + borrow %s)\n" \
    "$(count_admitted "$BORROWER_NS")" "$BORROWER_JOBS" "$CEILING_GPUS" "$NOMINAL_GPUS" "$BORROWING_LIMIT"
  echo
  echo "First blocked workload's reason:"
  show_first_pending_reason "$BORROWER_NS"
  echo
  info "Expect ${EXPECT_ADMITTED} admitted (${CEILING_GPUS} GPUs) and 1 Pending: borrow-a hit its"
  info "borrowingLimit. The cluster still has free GPUs and borrow-b is idle, but"
  info "the limit - not capacity - caps how much a queue can borrow."
}

cleanup() {
  kubectl_ctx delete ns "$BORROWER_NS" "$LENDER_NS" --ignore-not-found
  kubectl_ctx delete clusterqueue "$BORROWER_CQ" "$LENDER_CQ" --ignore-not-found
}
