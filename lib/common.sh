#!/usr/bin/env bash
# Shared library for the Kueue demo lab.
# Sourced by demo.sh and by every scenarios/<name>/scenario.sh.
# Re-sourcing is a no-op (guard below), so scenarios can source it safely.

if [ -n "${_KUEUE_LIB_LOADED:-}" ]; then return 0; fi
_KUEUE_LIB_LOADED=1

set -euo pipefail

# ---- Pinned versions / config (override via env) ----
CLUSTER_NAME="${CLUSTER_NAME:-gpu-lab}"
KUEUE_VERSION="${KUEUE_VERSION:-0.18.3}"
LWS_VERSION="${LWS_VERSION:-0.9.0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.21.0}"
GROVE_VERSION="${GROVE_VERSION:-0.1.0-alpha.11}"
FORCE_RECREATE="${FORCE_RECREATE:-}"

KUBE_CONTEXT="kind-${CLUSTER_NAME}"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"

# Every kubectl/helm call is context-pinned so we never touch the wrong cluster.
kubectl_ctx() { command kubectl --context "${KUBE_CONTEXT}" "$@"; }
helm_ctx()    { command helm --kube-context "${KUBE_CONTEXT}" "$@"; }

# Logging helpers (color-coded): step = section header, info = indented detail,
# warn = highlighted warning, die = print error and exit non-zero.
step() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
info() { printf "    %s\n" "$*"; }
warn() { printf "\033[1;33m    %s\033[0m\n" "$*"; }
die()  { printf "\n\033[1;31mERROR: %s\033[0m\n" "$*" >&2; exit 1; }

# wait_for_count <count> <kind> [extra kubectl args...]
# Poll until at least <count> objects of <kind> (matching the extra args) exist.
wait_for_count() {
  local want="$1" kind="$2"; shift 2
  local i n
  for i in $(seq 1 30); do
    n=$(kubectl_ctx get "$kind" "$@" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" -ge "$want" ] && return 0
    sleep 2
  done
  die "timed out waiting for $want $kind object(s)"
}

# apply_with_retry <file> [attempts]  - tolerate an admission webhook (Kueue,
# Grove, ...) not being ready yet. Defaults to 6 attempts, 5s apart.
apply_with_retry() {
  local f="$1" attempts="${2:-6}" i
  for i in $(seq 1 "$attempts"); do
    kubectl_ctx apply -f "$f" && return 0
    info "webhook not ready yet, retrying in 5s (attempt $i/$attempts)"
    sleep 5
  done
  die "failed to apply $f"
}

# ---------------------------------------------------------------------------
# Cluster + base install (shared by every scenario)
# ---------------------------------------------------------------------------
# Create the kind cluster from the checked-in topology config.
_create_cluster() {
  kind create cluster --name "$CLUSTER_NAME" \
    --config "$REPO_ROOT/cluster/kind-cluster.yaml"
}

# Verify required tools/daemon, then create the cluster if missing (or rebuild it
# when FORCE_RECREATE is set) and confirm it is reachable.
ensure_cluster() {
  step "Ensuring kind cluster '$CLUSTER_NAME' (1 control-plane + 8 workers)"
  local bin
  for bin in docker kind kubectl helm; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found in PATH"
  done
  docker info >/dev/null 2>&1 || die "docker daemon is not running"
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    if [ -n "$FORCE_RECREATE" ]; then
      info "FORCE_RECREATE set - deleting existing cluster '$CLUSTER_NAME'..."
      kind delete cluster --name "$CLUSTER_NAME"
      _create_cluster
    else
      info "cluster '$CLUSTER_NAME' already exists - reusing it (FORCE_RECREATE=1 to rebuild)"
    fi
  else
    _create_cluster
  fi
  kubectl_ctx cluster-info >/dev/null
}

# Patch each worker's status to advertise 8 fake nvidia.com/gpu (no real GPUs
# needed). Idempotent: skips nodes that already report the capacity.
patch_fake_gpus() {
  step "Advertising fake accelerators (nvidia.com/gpu: 8) on each worker"
  local workers node cur
  mapfile -t workers < <(kubectl_ctx get nodes -l cloud.provider.com/node-group=tas-group \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  [ "${#workers[@]}" -eq 8 ] || die "expected 8 workers, found ${#workers[@]}"
  for node in "${workers[@]}"; do
    cur=$(kubectl_ctx get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null || true)
    if [ "$cur" != "8" ]; then
      kubectl_ctx patch node "$node" --subresource=status --type=json \
        -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"8"}]' >/dev/null
    fi
    info "$node -> nvidia.com/gpu: 8"
  done
}

