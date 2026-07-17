#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="kai-reclaim"                      # namespace holding both teams' workloads
QUEUES=(reclaim-root reclaim-team-a reclaim-team-b)
QA="reclaim-team-a"                   # borrows the whole cluster first
QB="reclaim-team-b"                   # wakes up and reclaims its share
GPU_PER_JOB=8                         # each job is one whole 8-GPU node
TEAM_QUOTA=32                         # each team's guaranteed GPUs
A_JOBS=8                              # 64 GPUs = the whole cluster
B_JOBS=4                              # 32 GPUs = team-b's guaranteed quota
A_AFTER=$((TEAM_QUOTA / GPU_PER_JOB)) # team-a is reclaimed back down to its quota
QUEUES_YAML="$SCENARIO_DIR/manifests/queues.yaml"

describe() {
  echo "KAI reclaim: team-a borrows the whole cluster while team-b is idle; when team-b submits, KAI reclaims team-b's guaranteed ${TEAM_QUOTA} GPUs by evicting team-a's over-quota pods"
}

# pre_run: install the KAI Scheduler (reclaim is a KAI feature).
pre_run() {
  install_kai
}

apply() {
  step "Applying the KAI queue hierarchy (root -> team-a, team-b, each quota ${TEAM_QUOTA})"
  apply_with_retry "$QUEUES_YAML" 12

  step "Phase 1: team-a submits ${A_JOBS} jobs ($((A_JOBS * GPU_PER_JOB)) GPUs = the whole cluster) while team-b is idle"
  submit_kai_jobs "$NS" "$QA" "a" "$A_JOBS" "$GPU_PER_JOB"
  info "waiting for team-a to borrow the full cluster (${A_JOBS} pods Running)..."
  wait_for_pods_phase "$A_JOBS" Running "$NS" "kai.scheduler/queue=$QA" || true

  step "Phase 2: team-b submits ${B_JOBS} jobs ($((B_JOBS * GPU_PER_JOB)) GPUs = its guaranteed quota)"
  submit_kai_jobs "$NS" "$QB" "b" "$B_JOBS" "$GPU_PER_JOB"
  info "waiting for KAI to reclaim team-b's share (evict team-a over-quota pods)..."
  wait_for_pods_phase "$B_JOBS" Running "$NS" "kai.scheduler/queue=$QB" || true
  # team-a's evicted jobs are recreated by their Job controllers (after a short
  # backoff) and then sit Pending - wait for them so the contest is visible.
  info "waiting for team-a's reclaimed jobs to reappear as Pending..."
  wait_for_pods_phase "$((A_JOBS - A_AFTER))" Pending "$NS" "kai.scheduler/queue=$QA" || true
}

inspect() {
  echo "--- KAI queues (both settle at their ${TEAM_QUOTA}-GPU quota after reclaim) ---"
  inspect_kai_queues "${QUEUES[@]}"
  echo
  echo "--- Pods by queue (team-a: ${A_AFTER} Running + $((A_JOBS - A_AFTER)) Pending; team-b: ${B_JOBS} Running) ---"
  inspect_kai_pods "$NS"
  echo
  echo "--- KAI scheduling events (reclaim / eviction of team-a's over-quota pods) ---"
  inspect_kai_events "$NS"
  echo
  info "team-a first borrowed all 64 GPUs (its ${TEAM_QUOTA} quota + ${TEAM_QUOTA} over-quota)."
  info "When team-b submitted, KAI RECLAIMED team-b's guaranteed ${TEAM_QUOTA} GPUs by evicting"
  info "team-a's over-quota (preemptible) pods - but never below team-a's own ${TEAM_QUOTA}-GPU quota."
  info "Result: both teams sit at their guaranteed ${TEAM_QUOTA} GPUs; team-a's evicted jobs wait Pending."
}

cleanup() {
  kubectl_ctx delete namespace "$NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl_ctx delete -f "$QUEUES_YAML" --ignore-not-found >/dev/null 2>&1 || true
  uninstall_kai
}
