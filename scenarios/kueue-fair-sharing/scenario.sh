#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
# Two teams share one cohort. Each CQ nominally owns 32 GPUs (cohort total 64).
TEAM_A_NS="team-a";  TEAM_A_QUEUE="team-a-queue";  TEAM_A_CQ="team-a-cq"
TEAM_B_NS="team-b";  TEAM_B_QUEUE="team-b-queue";  TEAM_B_CQ="team-b-cq"
GPUS_PER_JOB=8       # each job claims a whole 8-GPU node
TEAM_A_JOBS=8        # 8 x 8 = 64 -> Team A tries to grab the whole cohort
TEAM_B_JOBS=4        # 4 x 8 = 32 -> Team B's fair share

describe() {
  echo "Fair sharing: Team A borrows the whole cohort, then Team B reclaims its fair share"
}

apply() {
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "Team A submits ${TEAM_A_JOBS} GPU jobs - borrows the whole 64-GPU cohort"
  submit_gpu_jobs "$TEAM_A_NS" "$TEAM_A_QUEUE" a "$TEAM_A_JOBS" "$GPUS_PER_JOB"
  info "letting Team A grab everything..."
  sleep 15

  step "Team B submits ${TEAM_B_JOBS} GPU jobs - fair sharing reclaims ~half from A"
  submit_gpu_jobs "$TEAM_B_NS" "$TEAM_B_QUEUE" b "$TEAM_B_JOBS" "$GPUS_PER_JOB"
  info "waiting for fair-share reclaim/preemption to settle..."
  sleep 25
}

inspect() {
  echo "=== Team A ==="; inspect_workloads "$TEAM_A_NS"
  echo
  echo "=== Team B ==="; inspect_workloads "$TEAM_B_NS"
  echo
  inspect_clusterqueue_usage "$TEAM_A_CQ"
  echo
  inspect_clusterqueue_usage "$TEAM_B_CQ"
  echo
  echo "Admitted workloads (each = ${GPUS_PER_JOB} GPUs):"
  printf "    Team A admitted: %s\n" "$(count_admitted "$TEAM_A_NS")"
  printf "    Team B admitted: %s\n" "$(count_admitted "$TEAM_B_NS")"
  info "Expect a roughly even split (~4 vs ~4) once B has reclaimed its share."
}

cleanup() {
  kubectl_ctx delete ns "$TEAM_A_NS" "$TEAM_B_NS" --ignore-not-found
  kubectl_ctx delete clusterqueue "$TEAM_A_CQ" "$TEAM_B_CQ" --ignore-not-found
}
