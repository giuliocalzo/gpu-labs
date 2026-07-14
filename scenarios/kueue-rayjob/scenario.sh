#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="rayjob"                 # namespace holding the RayJobs
QUEUE="rayjob-queue"        # LocalQueue the RayJobs target
CQ="rayjob-cq"              # ClusterQueue (nvidia.com/gpu: 8 = one Ray cluster)
NUM_JOBS=2                  # 2 RayJobs submitted; the GPU quota only fits one
GPU_QUOTA=8                 # nvidia.com/gpu quota in the ClusterQueue

describe() {
  echo "Kueue + RayJob: whole Ray clusters are gang-admitted under GPU quota; the 2nd RayJob stays Pending"
}

# Create one RayJob (generateName gives it a unique name). The Kueue rayjob
# webhook may still be settling right after the controller restart, so retry.
_create_rayjob() {
  local j
  for j in $(seq 1 12); do
    kubectl_ctx create -f "$SCENARIO_DIR/manifests/rayjob.yaml" && return 0
    info "Kueue rayjob webhook not ready yet, retrying in 5s (attempt $j/12)"
    sleep 5
  done
  die "failed to create RayJob"
}

# pre_run: install the prerequisite KubeRay operator before the scenario runs.
pre_run() {
  install_kuberay
  # Kueue only starts its RayJob controller for CRDs that exist when the Kueue
  # controller boots. KubeRay (and the Ray CRDs) was just installed, so restart
  # the Kueue controller to activate the ray.io/rayjob integration.
  step "Restarting the Kueue controller so it picks up the Ray CRDs"
  kubectl_ctx -n kueue-system rollout restart deploy/kueue-controller-manager
  kubectl_ctx -n kueue-system rollout status deploy/kueue-controller-manager --timeout=180s
}

apply() {
  step "Applying RayJob queues (quota: nvidia.com/gpu = ${GPU_QUOTA} = one Ray cluster)"
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "Submitting ${NUM_JOBS} RayJobs (each Ray cluster's worker needs ${GPU_QUOTA} GPUs)"
  local i
  for i in $(seq 1 "$NUM_JOBS"); do
    _create_rayjob
  done

  info "letting Kueue admit one Ray cluster and KubeRay create its pods..."
  info "(the rayproject/ray image is large; first pull can take a few minutes)"
  sleep 40
}

inspect() {
  echo "--- Workloads (one RayJob = one gang Workload) ---"
  inspect_workloads "$NS"
  echo
  inspect_clusterqueue_usage "$CQ"
  echo
  echo "--- RayJobs (deployment / job status) ---"
  kubectl_ctx get rayjobs -n "$NS" \
    -o custom-columns='NAME:.metadata.name,DEPLOYMENT:.status.jobDeploymentStatus,JOB:.status.jobStatus,SUSPEND:.spec.suspend' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- RayClusters (only the admitted RayJob has one) ---"
  kubectl_ctx get rayclusters -n "$NS" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Pods (head + worker of the admitted Ray cluster) ---"
  kubectl_ctx get pods -n "$NS" \
    -o custom-columns='POD:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Why is the second RayJob pending? ---"
  show_first_pending_reason "$NS"
  echo
  info "Expect one RayJob Admitted (its head+worker come up, ${GPU_QUOTA} GPUs reserved)"
  info "and the second RayJob's Workload Pending on quota, with no pods created for it."
}

# # post_run: remove the KubeRay operator that pre_run installed.
# post_run() {
#   step "Removing the RayJobs and the KubeRay operator"
#   kubectl_ctx delete rayjobs --all -n "$NS" --ignore-not-found
#   uninstall_kuberay
# }

cleanup() {
  kubectl_ctx delete rayjobs --all -n "$NS" --ignore-not-found 2>/dev/null || true
  kubectl_ctx delete -f "$SCENARIO_DIR/manifests/queues.yaml" --ignore-not-found
  # Fallback in case post_run didn't run (e.g. cleaning after an interrupted run).
  uninstall_kuberay
}
