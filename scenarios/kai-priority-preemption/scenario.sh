#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="kai-priority"                     # namespace holding the workloads
QUEUES=(priority-root priority-queue)
Q="priority-queue"                    # the single, capacity-1 queue
GPU_PER_JOB=8                         # each job is one whole 8-GPU node
QUEUE_LIMIT=16                        # queue holds exactly 2 jobs at a time
LOW_PRIO="train"                      # 50, preemptible
HIGH_PRIO="inference"                 # 125, non-preemptible, preempts lower
LOW_JOBS=$((QUEUE_LIMIT / GPU_PER_JOB))   # 2 low-priority jobs fill the queue
HIGH_JOBS=$((QUEUE_LIMIT / GPU_PER_JOB))  # 2 high-priority jobs arrive later
QUEUES_YAML="$SCENARIO_DIR/manifests/queues.yaml"

describe() {
  echo "KAI priority preemption: a full queue of '${LOW_PRIO}' jobs is preempted by higher-priority '${HIGH_PRIO}' jobs in the same queue"
}

# pre_run: install the KAI Scheduler (priority/preemption is a KAI feature).
pre_run() {
  install_kai
}

apply() {
  step "Applying the KAI queues (priority-queue: quota == limit == ${QUEUE_LIMIT} GPUs)"
  apply_with_retry "$QUEUES_YAML" 12

  step "Phase 1: submitting ${LOW_JOBS} '${LOW_PRIO}' jobs (${QUEUE_LIMIT} GPUs = fills the queue)"
  submit_kai_jobs "$NS" "$Q" "low" "$LOW_JOBS" "$GPU_PER_JOB" "$LOW_PRIO"
  info "waiting for the ${LOW_JOBS} '${LOW_PRIO}' pods to be Running..."
  wait_for_pods_phase "$LOW_JOBS" Running "$NS" "kai.scheduler/queue=$Q" || true

  step "Phase 2: submitting ${HIGH_JOBS} '${HIGH_PRIO}' jobs (queue is full - KAI must preempt)"
  submit_kai_jobs "$NS" "$Q" "high" "$HIGH_JOBS" "$GPU_PER_JOB" "$HIGH_PRIO"
  # KAI protects a freshly-started workload for a short minimum runtime before it
  # may be preempted, so the eviction takes ~1-2 min to fire here - wait patiently.
  # Select by the gpu-lab/priority label: both classes share the queue label, so
  # only the priority label distinguishes '${HIGH_PRIO}' from '${LOW_PRIO}'.
  info "waiting for KAI to preempt '${LOW_PRIO}' and admit '${HIGH_PRIO}' (can take ~1-2 min)..."
  wait_for_pods_phase "$HIGH_JOBS" Running "$NS" "gpu-lab/priority=$HIGH_PRIO" 150 || true
  # the preempted low-priority jobs are recreated by their Job controllers and
  # then sit Pending - wait for them so the contest shows.
  info "waiting for the preempted '${LOW_PRIO}' jobs to reappear as Pending..."
  wait_for_pods_phase "$LOW_JOBS" Pending "$NS" "gpu-lab/priority=$LOW_PRIO" 90 || true
}

inspect() {
  echo "--- KAI queue (quota == limit == ${QUEUE_LIMIT}, so no room without preemption) ---"
  inspect_kai_queues "${QUEUES[@]}"
  echo
  echo "--- Pods by priority ('${HIGH_PRIO}' Running, '${LOW_PRIO}' preempted -> Pending) ---"
  inspect_kai_pods "$NS"
  echo
  echo "--- KAI scheduling events (preemption of '${LOW_PRIO}' pods) ---"
  inspect_kai_events "$NS"
  echo
  info "The queue's quota == limit == ${QUEUE_LIMIT} GPUs, so it holds only ${LOW_JOBS} jobs at once."
  info "'${HIGH_PRIO}' (125) outranks '${LOW_PRIO}' (50), so KAI PREEMPTS the running '${LOW_PRIO}'"
  info "pods to make room for '${HIGH_PRIO}' in the same queue."
  info "The evicted '${LOW_PRIO}' jobs are recreated and wait Pending until GPUs free up."
}

cleanup() {
  kubectl_ctx delete namespace "$NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl_ctx delete -f "$QUEUES_YAML" --ignore-not-found >/dev/null 2>&1 || true
  uninstall_kai
}
