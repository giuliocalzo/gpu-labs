#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="tas"                      # namespace holding the workloads
CQ="tas-cluster-queue"        # ClusterQueue (nvidia.com/gpu: 64 = the whole cluster)
GROUPS_LWS="lws-groups"       # the two groups that should be admitted
OVERFLOW_LWS="lws-overflow"   # the third group, expected to stay Pending on quota
GROUP_POD_COUNT=8             # 2 groups x size 4 = 8 pods total

describe() {
  echo "Topology-Aware Scheduling: LWS groups fall back rack->block, 3rd group quota-blocked"
}

# LWS creates the Kueue Workloads asynchronously, so poll until both group
# Workloads exist. Populates the global GROUP_WORKLOADS array.
_wait_for_group_workloads() {
  local attempt
  for attempt in $(seq 1 30); do
    mapfile -t GROUP_WORKLOADS < <(
      kubectl_ctx get workloads -n "$NS" -o name 2>/dev/null | grep "$GROUPS_LWS" || true
    )
    [ "${#GROUP_WORKLOADS[@]}" -ge 2 ] && return 0
    sleep 2
  done
  die "group Workloads were not created in time"
}

apply() {
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "Submitting two LWS groups (replicas: 2, size: 4 = a whole block each)"
  kubectl_ctx apply -f "$SCENARIO_DIR/manifests/lws-groups.yaml"

  info "waiting for Kueue to create the group Workloads..."
  _wait_for_group_workloads

  info "waiting for the group Workloads to be Admitted..."
  kubectl_ctx wait --for=condition=Admitted "${GROUP_WORKLOADS[@]}" -n "$NS" --timeout=180s

  info "waiting for the group pods to be Ready..."
  wait_for_count "$GROUP_POD_COUNT" pods -n "$NS" -l "leaderworkerset.sigs.k8s.io/name=$GROUPS_LWS"
  kubectl_ctx wait --for=condition=Ready pods -n "$NS" \
    -l "leaderworkerset.sigs.k8s.io/name=$GROUPS_LWS" --timeout=180s

  step "Submitting the overflow group (should stay Pending on quota)"
  kubectl_ctx apply -f "$SCENARIO_DIR/manifests/lws-overflow.yaml"
  info "giving Kueue a few seconds to evaluate admission..."
  sleep 10
}

inspect() {
  inspect_workloads "$NS"
  echo
  inspect_pod_topology "$NS"
  echo
  inspect_pending_pods "$NS"
  echo
  inspect_clusterqueue_usage "$CQ"
  echo
  echo "--- Why is the overflow group pending? ---"
  show_workload_reason "$NS" "$OVERFLOW_LWS"
}

cleanup() {
  kubectl_ctx delete -f "$SCENARIO_DIR/manifests/lws-overflow.yaml" --ignore-not-found
  kubectl_ctx delete -f "$SCENARIO_DIR/manifests/lws-groups.yaml" --ignore-not-found
  kubectl_ctx delete -f "$SCENARIO_DIR/manifests/queues.yaml" --ignore-not-found
}
