#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="kai-gang"                         # namespace holding the gangs
QUEUES=(kai-gang-root kai-gang-queue)
QUEUE="kai-gang-queue"                # the capacity-capped queue (limit 32 GPUs)
GANG_SIZE=3                           # pods per gang (PodGroup minMember)
GPU_PER_POD=8                         # each pod holds one whole 8-GPU node
GANG_GPU=$((GANG_SIZE * GPU_PER_POD)) # 24 GPUs per gang
GANG1="gang-1"                        # fits: admitted all-or-nothing
GANG2="gang-2"                        # does not fully fit: stays fully Pending
QUEUES_YAML="$SCENARIO_DIR/manifests/queues.yaml"

describe() {
  echo "KAI explicit PodGroup: a ${GANG_SIZE}-pod gang is admitted all-or-nothing; a 2nd gang stays fully Pending even though one node is free (a partial gang can't run)"
}

# pre_run: install the KAI Scheduler (PodGroup is a KAI CRD).
pre_run() {
  install_kai
}

# Apply an explicit PodGroup (minMember=GANG_SIZE) plus its bare member pods.
# Rendered to a temp file and applied with retry so a freshly-installed KAI
# admission webhook that is not ready yet does not fail the submission.
_submit_gang() {
  local group="$1" prio="${2:-train}" f
  f="$(mktemp)"
  kai_podgroup_gang "$NS" "$group" "$QUEUE" "$GANG_SIZE" "$GANG_SIZE" "$GPU_PER_POD" "$prio" > "$f"
  apply_with_retry "$f" 12
  rm -f "$f"
}

apply() {
  step "Applying the KAI queues (kai-gang-queue: limit 32 GPUs = room for one gang + one spare node)"
  apply_with_retry "$QUEUES_YAML" 12

  step "Submitting gang '$GANG1' (explicit PodGroup, minMember ${GANG_SIZE}, ${GANG_GPU} GPUs)"
  _submit_gang "$GANG1"
  info "waiting for the whole gang to be admitted all-or-nothing (${GANG_SIZE} pods Running)..."
  wait_for_pods_phase "$GANG_SIZE" Running "$NS" "gpu-lab/gang=$GANG1" || true

  step "Submitting gang '$GANG2' (another ${GANG_GPU}-GPU gang - only 8 GPUs are free under the limit)"
  _submit_gang "$GANG2"
  info "waiting to confirm the gang stays fully Pending (all-or-nothing, no partial run)..."
  wait_for_pods_phase "$GANG_SIZE" Pending "$NS" "gpu-lab/gang=$GANG2" || true
}

# Pod table grouped by gang so it is obvious gang-1 is fully Running and gang-2 is
# fully Pending (never a partial mix).
_inspect_gang_pods() {
  local out
  out=$(kubectl_ctx get pods -n "$NS" -o custom-columns=\
'POD:.metadata.name,'\
'PHASE:.status.phase,'\
'GANG:.metadata.labels.gpu-lab/gang,'\
'NODE:.spec.nodeName' 2>/dev/null)
  if [ -z "$out" ]; then echo "    (none)"; return; fi
  { printf '%s\n' "$out" | head -n1
    printf '%s\n' "$out" | tail -n +2 | sort -k3,3 -k1,1
  } | sed 's/^/    /'
}

inspect() {
  echo "--- KAI PodGroups (the explicit gangs; MIN = minMember = all-or-nothing threshold) ---"
  kubectl_ctx get podgroups.scheduling.run.ai -n "$NS" \
    -o custom-columns='PODGROUP:.metadata.name,MIN:.spec.minMember,QUEUE:.spec.queue,PRIORITY:.spec.priorityClassName' \
    2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- KAI queue (limit 32 GPUs; gang-1 uses 24, leaving 8 = one idle node) ---"
  inspect_kai_queues "${QUEUES[@]}"
  echo
  echo "--- Pods by gang ('$GANG1' all Running, '$GANG2' all Pending) ---"
  _inspect_gang_pods
  echo
  info "'$GANG1' is an explicit PodGroup with minMember ${GANG_SIZE}: KAI admits it all-or-nothing"
  info "and all ${GANG_SIZE} pods run (${GANG_GPU} GPUs)."
  info "'$GANG2' wants another ${GANG_GPU} GPUs but only 8 (one node) are free under the queue limit."
  info "A single pod would fit that node - but a gang runs all-or-nothing, so KAI schedules"
  info "ZERO of '$GANG2''s pods. Raise the queue limit (or free a gang) to admit it as a whole."
}

cleanup() {
  kubectl_ctx delete namespace "$NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl_ctx delete -f "$QUEUES_YAML" --ignore-not-found >/dev/null 2>&1 || true
  uninstall_kai
}
