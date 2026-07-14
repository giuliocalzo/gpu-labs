#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

NS="tas"

describe() { echo "Topology-Aware Scheduling: LWS groups fall back rack->block, 3rd group quota-blocked"; }

apply() {
  apply_with_retry "$SCENARIO_DIR/manifests/queues.yaml"

  step "Submitting two LWS groups (replicas: 2, size: 4 = a whole block each)"
  kubectl_ctx apply -f "$SCENARIO_DIR/manifests/lws-groups.yaml"
  info "waiting for Kueue to create the group Workloads..."
  local wls=()
  for _ in $(seq 1 30); do
    mapfile -t wls < <(kubectl_ctx get workloads -n "$NS" -o name 2>/dev/null | grep 'lws-groups' || true)
    [ "${#wls[@]}" -ge 2 ] && break
    sleep 2
  done
  [ "${#wls[@]}" -ge 2 ] || die "group Workloads were not created in time"
  info "waiting for group Workloads to be Admitted..."
  kubectl_ctx wait --for=condition=Admitted "${wls[@]}" -n "$NS" --timeout=180s
  info "waiting for group pods to be Ready..."
  wait_for_count 8 pods -n "$NS" -l leaderworkerset.sigs.k8s.io/name=lws-groups
  kubectl_ctx wait --for=condition=Ready pods -l leaderworkerset.sigs.k8s.io/name=lws-groups \
    -n "$NS" --timeout=180s

  step "Submitting the overflow group (should stay Pending on quota)"
  kubectl_ctx apply -f "$SCENARIO_DIR/manifests/lws-overflow.yaml"
  info "giving Kueue a few seconds to evaluate admission..."
  sleep 10
}

inspect() {
  inspect_workloads "$NS"
  echo; inspect_pod_topology "$NS"
  echo; inspect_pending_pods "$NS"
  echo; inspect_clusterqueue_usage "tas-cluster-queue"
  echo; echo "--- Why is the overflow group pending? ---"
  show_workload_reason "$NS" "lws-overflow"
}

cleanup() {
  kubectl_ctx delete -f "$SCENARIO_DIR/manifests/lws-overflow.yaml" --ignore-not-found
  kubectl_ctx delete -f "$SCENARIO_DIR/manifests/lws-groups.yaml" --ignore-not-found
  kubectl_ctx delete -f "$SCENARIO_DIR/manifests/queues.yaml" --ignore-not-found
}
