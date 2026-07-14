#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="grove-kai"                # namespace holding the Grove workload
PCS="llm-inference"           # the PodCliqueSet we submit
TOPOLOGY="$SCENARIO_DIR/manifests/topology.yaml"
MANIFEST="$SCENARIO_DIR/manifests/podcliqueset.yaml"
CLIQUE_COUNT=4                # frontend + prefill-leader + prefill-worker + decode
POD_COUNT=6                   # 1 + 1 + 2 + 2 replicas across the cliques

# Grove custom resources (full names avoid short-name alias clashes).
PCLQ_KIND="podcliques.grove.io"
PCSG_KIND="podcliquescalinggroups.grove.io"
PODGANG_KIND="podgangs.scheduler.grove.io"

describe() {
  echo "Grove + KAI: KAI gang-schedules the PodGang and packs the prefill gang into one topology block"
}

# pre_run: install the two operators this scenario needs (not part of the base
# install): the KAI Scheduler (the gang/topology scheduler) and Grove.
pre_run() {
  install_kai
  install_grove
}

apply() {
  step "Applying the KAI Topology + Grove ClusterTopologyBinding + KAI queues"
  apply_with_retry "$TOPOLOGY" 12

  step "Submitting the PodCliqueSet '$PCS' (scheduled by KAI, prefill packed into one block)"
  apply_with_retry "$MANIFEST" 24

  info "waiting for Grove to expand it into ${CLIQUE_COUNT} PodCliques..."
  wait_for_count "$CLIQUE_COUNT" "$PCLQ_KIND" -n "$NS"

  info "waiting for all ${POD_COUNT} pods to be created..."
  wait_for_count "$POD_COUNT" pods -n "$NS"

  info "waiting for KAI to gang-schedule the pods (they should become Ready)..."
  kubectl_ctx wait --for=condition=Ready pods -n "$NS" --all --timeout=180s || true
}

# Print each pod with the block/rack it landed on, sorted by block/rack so the
# prefill gang's co-location is obvious.
_inspect_placement() {
  printf "    %-52s %-8s %-8s %s\n" POD BLOCK RACK NODE
  kubectl_ctx get pods -n "$NS" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
    | while IFS='|' read -r pod node; do
        [ -z "$node" ] && { printf "    %-52s %-8s %-8s %s\n" "$pod" "-" "-" "(unscheduled)"; continue; }
        block=$(kubectl_ctx get node "$node" -o jsonpath='{.metadata.labels.cloud\.provider\.com/topology-block}' 2>/dev/null || true)
        rack=$(kubectl_ctx get node "$node" -o jsonpath='{.metadata.labels.cloud\.provider\.com/topology-rack}' 2>/dev/null || true)
        printf "    %-52s %-8s %-8s %s\n" "$pod" "$block" "$rack" "$node"
      done | sort -k2,2 -k3,3
}

inspect() {
  echo "--- Grove PodGang (what Grove generates for the scheduler) ---"
  kubectl_ctx get "$PODGANG_KIND" -n "$NS" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- KAI PodGroup (the actual scheduler-facing gang KAI admits) ---"
  kubectl_ctx get podgroups.scheduling.run.ai -n "$NS" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- PodCliqueScalingGroup (the prefill gang) ---"
  kubectl_ctx get "$PCSG_KIND" -n "$NS" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Pods (all Running = KAI admitted the whole gang all-or-nothing) ---"
  kubectl_ctx get pods -n "$NS" \
    -o custom-columns='POD:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName' 2>/dev/null \
    | sed 's/^/    /'
  echo
  echo "--- Placement (prefill-leader + prefill-worker land in ONE block) ---"
  _inspect_placement
  echo
  info "KAI gang-schedules the whole PodGang: all pods go Pending -> Running together"
  info "(vs the grove-podcliques baseline, where the default scheduler leaves them"
  info "Pending forever)."
  info "Topology: the 3-pod prefill gang is packed into a single block (required=block);"
  info "a rack only holds 2 nodes, so preferred=rack co-locates 2 of the 3 and spills"
  info "the third to another rack in the SAME block."
}

# # post_run: uninstall the operators this scenario installed.
# post_run() {
#   step "Removing the Grove workload, KAI, and Grove"
#   kubectl_ctx delete -f "$MANIFEST" --ignore-not-found
#   kubectl_ctx delete -f "$TOPOLOGY" --ignore-not-found
#   uninstall_grove
#   uninstall_kai
# }

cleanup() {
  kubectl_ctx delete -f "$MANIFEST" --ignore-not-found
  kubectl_ctx delete -f "$TOPOLOGY" --ignore-not-found
  uninstall_grove
  uninstall_kai
}
