#!/usr/bin/env bash
set -euo pipefail

# ---- Pinned versions (edit here) ----
CLUSTER_NAME="kueue-tas-demo"
KIND_NODE_IMAGE="kindest/node:v1.33.1"
KUEUE_VERSION="v0.18.3"
LWS_VERSION="v0.9.0"

NS="kueue-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The kubectl/helm context this script always targets. Every kubectl/helm call
# goes through the wrappers below so we never act on the wrong (current) context.
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
kubectl_ctx() { command kubectl --context "${KUBE_CONTEXT}" "$@"; }
helm_ctx()    { command helm --kube-context "${KUBE_CONTEXT}" "$@"; }

step() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
info() { printf "    %s\n" "$*"; }
die()  { printf "\n\033[1;31mERROR: %s\033[0m\n" "$*" >&2; exit 1; }

# wait_for_count <count> <kind> [extra kubectl args...]
# Poll until at least <count> objects of <kind> (matching the extra args) exist.
# Kueue's LWS integration creates Workload objects a moment after the LWS is
# applied, so `kubectl wait` would otherwise fail with "no matching resources".
wait_for_count() {
  local want="$1" kind="$2"; shift 2
  local i n
  for i in $(seq 1 30); do
    n=$(kubectl_ctx get "$kind" -n "$NS" "$@" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" -ge "$want" ] && return 0
    sleep 2
  done
  die "timed out waiting for $want $kind object(s) in namespace $NS"
}

# ---------------------------------------------------------------------------
step "Step 1/9: Preflight - checking required tools"
for bin in docker kind kubectl; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found in PATH"
  info "found $bin"
done
docker info >/dev/null 2>&1 || die "docker daemon is not running"
info "docker daemon is running"

# ---------------------------------------------------------------------------
step "Step 2/9: Creating kind cluster '$CLUSTER_NAME' (1 control-plane + 8 workers)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  info "cluster '$CLUSTER_NAME' already exists - reusing it"
  info "(to start clean: kind delete cluster --name $CLUSTER_NAME)"
else
  kind create cluster --name "$CLUSTER_NAME" \
    --image "$KIND_NODE_IMAGE" \
    --config "$SCRIPT_DIR/kind/kind-cluster.yaml"
fi
kubectl_ctx cluster-info >/dev/null

# ---------------------------------------------------------------------------
step "Step 3/9: Advertising fake accelerator (example.com/gpu: 1) on each worker"
mapfile -t WORKERS < <(kubectl_ctx get nodes -l cloud.provider.com/node-group=tas-group \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[ "${#WORKERS[@]}" -eq 8 ] || die "expected 8 workers, found ${#WORKERS[@]}"
for node in "${WORKERS[@]}"; do
  kubectl_ctx patch node "$node" --subresource=status --type=json \
    -p '[{"op":"add","path":"/status/capacity/example.com~1gpu","value":"1"}]' >/dev/null
  info "patched $node -> example.com/gpu: 1"
done

# ---------------------------------------------------------------------------
step "Step 4/9: Installing LeaderWorkerSet $LWS_VERSION"
kubectl_ctx apply --server-side -f \
  "https://github.com/kubernetes-sigs/lws/releases/download/${LWS_VERSION}/manifests.yaml"
info "waiting for lws-controller-manager to become available..."
kubectl_ctx wait deploy/lws-controller-manager -n lws-system \
  --for=condition=available --timeout=300s

# ---------------------------------------------------------------------------
step "Step 5/9: Installing Kueue $KUEUE_VERSION"
kubectl_ctx apply --server-side -f \
  "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml"
info "waiting for kueue-controller-manager to become available..."
kubectl_ctx wait deploy/kueue-controller-manager -n kueue-system \
  --for=condition=available --timeout=300s

# ---------------------------------------------------------------------------
step "Step 6/9: Applying Kueue TAS resources (Topology, flavor, queues)"
# Retry: the Kueue webhook may take a few seconds after the deployment is ready.
for attempt in 1 2 3 4 5 6; do
  if kubectl_ctx apply -f "$SCRIPT_DIR/manifests/kueue-tas.yaml"; then
    break
  fi
  [ "$attempt" -eq 6 ] && die "failed to apply Kueue TAS resources"
  info "webhook not ready yet, retrying in 5s (attempt $attempt)"
  sleep 5
done

# ---------------------------------------------------------------------------
step "Step 7/9: Submitting the two LWS groups (replicas: 2, size: 4)"
kubectl_ctx apply -f "$SCRIPT_DIR/manifests/lws-groups.yaml"
info "waiting for Kueue to create the group Workloads..."
# Scope waits to the lws-groups resources so a pre-existing (intentionally
# blocked) overflow workload on a reused cluster doesn't make the wait time out.
GROUP_WLS=()
for _ in $(seq 1 30); do
  mapfile -t GROUP_WLS < <(kubectl_ctx get workloads -n "$NS" -o name 2>/dev/null | grep 'lws-groups' || true)
  [ "${#GROUP_WLS[@]}" -ge 2 ] && break
  sleep 2
done
[ "${#GROUP_WLS[@]}" -ge 2 ] || die "group Workloads were not created in time"
info "waiting for group Workloads to be Admitted..."
kubectl_ctx wait --for=condition=Admitted "${GROUP_WLS[@]}" -n "$NS" --timeout=180s
info "waiting for group pods to be Ready..."
wait_for_count 8 pods -l leaderworkerset.sigs.k8s.io/name=lws-groups
kubectl_ctx wait --for=condition=Ready pods -l leaderworkerset.sigs.k8s.io/name=lws-groups \
  -n "$NS" --timeout=180s

# ---------------------------------------------------------------------------
step "Step 8/9: Submitting the overflow group (should stay Pending)"
kubectl_ctx apply -f "$SCRIPT_DIR/manifests/lws-overflow.yaml"
info "giving Kueue a few seconds to evaluate admission..."
sleep 10

# ---------------------------------------------------------------------------
step "Step 9/9: Inspection"

echo
echo "--- Workloads (Admitted vs Pending) ---"
kubectl_ctx get workloads -n "$NS" \
  -o custom-columns=\
'NAME:.metadata.name,'\
'QUEUE:.spec.queueName,'\
'RESERVED:.status.conditions[?(@.type=="QuotaReserved")].status,'\
'ADMITTED:.status.conditions[?(@.type=="Admitted")].status'

echo
echo "--- Pod placement by topology (each group should sit in ONE block) ---"
info "(gated/pending pods have no node yet and are listed separately below)"
printf "%-46s %-8s %-8s %-8s %s\n" POD GROUP BLOCK RACK NODE
# Use '|' as field separator so an empty nodeName (gated pods) doesn't shift columns.
kubectl_ctx get pods -n "$NS" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"|"}{.metadata.labels.leaderworkerset\.sigs\.k8s\.io/group-index}{"\n"}{end}' \
  | while IFS='|' read -r pod node gidx; do
      [ -z "$node" ] && continue
      block=$(kubectl_ctx get node "$node" -o jsonpath='{.metadata.labels.cloud\.provider\.com/topology-block}' 2>/dev/null || true)
      rack=$(kubectl_ctx get node "$node" -o jsonpath='{.metadata.labels.cloud\.provider\.com/topology-rack}' 2>/dev/null || true)
      printf "%-46s %-8s %-8s %-8s %s\n" "$pod" "${gidx:-?}" "$block" "$rack" "$node"
    done | sort -k3,3 -k4,4

echo
echo "Pods not yet scheduled (gated by Kueue - the blocked group):"
kubectl_ctx get pods -n "$NS" \
  -o jsonpath='{range .items[?(@.status.phase=="Pending")]}{"    "}{.metadata.name}{" ("}{.status.phase}{")\n"}{end}'

echo
echo "--- ClusterQueue quota usage ---"
kubectl_ctx get clusterqueue tas-cluster-queue \
  -o custom-columns=\
'NAME:.metadata.name,'\
'PENDING:.status.pendingWorkloads,'\
'ADMITTED:.status.admittedWorkloads,'\
'RESERVING:.status.reservingWorkloads'
echo
echo "example.com/gpu reserved:"
kubectl_ctx get clusterqueue tas-cluster-queue \
  -o jsonpath='{range .status.flavorsReservation[*]}{.name}{": "}{range .resources[*]}{.name}{"="}{.total}{" "}{end}{"\n"}{end}'

echo
echo "--- Why is the overflow group pending? ---"
OVERFLOW_WL=$(kubectl_ctx get workloads -n "$NS" -o name 2>/dev/null | grep 'lws-overflow' | head -n1 || true)
if [ -n "$OVERFLOW_WL" ]; then
  kubectl_ctx get "$OVERFLOW_WL" -n "$NS" \
    -o jsonpath='{range .status.conditions[*]}{"    "}{.type}{": "}{.reason}{" - "}{.message}{"\n"}{end}'
else
  echo "    (overflow workload not found or already admitted)"
fi

echo
step "Demo complete."
info "Re-run inspection anytime with the commands in the README."
info "Tear down with: kind delete cluster --name $CLUSTER_NAME"
