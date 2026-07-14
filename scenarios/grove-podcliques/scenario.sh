#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="grove"                     # namespace holding the Grove workload
PCS="llm-inference"            # the PodCliqueSet we submit
MANIFEST="$SCENARIO_DIR/manifests/podcliqueset.yaml"
CLIQUE_COUNT=4                 # frontend + prefill-leader + prefill-worker + decode
POD_COUNT=6                    # 1 + 1 + 2 + 2 replicas across the cliques

# Grove custom resources (full names are used so short-name aliases don't matter).
PCS_KIND="podcliquesets.grove.io"
PCLQ_KIND="podcliques.grove.io"
PCSG_KIND="podcliquescalinggroups.grove.io"
PODGANG_KIND="podgangs.scheduler.grove.io"

describe() {
  echo "Grove PodCliqueSet: one spec expands into role cliques, a scaling group, a PodGang, and ordered pods"
}

# pre_run: install the prerequisite Grove operator before the scenario runs.
pre_run() {
  install_grove
}

apply() {
  step "Submitting the PodCliqueSet '$PCS' (disaggregated inference: frontend + prefill + decode)"
  # Grove's admission webhook may still be settling right after install, so retry.
  apply_with_retry "$MANIFEST" 24

  info "waiting for Grove to expand it into ${CLIQUE_COUNT} PodCliques..."
  wait_for_count "$CLIQUE_COUNT" "$PCLQ_KIND" -n "$NS"

  info "waiting for all ${POD_COUNT} pods to be created (startup order rolls out in waves)..."
  wait_for_count "$POD_COUNT" pods -n "$NS"

  info "waiting for the pods to become Ready..."
  kubectl_ctx wait --for=condition=Ready pods -n "$NS" --all --timeout=180s || true
}

inspect() {
  echo "--- PodCliqueSet (the single object we submitted) ---"
  kubectl_ctx get "$PCS_KIND" -n "$NS" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- PodCliques (one group of pods per role) ---"
  kubectl_ctx get "$PCLQ_KIND" -n "$NS" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- PodCliqueScalingGroup (prefill leader + workers, one gang) ---"
  kubectl_ctx get "$PCSG_KIND" -n "$NS" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- PodGang (scheduler-facing gang Grove generated) ---"
  kubectl_ctx get "$PODGANG_KIND" -n "$NS" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- Pods (placement across the fake-GPU nodes) ---"
  kubectl_ctx get pods -n "$NS" \
    -o custom-columns='POD:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName' 2>/dev/null \
    | sed 's/^/    /' || echo "    (none)"
  echo
  info "One PodCliqueSet became ${CLIQUE_COUNT} PodCliques + 1 scaling group + 1 PodGang + ${POD_COUNT} pods,"
  info "started in order: frontend -> prefill (leader+workers) -> decode."
}

# post_run: remove the workload and the operator that pre_run installed, so the
# shared cluster returns to baseline (same pattern as the DRA driver).
post_run() {
  step "Removing the Grove workload"
  kubectl_ctx delete -f "$MANIFEST" --ignore-not-found
  uninstall_grove
}

cleanup() {
  kubectl_ctx delete -f "$MANIFEST" --ignore-not-found
  # Fallback in case post_run didn't run (e.g. cleaning after an interrupted run).
  uninstall_grove
}
