#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="kai-lws"                          # namespace holding the LWS
LWS="lws-topology"                    # the LeaderWorkerSet we submit
GROUP_SIZE=4                          # 1 leader + 3 workers (each a whole 8-GPU node)
PODS_PER_RACK=2                       # a rack is 2 nodes, so preferred=rack packs 2 pods/rack
POD_COUNT="$GROUP_SIZE"              # replicas: 1, so pods == group size
TOPOLOGY="$SCENARIO_DIR/manifests/topology.yaml"
MANIFEST="$SCENARIO_DIR/manifests/lws.yaml"

# Node-label keys of the topology hierarchy (must match cluster/kind-cluster.yaml).
BLOCK_LABEL="cloud.provider.com/topology-block"
RACK_LABEL="cloud.provider.com/topology-rack"

describe() {
  echo "KAI + LeaderWorkerSet: KAI gang-schedules the LWS into one topology block and packs it ${PODS_PER_RACK} pods per rack (required=block, preferred=rack)"
}

# pre_run: install the KAI Scheduler (the gang/topology scheduler). LeaderWorkerSet
# is already part of the base install, so only KAI is scenario-specific here.
pre_run() {
  install_kai
}

apply() {
  step "Applying the KAI Topology + queues"
  apply_with_retry "$TOPOLOGY" 12

  step "Submitting the LeaderWorkerSet '$LWS' (size ${GROUP_SIZE}, one 8-GPU node per pod, scheduled by KAI)"
  apply_with_retry "$MANIFEST" 12

  info "waiting for all ${POD_COUNT} pods to be created..."
  wait_for_count "$POD_COUNT" pods -n "$NS"

  info "waiting for KAI to gang-schedule the group (pods should become Ready)..."
  kubectl_ctx wait --for=condition=Ready pods -n "$NS" --all --timeout=180s || true
}

# Print each pod with the block/rack it landed on, sorted by block then rack so
# the topology packing (one block, 2 pods per rack) is obvious.
_inspect_placement() {
  printf "    %-40s %-8s %-8s %s\n" POD BLOCK RACK NODE
  kubectl_ctx get pods -n "$NS" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
    | while IFS='|' read -r pod node; do
        if [ -z "$node" ]; then
          printf "    %-40s %-8s %-8s %s\n" "$pod" "-" "-" "(unscheduled)"
          continue
        fi
        block=$(kubectl_ctx get node "$node" -o jsonpath="{.metadata.labels.$(echo "$BLOCK_LABEL" | sed 's/\./\\./g')}" 2>/dev/null || true)
        rack=$(kubectl_ctx get node "$node" -o jsonpath="{.metadata.labels.$(echo "$RACK_LABEL" | sed 's/\./\\./g')}" 2>/dev/null || true)
        printf "    %-40s %-8s %-8s %s\n" "$pod" "$block" "$rack" "$node"
      done | sort -k2,2 -k3,3
}

inspect() {
  echo "--- LeaderWorkerSet ---"
  kubectl_ctx get leaderworkersets -n "$NS" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- KAI PodGroup (the scheduler-facing gang, one per LWS replica) ---"
  kubectl_ctx get podgroups.scheduling.run.ai -n "$NS" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Pods (all Running = KAI admitted the whole gang all-or-nothing) ---"
  kubectl_ctx get pods -n "$NS" \
    -o custom-columns='POD:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName' 2>/dev/null \
    | sed 's/^/    /'
  echo
  echo "--- Placement (whole group in ONE block, packed ${PODS_PER_RACK} pods per rack) ---"
  _inspect_placement
  echo
  info "KAI gang-schedules the whole LWS: all ${POD_COUNT} pods go Pending -> Running together."
  info "required=block: all ${POD_COUNT} pods land in a single block (32 GPUs / 4 nodes)."
  info "preferred=rack: within that block KAI packs them ${PODS_PER_RACK} per rack"
  info "(a rack is 2 nodes), so each rack holds one leader/worker pair."
}

# # post_run: uninstall the operators this scenario installed.
# post_run() {
#   step "Removing the LWS, KAI, and LeaderWorkerSet operator"
#   kubectl_ctx delete -f "$MANIFEST" --ignore-not-found
#   kubectl_ctx delete -f "$TOPOLOGY" --ignore-not-found
#   uninstall_kai
# }

cleanup() {
  kubectl_ctx delete -f "$MANIFEST" --ignore-not-found
  kubectl_ctx delete -f "$TOPOLOGY" --ignore-not-found
  uninstall_kai
}
