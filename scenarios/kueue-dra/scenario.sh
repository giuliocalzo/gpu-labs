#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="dra"                    # namespace holding the workloads
QUEUE="dra-local-queue"     # LocalQueue the jobs target
CQ="dra-cluster-queue"      # ClusterQueue backing that LocalQueue
DRIVER_NS="dra-driver"      # namespace for the DRA example driver
GPU_QUOTA=4                 # nvidia.com/gpu quota in the ClusterQueue (see queues.yaml)
NUM_JOBS=6                  # 1-GPU jobs submitted; only GPU_QUOTA of them fit

describe() {
  echo "Dynamic Resource Allocation: claim-based GPU devices put under Kueue quota"
}

_resourceslice_count() {
  kubectl_ctx get resourceslices --no-headers 2>/dev/null | wc -l | tr -d ' '
}

# _dra_job <name> - a suspended Job whose pod claims 1 GPU via the DRA template.
_dra_job() {
  cat <<EOF
---
apiVersion: batch/v1
kind: Job
metadata:
  name: $1
  namespace: $NS
  labels:
    kueue.x-k8s.io/queue-name: $QUEUE
spec:
  suspend: true
  parallelism: 1
  completions: 1
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: c
        image: registry.k8s.io/e2e-test-images/agnhost:2.53
        args: ["pause"]
        resources:
          claims:
          - name: gpu
          requests:
            cpu: "50m"
      resourceClaims:
      - name: gpu
        resourceClaimTemplateName: single-gpu
EOF
}

# pre_run: install the prerequisite DRA driver before the scenario itself runs.
pre_run() {
  step "Installing the DRA example driver (simulated GPUs, 8 per worker)"
  kubectl_ctx apply --server-side -f "$SCENARIO_DIR/manifests/driver.yaml"
  kubectl_ctx rollout status daemonset/dra-example-driver-kubeletplugin -n "$DRIVER_NS" --timeout=180s
  info "waiting for the driver to publish ResourceSlices..."
  wait_for_count 1 resourceslices
  info "ResourceSlices published: $(_resourceslice_count)"
}

apply() {
  step "Applying DRA queues + ResourceClaimTemplate (quota: nvidia.com/gpu = ${GPU_QUOTA})"
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "Submitting ${NUM_JOBS} GPU jobs (each claims 1 device; quota only admits ${GPU_QUOTA})"
  local i
  for i in $(seq 1 "$NUM_JOBS"); do
    _dra_job "dra-$i"
  done | kubectl_ctx apply -f -
  info "letting Kueue admit within quota and the scheduler allocate devices..."
  sleep 20
}

inspect() {
  inspect_workloads "$NS"
  echo
  inspect_clusterqueue_usage "$CQ"
  echo
  local devices
  devices=$(kubectl_ctx get resourceslices \
    -o jsonpath='{range .items[*]}{range .spec.devices[*]}{.name}{"\n"}{end}{end}' 2>/dev/null | wc -l | tr -d ' ')
  echo "--- Mock GPU inventory ---"
  echo "    ResourceSlices: $(_resourceslice_count) | total mock devices: ${devices}"
  echo
  echo "--- ResourceClaims (DRA allocations for admitted pods) ---"
  kubectl_ctx get resourceclaims -n "$NS" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Job pods (only admitted jobs have pods; pending jobs stay suspended) ---"
  kubectl_ctx get pods -n "$NS" \
    -o custom-columns='POD:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Why are the extra jobs pending? ---"
  show_first_pending_reason "$NS"
  echo
  info "Expect ${GPU_QUOTA} workloads Admitted (${GPU_QUOTA} devices claimed) and the rest"
  info "pending on quota, even though the driver advertises far more mock GPUs."
}

# # post_run: remove the driver that pre_run installed (the scenario's queues and
# # jobs are left in place for inspection and are removed by cleanup()).
# post_run() {
#   step "Removing the DRA example driver (installed by pre_run)"
#   kubectl_ctx delete -f "$SCENARIO_DIR/manifests/driver.yaml" --ignore-not-found
# }

cleanup() {
  kubectl_ctx delete -f "$SCENARIO_DIR/manifests/queues.yaml" --ignore-not-found
  # Fallback in case post_run didn't run (e.g. cleaning after an interrupted run).
  kubectl_ctx delete -f "$SCENARIO_DIR/manifests/driver.yaml" --ignore-not-found
}
