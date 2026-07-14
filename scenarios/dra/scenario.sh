#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

describe() { echo "(stub) Dynamic Resource Allocation - needs DRA feature gates + a DRA driver"; }

apply() {
  warn "The DRA scenario is a documented STUB - it does not create workloads."
  cat <<'EOF'

    Dynamic Resource Allocation (DRA) can't run on this shared cluster as-is
    because it requires cluster-creation-time changes and an external driver:

      1. Feature gates on the kube-apiserver, kube-scheduler and kubelet
         (DynamicResourceAllocation) plus the resource.k8s.io API enabled.
         These go in cluster/kind-cluster.yaml (featureGates + apiServer
         runtimeConfig) and need FORCE_RECREATE=1 to take effect.
      2. A DRA driver installed (e.g. the k8s DRA example driver, or the
         NVIDIA DRA driver for GPUs) that publishes ResourceSlices.
      3. Kueue configured to account for DeviceClass/ResourceClaim requests,
         plus DeviceClass + ResourceClaimTemplate objects, and workloads that
         reference the claim instead of nvidia.com/gpu.

    See scenarios/dra/README.md for the full enablement plan.
EOF
}

inspect() {
  info "Nothing to inspect - DRA scenario is a stub. See scenarios/dra/README.md."
}

cleanup() {
  info "Nothing to clean - DRA scenario is a stub."
}
