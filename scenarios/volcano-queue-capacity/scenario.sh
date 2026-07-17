#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="volcano-queue"                    # namespace holding both teams' jobs
QA="vol-queue-a"                      # borrows the whole cluster first
QB="vol-queue-b"                      # wakes up and reclaims its deserved share
GPU_PER_JOB=8                         # each job is one whole 8-GPU node
DESERVED=32                           # each queue's deserved (fair-share) GPUs
A_JOBS=8                              # 64 GPUs = the whole cluster
B_JOBS=4                              # 32 GPUs = team-b's deserved
A_AFTER=$((DESERVED / GPU_PER_JOB))   # team-a is reclaimed back down to deserved
SCHED_CONF="$SCENARIO_DIR/manifests/scheduler.conf"
QUEUES_YAML="$SCENARIO_DIR/manifests/queues.yaml"

# Volcano job resource (full name avoids short-name clashes with other CRDs).
VCJOB_KIND="jobs.batch.volcano.sh"

describe() {
  echo "Volcano queue capacity: team-a borrows the whole cluster while team-b is idle; when team-b submits, Volcano reclaims team-b's deserved ${DESERVED} GPUs from team-a's over-deserved jobs"
}

# pre_run: install Volcano and switch its scheduler to a config that enables the
# reclaim action and the capacity plugin (both off in the default config).
pre_run() {
  install_volcano
  configure_volcano_scheduler "$SCHED_CONF"
}

apply() {
  step "Creating the Volcano queues (deserved ${DESERVED} GPUs each, capability 64, reclaimable)"
  apply_with_retry "$QUEUES_YAML" 12

  # Volcano Job specs are immutable (only minAvailable/replicas/priorityClassName
  # may change), so re-running would fail on apply. Recreate from scratch for a
  # deterministic starting state.
  kubectl_ctx delete "$VCJOB_KIND" --all -n "$NS" --ignore-not-found >/dev/null 2>&1 || true

  step "Phase 1: team-a submits ${A_JOBS} jobs ($((A_JOBS * GPU_PER_JOB)) GPUs = the whole cluster) while team-b is idle"
  submit_volcano_jobs "$NS" "$QA" "a" "$A_JOBS" "$GPU_PER_JOB"
  info "waiting for team-a to borrow the full cluster (${A_JOBS} pods Running)..."
  wait_for_pods_phase "$A_JOBS" Running "$NS" "volcano.sh/queue-name=$QA" || true

  step "Phase 2: team-b submits ${B_JOBS} jobs ($((B_JOBS * GPU_PER_JOB)) GPUs = its deserved share)"
  submit_volcano_jobs "$NS" "$QB" "b" "$B_JOBS" "$GPU_PER_JOB"
  info "waiting for Volcano to reclaim team-b's deserved share (evict team-a over-deserved jobs)..."
  wait_for_volcano_pg_phase "$B_JOBS" Running "$NS" "$QB" 90 || true
  # After reclaim, team-a is left with exactly its deserved share Running and the
  # rest waiting; PodGroups reflect this reliably.
  info "waiting for team-a to settle at its deserved ${DESERVED} GPUs (${A_AFTER} gangs Running)..."
  local i
  for i in $(seq 1 90); do
    [ "$(kubectl_ctx get podgroups.scheduling.volcano.sh -n "$NS" \
        -o jsonpath="{range .items[?(@.spec.queue=='$QA')]}{.status.phase}{'\n'}{end}" 2>/dev/null \
        | grep -c '^Running$')" -le "$A_AFTER" ] && break
    sleep 2
  done
}

inspect() {
  echo "--- Volcano queues (deserved = fair share, capability = hard cap, allocated = live) ---"
  inspect_volcano_queues "$QA" "$QB"
  echo
  echo "--- PodGroups per job (team-a: ${A_AFTER} Running + $((A_JOBS - A_AFTER)) waiting; team-b: ${B_JOBS} Running) ---"
  inspect_volcano_podgroups "$NS"
  echo
  echo "--- Running pods & their nodes (admitted work only) ---"
  kubectl_ctx get pods -n "$NS" --field-selector=status.phase=Running -o custom-columns=\
'POD:.metadata.name,'\
'QUEUE:.metadata.labels.volcano\.sh/queue-name,'\
'NODE:.spec.nodeName' 2>/dev/null \
    | { read -r h; echo "$h"; sort -k2,2; } | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Reclaim / eviction events ---"
  local out
  out=$(kubectl_ctx get events -n "$NS" --sort-by=.lastTimestamp 2>/dev/null \
    | grep -Ei 'evict|reclaim|preempt' | tail -n 12 || true)
  [ -n "$out" ] && echo "$out" | sed 's/^/    /' || echo "    (no reclaim events in window)"
  echo
  info "team-a first borrowed all 64 GPUs (its ${DESERVED} deserved + ${DESERVED} over-deserved)."
  info "When team-b submitted, Volcano's reclaim action evicted team-a's OVER-DESERVED jobs"
  info "to give team-b its deserved ${DESERVED} GPUs - but never below team-a's own deserved ${DESERVED}."
  info "Both queues settle at their deserved ${DESERVED} GPUs; team-a's evicted jobs wait Pending."
}

cleanup() {
  kubectl_ctx delete "$VCJOB_KIND" --all -n "$NS" --ignore-not-found 2>/dev/null || true
  kubectl_ctx delete namespace "$NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl_ctx delete -f "$QUEUES_YAML" --ignore-not-found >/dev/null 2>&1 || true
  uninstall_volcano
}
