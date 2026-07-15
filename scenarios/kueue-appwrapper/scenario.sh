#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="appwrapper"              # namespace holding the AppWrappers
QUEUE="appwrapper-queue"     # LocalQueue the AppWrappers target
CQ="appwrapper-cq"           # ClusterQueue (nvidia.com/gpu: 16 = one AppWrapper)
NUM_AWS=2                    # 2 AppWrappers submitted; the GPU quota only fits one
GPU_PER_AW=16               # wrapped Job = 2 pods x 8 GPUs

describe() {
  echo "Kueue + AppWrapper: a whole AppWrapper (its wrapped resources) is gang-admitted under GPU quota; the 2nd stays Pending"
}

# pre_run: install the prerequisite AppWrapper operator before the run.
pre_run() {
  install_appwrapper
  # Kueue only starts its AppWrapper controller for CRDs that exist when the
  # Kueue controller boots. The AppWrapper operator (and its CRD) was just
  # installed, so restart the Kueue controller to activate the
  # workload.codeflare.dev/appwrapper integration.
  step "Restarting the Kueue controller so it picks up the AppWrapper CRD"
  kubectl_ctx -n kueue-system rollout restart deploy/kueue-controller-manager
  kubectl_ctx -n kueue-system rollout status deploy/kueue-controller-manager --timeout=180s
}

apply() {
  step "Applying AppWrapper queues (quota: nvidia.com/gpu = ${GPU_PER_AW} = one AppWrapper)"
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "Submitting ${NUM_AWS} AppWrappers (each wraps a Job of 2 pods x 8 GPUs = ${GPU_PER_AW} GPUs)"
  # AppWrappers use generateName, so create (not apply) each one; retry rides out
  # the Kueue/AppWrapper webhooks still settling after the controller restart.
  local i
  for i in $(seq 1 "$NUM_AWS"); do
    create_with_retry "$SCENARIO_DIR/manifests/appwrapper.yaml"
  done

  info "letting Kueue admit one AppWrapper and the operator create its wrapped Job/pods..."
  sleep 20
}

inspect() {
  echo "--- Workloads (one AppWrapper = one gang Workload) ---"
  inspect_workloads "$NS"
  echo
  inspect_clusterqueue_usage "$CQ"
  echo
  echo "--- AppWrappers ---"
  kubectl_ctx get appwrappers -n "$NS" \
    -o custom-columns='NAME:.metadata.name,SUSPEND:.spec.suspend,STATUS:.status.phase' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Wrapped Jobs (only the admitted AppWrapper has one) ---"
  kubectl_ctx get jobs -n "$NS" \
    -o custom-columns='NAME:.metadata.name,COMPLETIONS:.status.ready,SUSPEND:.spec.suspend' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Pods (of the admitted AppWrapper's wrapped Job) ---"
  kubectl_ctx get pods -n "$NS" \
    -o custom-columns='POD:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Why is the second AppWrapper pending? ---"
  show_first_pending_reason "$NS"
  echo
  info "Expect one AppWrapper Admitted (its wrapped Job's pods start, ${GPU_PER_AW} GPUs reserved)"
  info "and the second AppWrapper's Workload Pending on quota, with no wrapped Job created for it."
}

# # post_run: remove the AppWrapper operator that pre_run installed.
# post_run() {
#   step "Removing the AppWrappers and the AppWrapper operator"
#   kubectl_ctx delete appwrappers --all -n "$NS" --ignore-not-found
#   uninstall_appwrapper
# }

cleanup() {
  kubectl_ctx delete appwrappers --all -n "$NS" --ignore-not-found 2>/dev/null || true
  kubectl_ctx delete -f "$SCENARIO_DIR/manifests/queues.yaml" --ignore-not-found
  # Fallback in case post_run didn't run (e.g. cleaning after an interrupted run).
  uninstall_appwrapper
}