# Install cert-manager via Helm (skips if already present). The chart version
# tag uses a leading "v"; CERT_MANAGER_VERSION is stored without it. The
# validating/mutating webhook is disabled (webhook.enabled=false): nothing in
# this lab submits cert-manager CRs through the API, so the webhook is dead
# weight - Kueue and LWS manage their own webhook TLS internally.
install_cert_manager() {
  if kubectl_ctx get deploy cert-manager -n cert-manager >/dev/null 2>&1; then
    info "cert-manager already installed"
    return
  fi
  step "Installing cert-manager (helm chart v${CERT_MANAGER_VERSION}, webhook disabled)"
  helm_ctx install cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --version="v${CERT_MANAGER_VERSION}" \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true \
    --wait --timeout 300s
}

# Install the LeaderWorkerSet controller via Helm (skips if already present).
install_lws() {
  if kubectl_ctx get deploy lws-controller-manager -n lws-system >/dev/null 2>&1; then
    info "LeaderWorkerSet already installed"
    return
  fi
  step "Installing LeaderWorkerSet (helm chart $LWS_VERSION)"
  helm_ctx install lws oci://registry.k8s.io/lws/charts/lws \
    --version="$LWS_VERSION" \
    --namespace lws-system \
    --create-namespace \
    --set enableDisaggregatedSet=true \
    --wait --timeout 300s
}

# Install Kueue via Helm using base/kueue-values.yaml (fair sharing + DRA
# integration). Skips if already present.
install_kueue() {
  if kubectl_ctx get deploy kueue-controller-manager -n kueue-system >/dev/null 2>&1; then
    info "Kueue already installed"
    return
  fi
  step "Installing Kueue (helm chart $KUEUE_VERSION, fairSharing enabled via values)"
  helm_ctx install kueue oci://registry.k8s.io/kueue/charts/kueue \
    --version="$KUEUE_VERSION" \
    --create-namespace --namespace=kueue-system \
    -f "$REPO_ROOT/base/kueue-values.yaml" \
    --wait --timeout 300s
}

# Bring the shared platform up end-to-end: cluster, fake GPUs, cert-manager,
# LWS, Kueue, and the base ResourceFlavors/Topology every scenario builds on.
install_base() {
  ensure_cluster
  patch_fake_gpus
  install_cert_manager
  install_lws
  install_kueue
  step "Applying base ResourceFlavors + Topology"
  apply_with_retry "$REPO_ROOT/base/flavors.yaml"
}

# Install the Grove operator via Helm (scenario-scoped, not part of install_base).
# Idempotent via 'helm upgrade -i'. The chart ships its own CRDs and the operator
# self-manages its webhook TLS, so no extra prerequisites are needed. The chart
# version tag uses a leading "v"; GROVE_VERSION is stored without it.
install_grove() {
  step "Installing the Grove operator (helm chart v${GROVE_VERSION})"
  helm_ctx upgrade -i grove oci://ghcr.io/ai-dynamo/grove/grove-charts \
    --version="v${GROVE_VERSION}" \
    --namespace grove-system \
    --create-namespace \
    --wait --timeout 300s
  # The operator bootstraps its own webhook TLS and restarts once on first
  # install; wait for it to settle so the admission webhook is actually serving.
  kubectl_ctx -n grove-system rollout status deploy/grove-operator --timeout=120s
}

