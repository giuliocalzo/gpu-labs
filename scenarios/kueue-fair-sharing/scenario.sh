#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

describe() { echo "Fair sharing: Team A borrows the whole cohort, then Team B reclaims its fair share"; }

apply() {
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "Team A submits 8 GPU jobs (8x8=64) - borrows the whole 64-GPU cohort"
  { for i in 1 2 3 4 5 6 7 8; do gpu_job team-a team-a-queue "a-$i" 8; done; } \
    | kubectl_ctx apply -f -
  info "letting Team A grab everything..."
  sleep 15

  step "Team B submits 4 GPU jobs (4x8=32) - fair sharing reclaims ~half from A"
  { for i in 1 2 3 4; do gpu_job team-b team-b-queue "b-$i" 8; done; } \
    | kubectl_ctx apply -f -
  info "waiting for fair-share reclaim/preemption to settle..."
  sleep 25
}

inspect() {
  echo "=== Team A ==="; inspect_workloads team-a
  echo; echo "=== Team B ==="; inspect_workloads team-b
  echo; inspect_clusterqueue_usage team-a-cq
  echo; inspect_clusterqueue_usage team-b-cq
  echo
  echo "Admitted workloads (each = 8 GPUs):"
  printf "    team-a admitted: %s\n" "$(count_admitted team-a)"
  printf "    team-b admitted: %s\n" "$(count_admitted team-b)"
  info "Expect a roughly even split (~4 vs ~4) once B has reclaimed its share."
}

cleanup() {
  kubectl_ctx delete ns team-a team-b --ignore-not-found
  kubectl_ctx delete clusterqueue team-a-cq team-b-cq --ignore-not-found
}
