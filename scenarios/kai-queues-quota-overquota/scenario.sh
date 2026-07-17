#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="kai-quota"                        # namespace holding the workloads
QUEUES=(quota-root quota-team-a quota-team-b)
QA="quota-team-a"                     # the active queue we submit to
GPU_PER_JOB=8                         # each job is one whole 8-GPU node
NUM_JOBS=5                            # jobs submitted to team-a = 40 GPUs wanted
A_QUOTA=16                            # team-a guaranteed share (GPUs)
A_LIMIT=32                            # team-a hard cap (quota + over-quota)
EXPECT_RUNNING=$((A_LIMIT / GPU_PER_JOB))   # 4 jobs fit under the 32-GPU limit
EXPECT_PENDING=$((NUM_JOBS - EXPECT_RUNNING))
QUEUES_YAML="$SCENARIO_DIR/manifests/queues.yaml"

describe() {
  echo "KAI quotas & over-quota: team-a (quota ${A_QUOTA}, limit ${A_LIMIT}) borrows idle GPUs past its quota, but its hard limit caps it below cluster capacity"
}

# pre_run: install the KAI Scheduler (queues + over-quota are KAI features).
pre_run() {
  install_kai
}

apply() {
  step "Applying the KAI queue hierarchy (root -> team-a, team-b)"
  apply_with_retry "$QUEUES_YAML" 12

  step "Submitting ${NUM_JOBS} jobs to '$QA' (${GPU_PER_JOB} GPUs each = $((NUM_JOBS * GPU_PER_JOB)) GPUs wanted)"
  submit_kai_jobs "$NS" "$QA" "a" "$NUM_JOBS" "$GPU_PER_JOB"

  info "waiting for KAI to admit up to team-a's ${A_LIMIT}-GPU limit (${EXPECT_RUNNING} jobs)..."
  wait_for_pods_phase "$EXPECT_RUNNING" Running "$NS" "kai.scheduler/queue=$QA" || true
  # the over-limit job stays Pending (capped by the queue limit) - wait for it.
  wait_for_pods_phase "$EXPECT_PENDING" Pending "$NS" "kai.scheduler/queue=$QA" || true
}

inspect() {
  echo "--- KAI queues (quota = guaranteed, limit = hard cap, alloc = live usage) ---"
  inspect_kai_queues "${QUEUES[@]}"
  echo
  echo "--- Jobs submitted to '$QA' ---"
  kubectl_ctx get jobs -n "$NS" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Pods (${EXPECT_RUNNING} Running up to the limit, ${EXPECT_PENDING} Pending above it) ---"
  inspect_kai_pods "$NS"
  echo
  info "team-a's quota is ${A_QUOTA} GPUs, yet KAI admits ${A_LIMIT} GPUs (${EXPECT_RUNNING} jobs):"
  info "the extra $((A_LIMIT - A_QUOTA)) GPUs are OVER-QUOTA, borrowed from idle team-b/cluster capacity."
  info "The ${EXPECT_PENDING} remaining job(s) stay Pending: team-a's hard limit (${A_LIMIT}) caps it"
  info "even though the cluster still has free GPUs. Raise team-a's limit to admit more."
}

cleanup() {
  kubectl_ctx delete namespace "$NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl_ctx delete -f "$QUEUES_YAML" --ignore-not-found >/dev/null 2>&1 || true
  uninstall_kai
}
