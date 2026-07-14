#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="volcano-gang"            # namespace holding the workloads
QUEUE="volcano-demo"         # the Volcano Queue the jobs target
QUEUE_FILE="$SCENARIO_DIR/manifests/queue.yaml"
JOBS_FILE="$SCENARIO_DIR/manifests/jobs.yaml"

JOB_COUNT=2                  # training-a + training-b
TASKS_PER_JOB=2             # worker replicas per job (the gang size)
JOB_GPUS=8                   # GPUs per pod (a whole fake node)
GANG_GPUS=$(( TASKS_PER_JOB * JOB_GPUS ))   # 16 GPUs = one job's gang
POD_COUNT=$(( JOB_COUNT * TASKS_PER_JOB ))  # 4 pods total

# Volcano custom resources (full names avoid short-name alias clashes).
VCJOB_KIND="jobs.batch.volcano.sh"
QUEUE_KIND="queues.scheduling.volcano.sh"
PODGROUP_KIND="podgroups.scheduling.volcano.sh"

describe() {
  echo "Volcano: gang-schedule a job group all-or-nothing; a 2nd gang waits on queue capacity"
}

# pre_run: install the Volcano scheduler + CRDs (not part of the base install).
pre_run() {
  install_volcano
}

# _running_pods - number of pods currently in phase Running in the namespace.
_running_pods() {
  kubectl_ctx get pods -n "$NS" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -c . || true
}

apply() {
  step "Creating the Volcano Queue '$QUEUE' (capped at ${GANG_GPUS} GPUs = one gang)"
  apply_with_retry "$QUEUE_FILE" 12

  step "Submitting ${JOB_COUNT} Volcano Jobs (each a ${TASKS_PER_JOB}-pod / ${GANG_GPUS}-GPU gang)"
  # Volcano Job specs are immutable (only minAvailable/replicas/priorityClassName
  # can change), so `apply` fails on a re-run. Recreate the jobs from scratch for
  # a deterministic starting state. `kubectl delete` waits for finalization.
  kubectl_ctx delete "$VCJOB_KIND" --all -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
  apply_with_retry "$JOBS_FILE" 12

  info "waiting for Volcano to create a PodGroup per job..."
  wait_for_count "$JOB_COUNT" "$PODGROUP_KIND" -n "$NS"

  info "waiting for one gang (${TASKS_PER_JOB} pods) to be admitted and Running..."
  local i
  for i in $(seq 1 60); do
    [ "$(_running_pods)" -ge "$TASKS_PER_JOB" ] && break
    sleep 2
  done
}

inspect() {
  echo "--- Volcano Queue (capacity gate) ---"
  kubectl_ctx get "$QUEUE_KIND" "$QUEUE" \
    -o custom-columns='NAME:.metadata.name,STATE:.status.state,CAP-GPU:.spec.capability.nvidia\.com/gpu' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- PodGroups (one per job; Running = gang admitted, Inqueue/Pending = waiting) ---"
  kubectl_ctx get "$PODGROUP_KIND" -n "$NS" \
    -o custom-columns='NAME:.metadata.name,MINMEMBER:.spec.minMember,PHASE:.status.phase' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Volcano Jobs ---"
  kubectl_ctx get "$VCJOB_KIND" -n "$NS" \
    -o custom-columns='NAME:.metadata.name,QUEUE:.spec.queue,MIN:.spec.minAvailable,PHASE:.status.state.phase,RUNNING:.status.running' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Pods (only the admitted gang has pods; the waiting gang has none yet) ---"
  kubectl_ctx get pods -n "$NS" \
    -o custom-columns='POD:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName' 2>/dev/null \
    | sed 's/^/    /'
  echo
  info "Gang scheduling: Volcano admits a whole job (both worker pods) at once, or"
  info "not at all - you never see one worker Running while its partner is Pending."
  info "Queue capacity (${GANG_GPUS} GPUs) admits exactly one gang; the second job's"
  info "PodGroup stays Pending and Volcano creates no pods for it, even though the"
  info "cluster still has free GPUs."
}

# # post_run: uninstall the Volcano scheduler this scenario installed.
# post_run() {
#   step "Removing the Volcano Jobs and the Volcano scheduler"
#   kubectl_ctx delete "$VCJOB_KIND" --all -n "$NS" --ignore-not-found
#   uninstall_volcano
# }

cleanup() {
  kubectl_ctx delete "$VCJOB_KIND" --all -n "$NS" --ignore-not-found 2>/dev/null || true
  kubectl_ctx delete -f "$QUEUE_FILE" --ignore-not-found
  uninstall_volcano
}
