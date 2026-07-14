#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="training"              # namespace holding the TrainJobs
QUEUE="training-queue"     # LocalQueue the TrainJobs target
CQ="training-cq"           # ClusterQueue (nvidia.com/gpu: 16 = one TrainJob)
NUM_JOBS=2                 # 2 TrainJobs submitted; the GPU quota only fits one
GPU_PER_JOB=16             # 2 training nodes x 8 GPUs each

describe() {
  echo "Kueue + Kubeflow Trainer (TrainJob): a whole TrainJob (all its nodes) is gang-admitted under GPU quota; the 2nd stays Pending"
}

# pre_run: install the prerequisite Kubeflow Trainer before the run.
pre_run() {
  install_kubeflow_trainer
  # Kueue only starts its TrainJob controller for CRDs that exist when the Kueue
  # controller boots. Kubeflow Trainer (and the trainer.kubeflow.org CRDs) was
  # just installed, so restart the Kueue controller to activate the
  # trainer.kubeflow.org/trainjob integration.
  step "Restarting the Kueue controller so it picks up the Trainer CRDs"
  kubectl_ctx -n kueue-system rollout restart deploy/kueue-controller-manager
  kubectl_ctx -n kueue-system rollout status deploy/kueue-controller-manager --timeout=180s
}

apply() {
  step "Applying the ClusterTrainingRuntime the TrainJobs reference"
  apply_with_retry "$SCENARIO_DIR/manifests/runtime.yaml"

  step "Applying TrainJob queues (quota: nvidia.com/gpu = ${GPU_PER_JOB} = one TrainJob)"
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "Submitting ${NUM_JOBS} TrainJobs (each = 2 nodes x 8 GPUs = ${GPU_PER_JOB} GPUs)"
  # TrainJobs use generateName, so create (not apply) each one; retry rides out
  # the Kueue/Trainer webhooks still settling after the controller restart.
  local i
  for i in $(seq 1 "$NUM_JOBS"); do
    create_with_retry "$SCENARIO_DIR/manifests/trainjob.yaml"
  done

  info "letting Kueue admit one TrainJob and the trainer create its pods..."
  sleep 20
}

inspect() {
  echo "--- Workloads (one TrainJob = one gang Workload) ---"
  inspect_workloads "$NS"
  echo
  inspect_clusterqueue_usage "$CQ"
  echo
  echo "--- TrainJobs ---"
  kubectl_ctx get trainjobs -n "$NS" \
    -o custom-columns='NAME:.metadata.name,SUSPEND:.spec.suspend,STATE:.status.conditions[?(@.type=="Suspended")].reason' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Pods (training nodes of the admitted TrainJob) ---"
  kubectl_ctx get pods -n "$NS" \
    -o custom-columns='POD:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Why is the second TrainJob pending? ---"
  show_first_pending_reason "$NS"
  echo
  info "Expect one TrainJob Admitted (its 2 node pods start, ${GPU_PER_JOB} GPUs reserved)"
  info "and the second TrainJob's Workload Pending on quota, with no pods created for it."
}

# # post_run: remove Kubeflow Trainer that pre_run installed.
# post_run() {
#   step "Removing the TrainJobs and Kubeflow Trainer"
#   kubectl_ctx delete trainjobs --all -n "$NS" --ignore-not-found
#   uninstall_kubeflow_trainer
# }

cleanup() {
  kubectl_ctx delete trainjobs --all -n "$NS" --ignore-not-found 2>/dev/null || true
  kubectl_ctx delete -f "$SCENARIO_DIR/manifests/runtime.yaml" --ignore-not-found 2>/dev/null || true
  kubectl_ctx delete -f "$SCENARIO_DIR/manifests/queues.yaml" --ignore-not-found
  # Fallback in case post_run didn't run (e.g. cleaning after an interrupted run).
  uninstall_kubeflow_trainer
}
