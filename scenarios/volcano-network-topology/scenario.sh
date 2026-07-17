#!/usr/bin/env bash
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCENARIO_DIR/../../lib/common.sh"

# --- Scenario configuration --------------------------------------------------
NS="volcano-topology"                 # namespace holding both jobs
QUEUE="vol-topo"                      # single queue; placement is topology-driven
GANG_PODS=4                           # pods per job (each a whole 8-GPU node)
SCHED_CONF="$SCENARIO_DIR/manifests/scheduler.conf"
HYPERNODES_YAML="$SCENARIO_DIR/manifests/hypernodes.yaml"
QUEUE_YAML="$SCENARIO_DIR/manifests/queue.yaml"
JOBS_YAML="$SCENARIO_DIR/manifests/jobs.yaml"

JOB_FIT="topo-tier2"                  # hard, highestTierAllowed 2 -> fits one block
JOB_STUCK="topo-tier1"               # hard, highestTierAllowed 1 -> cannot fit a rack

# Volcano job resource (full name avoids short-name clashes with other CRDs).
VCJOB_KIND="jobs.batch.volcano.sh"
HYPERNODE_KIND="hypernodes.topology.volcano.sh"

describe() {
  echo "Volcano network topology: HyperNodes model racks/blocks; a hard highestTierAllowed=2 gang packs into one block, while an identical highestTierAllowed=1 gang cannot fit a 2-node rack and stays Pending"
}

# pre_run: install Volcano and switch its scheduler to a config that enables the
# network-topology-aware plugin (off in the default config).
pre_run() {
  install_volcano
  configure_volcano_scheduler "$SCHED_CONF"
}

apply() {
  step "Creating the network topology (HyperNodes: 4 racks @ tier1, 2 blocks @ tier2, 1 root @ tier3)"
  apply_with_retry "$HYPERNODES_YAML" 12

  step "Creating the Volcano queue '$QUEUE' (capability 64 GPUs)"
  apply_with_retry "$QUEUE_YAML" 12

  # Volcano Job specs are immutable, so recreate from scratch for a deterministic
  # starting state.
  kubectl_ctx delete "$VCJOB_KIND" --all -n "$NS" --ignore-not-found >/dev/null 2>&1 || true

  step "Submitting two ${GANG_PODS}-pod / 32-GPU gangs: '$JOB_FIT' (hard tier2) and '$JOB_STUCK' (hard tier1)"
  apply_with_retry "$JOBS_YAML" 12

  info "waiting for '$JOB_FIT' to be admitted inside a single block (${GANG_PODS} pods Running)..."
  wait_for_pods_phase "$GANG_PODS" Running "$NS" "volcano.sh/job-name=$JOB_FIT" 90 || true
  info "'$JOB_STUCK' cannot fit a 2-node rack; letting the scheduler settle..."
  sleep 10
}

# _pods_with_topology <job-name> - print each of a job's pods with the node it
# landed on and that node's block/rack, so single-block packing is visible.
_pods_with_topology() {
  local job="$1"
  printf '    %-14s %-18s %-9s %s\n' POD NODE BLOCK RACK
  kubectl_ctx get pods -n "$NS" -l "volcano.sh/job-name=$job" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
    | while read -r pod phase node; do
        if [ -n "$node" ] && [ "$node" != "<none>" ]; then
          local block rack
          block=$(kubectl_ctx get node "$node" -o jsonpath='{.metadata.labels.cloud\.provider\.com/topology-block}' 2>/dev/null)
          rack=$(kubectl_ctx get node "$node" -o jsonpath='{.metadata.labels.cloud\.provider\.com/topology-rack}' 2>/dev/null)
          printf '    %-14s %-18s %-9s %s\n' "$pod" "$node" "$block" "$rack"
        else
          printf '    %-14s %-18s %-9s %s\n' "$pod" "($phase)" "-" "-"
        fi
      done
}

inspect() {
  echo "--- HyperNodes (network topology tree; lower tier = tighter domain) ---"
  kubectl_ctx get "$HYPERNODE_KIND" -o custom-columns=\
'HYPERNODE:.metadata.name,TIER:.spec.tier' 2>/dev/null \
    | { read -r h; echo "$h"; sort -k2,2 -k1,1; } | sed 's/^/    /' || echo "    (none)"
  echo
  echo "--- PodGroups (one per job; Running = gang admitted, Pending/Inqueue = waiting) ---"
  inspect_volcano_podgroups "$NS"
  echo
  echo "--- '$JOB_FIT' (hard, highestTierAllowed=2): all ${GANG_PODS} pods packed into ONE block ---"
  _pods_with_topology "$JOB_FIT"
  echo
  echo "--- '$JOB_STUCK' (hard, highestTierAllowed=1): cannot fit a 2-node rack, stays Pending ---"
  _pods_with_topology "$JOB_STUCK"
  echo
  info "'$JOB_FIT' asked for a tier-2 (block) domain: Volcano placed all ${GANG_PODS} whole-node"
  info "pods inside a single block - minimising cross-block hops for the training job."
  info "'$JOB_STUCK' asked for a tier-1 (rack) domain: no rack holds ${GANG_PODS} nodes, so the"
  info "gang stays Pending despite 32 free GPUs elsewhere. highestTierAllowed is the knob"
  info "that trades placement tightness (network locality) against schedulability."
}

cleanup() {
  kubectl_ctx delete "$VCJOB_KIND" --all -n "$NS" --ignore-not-found 2>/dev/null || true
  kubectl_ctx delete namespace "$NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl_ctx delete -f "$QUEUE_YAML" --ignore-not-found >/dev/null 2>&1 || true
  kubectl_ctx delete -f "$HYPERNODES_YAML" --ignore-not-found >/dev/null 2>&1 || true
  uninstall_volcano
}