# Remove the Grove operator installed by install_grove.
uninstall_grove() {
  step "Uninstalling the Grove operator"
  helm_ctx uninstall grove --namespace grove-system --ignore-not-found --wait || true
  kubectl_ctx delete namespace grove-system --ignore-not-found >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Workload helpers
# ---------------------------------------------------------------------------
# gpu_job <ns> <queue> <name> <gpus> [workload-priority-class]
# Emits a suspended batch/v1 Job (one pause pod) requesting <gpus> nvidia.com/gpu.
gpu_job() {
  local ns="$1" queue="$2" name="$3" gpus="$4" prio="${5:-}"
  echo "---"
  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $name
  namespace: $ns
  labels:
    kueue.x-k8s.io/queue-name: $queue
EOF
  [ -n "$prio" ] && printf "    kueue.x-k8s.io/priority-class: %s\n" "$prio"
  cat <<EOF
spec:
  parallelism: 1
  completions: 1
  suspend: true
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: c
          image: registry.k8s.io/pause:3.10
          resources:
            requests:
              cpu: "50m"
              nvidia.com/gpu: "$gpus"
            limits:
              nvidia.com/gpu: "$gpus"
EOF
}

# submit_gpu_jobs <ns> <queue> <name-prefix> <count> <gpus> [workload-priority-class]
# Applies <count> suspended GPU jobs named <prefix>-1 .. <prefix>-<count>.
submit_gpu_jobs() {
  local ns="$1" queue="$2" prefix="$3" count="$4" gpus="$5" prio="${6:-}" i
  for i in $(seq 1 "$count"); do
    gpu_job "$ns" "$queue" "${prefix}-${i}" "$gpus" "$prio"
  done | kubectl_ctx apply -f -
}

# ---------------------------------------------------------------------------
# Generic inspection helpers (scenarios compose these)
# ---------------------------------------------------------------------------
# inspect_workloads <ns> - table of Workloads with queue, priority, and the
# QuotaReserved/Admitted condition status.
inspect_workloads() {
  local ns="$1"
  echo "--- Workloads in '$ns' (priority / reserved / admitted) ---"
  kubectl_ctx get workloads -n "$ns" -o custom-columns=\
'NAME:.metadata.name,'\
'QUEUE:.spec.queueName,'\
'PRIORITY:.spec.priority,'\
'RESERVED:.status.conditions[?(@.type=="QuotaReserved")].status,'\
'ADMITTED:.status.conditions[?(@.type=="Admitted")].status' 2>/dev/null \
    || echo "  (none)"
}

# inspect_pod_topology <ns> - show where each pod landed (LWS group, block, rack,
# node), sorted by block/rack to make topology co-location visible.
inspect_pod_topology() {
  local ns="$1"
  echo "--- Pod placement by topology in '$ns' ---"
  printf "%-46s %-8s %-8s %-8s %s\n" POD GROUP BLOCK RACK NODE
  kubectl_ctx get pods -n "$ns" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"|"}{.metadata.labels.leaderworkerset\.sigs\.k8s\.io/group-index}{"\n"}{end}' \
    | while IFS='|' read -r pod node gidx; do
        [ -z "$node" ] && continue
        block=$(kubectl_ctx get node "$node" -o jsonpath='{.metadata.labels.cloud\.provider\.com/topology-block}' 2>/dev/null || true)
        rack=$(kubectl_ctx get node "$node" -o jsonpath='{.metadata.labels.cloud\.provider\.com/topology-rack}' 2>/dev/null || true)
        printf "%-46s %-8s %-8s %-8s %s\n" "$pod" "${gidx:-?}" "$block" "$rack" "$node"
      done | sort -k3,3 -k4,4
}

# inspect_clusterqueue_usage <cq> - pending/admitted/reserving counts plus the
# per-flavor reserved resource totals for a ClusterQueue.
inspect_clusterqueue_usage() {
  local cq="$1"
  echo "--- ClusterQueue '$cq' ---"
  kubectl_ctx get clusterqueue "$cq" -o custom-columns=\
'NAME:.metadata.name,'\
'PENDING:.status.pendingWorkloads,'\
'ADMITTED:.status.admittedWorkloads,'\
'RESERVING:.status.reservingWorkloads' 2>/dev/null || { echo "  (not found)"; return; }
  kubectl_ctx get clusterqueue "$cq" \
    -o jsonpath='{range .status.flavorsReservation[*]}{"    reserved "}{.name}{": "}{range .resources[*]}{.name}{"="}{.total}{" "}{end}{"\n"}{end}' 2>/dev/null || true
}

# inspect_pending_pods <ns> - list pods still in Pending (i.e. gated by Kueue).
inspect_pending_pods() {
  local ns="$1"
  echo "Pods not yet scheduled (gated by Kueue):"
  kubectl_ctx get pods -n "$ns" \
    -o jsonpath='{range .items[?(@.status.phase=="Pending")]}{"    "}{.metadata.name}{" ("}{.status.phase}{")\n"}{end}' 2>/dev/null || true
}

# show_workload_reason <ns> <name-substring>
show_workload_reason() {
  local ns="$1" match="$2" wl
  wl=$(kubectl_ctx get workloads -n "$ns" -o name 2>/dev/null | grep "$match" | head -n1 || true)
  if [ -n "$wl" ]; then
    kubectl_ctx get "$wl" -n "$ns" \
      -o jsonpath='{range .status.conditions[*]}{"    "}{.type}{": "}{.reason}{" - "}{.message}{"\n"}{end}'
  fi
}

# count_admitted <ns>  -> number of workloads with Admitted=True
count_admitted() {
  kubectl_ctx get workloads -n "$1" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Admitted")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c True || true
}
