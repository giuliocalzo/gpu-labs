#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="jobset"                # namespace holding the JobSets
QUEUE="jobset-queue"       # LocalQueue the JobSets target
CQ="jobset-cq"             # ClusterQueue (nvidia.com/gpu: 16 = one JobSet)
NUM_JOBSETS=2              # 2 JobSets submitted; the GPU quota only fits one
GPU_PER_JOBSET=16          # 2 worker Jobs x 8 GPUs each

describe() {
  echo "Kueue + JobSet: a whole JobSet (all its child Jobs) is gang-admitted under GPU quota; the 2nd JobSet stays Pending"
}

# Create one JobSet (generateName gives it a unique name). The Kueue jobset
# webhook may still be settling right after the controller restart, so retry.
_create_jobset() {
  local j
  for j in $(seq 1 12); do
    kubectl_ctx create -f "$SCENARIO_DIR/manifests/jobset.yaml" && return 0
    info "Kueue jobset webhook not ready yet, retrying in 5s (attempt $j/12)"
    sleep 5
  done
  die "failed to create JobSet"
}

# pre_run: install the prerequisite JobSet operator before the scenario runs.
pre_run() {
  install_jobset
  # Kueue only starts its JobSet controller for CRDs that exist when the Kueue
  # controller boots. JobSet was just installed, so restart the Kueue controller
  # to activate the jobset.x-k8s.io/jobset integration.
  step "Restarting the Kueue controller so it picks up the JobSet CRD"
  kubectl_ctx -n kueue-system rollout restart deploy/kueue-controller-manager
  kubectl_ctx -n kueue-system rollout status deploy/kueue-controller-manager --timeout=180s
}

apply() {
  step "Applying JobSet queues (quota: nvidia.com/gpu = ${GPU_PER_JOBSET} = one JobSet)"
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "Submitting ${NUM_JOBSETS} JobSets (each = 2 worker Jobs x 8 GPUs = ${GPU_PER_JOBSET} GPUs)"
  local i
  for i in $(seq 1 "$NUM_JOBSETS"); do
    _create_jobset
  done

  info "letting Kueue admit one JobSet and JobSet create its child Jobs/pods..."
  sleep 20
}

inspect() {
  echo "--- Workloads (one JobSet = one gang Workload) ---"
  inspect_workloads "$NS"
  echo
  inspect_clusterqueue_usage "$CQ"
  echo
  echo "--- JobSets ---"
  kubectl_ctx get jobsets -n "$NS" \
    -o custom-columns='NAME:.metadata.name,SUSPEND:.spec.suspend,RESTARTS:.status.restarts' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Child Jobs (only the admitted JobSet has them) ---"
  kubectl_ctx get jobs -n "$NS" \
    -o custom-columns='NAME:.metadata.name,COMPLETIONS:.status.ready,SUSPEND:.spec.suspend' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Pods (workers of the admitted JobSet) ---"
  kubectl_ctx get pods -n "$NS" \
    -o custom-columns='POD:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Why is the second JobSet pending? ---"
  show_first_pending_reason "$NS"
  echo
  info "Expect one JobSet Admitted (both its worker Jobs start, ${GPU_PER_JOBSET} GPUs reserved)"
  info "and the second JobSet's Workload Pending on quota, with no child Jobs created for it."
}

# post_run: remove the JobSet operator that pre_run installed.
post_run() {
  step "Removing the JobSets and the JobSet operator"
  kubectl_ctx delete jobsets --all -n "$NS" --ignore-not-found
  uninstall_jobset
}

cleanup() {
  kubectl_ctx delete jobsets --all -n "$NS" --ignore-not-found 2>/dev/null || true
  kubectl_ctx delete -f "$SCENARIO_DIR/manifests/queues.yaml" --ignore-not-found
  # Fallback in case post_run didn't run (e.g. cleaning after an interrupted run).
  uninstall_jobset
}
