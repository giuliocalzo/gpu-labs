#!/usr/bin/env bash
set -euo pipefail

# ---- Pinned versions (edit here) ----
CLUSTER_NAME="kueue-tas-demo"
KIND_NODE_IMAGE="kindest/node:v1.33.1"
KUEUE_VERSION="v0.18.3"
LWS_VERSION="v0.9.0"

NS="kueue-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

step() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
info() { printf "    %s\n" "$*"; }
die()  { printf "\n\033[1;31mERROR: %s\033[0m\n" "$*" >&2; exit 1; }

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
kubectl cluster-info --context "kind-$CLUSTER_NAME" >/dev/null

# ---------------------------------------------------------------------------
step "Step 3/9: Advertising fake accelerator (example.com/gpu: 1) on each worker"
mapfile -t WORKERS < <(kubectl get nodes -l cloud.provider.com/node-group=tas-group \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[ "${#WORKERS[@]}" -eq 8 ] || die "expected 8 workers, found ${#WORKERS[@]}"
for node in "${WORKERS[@]}"; do
  kubectl patch node "$node" --subresource=status --type=json \
    -p '[{"op":"add","path":"/status/capacity/example.com~1gpu","value":"1"}]' >/dev/null
  info "patched $node -> example.com/gpu: 1"
done

# ---------------------------------------------------------------------------
step "Step 4/9: Installing LeaderWorkerSet $LWS_VERSION"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/lws/releases/download/${LWS_VERSION}/manifests.yaml"
info "waiting for lws-controller-manager to become available..."
kubectl wait deploy/lws-controller-manager -n lws-system \
  --for=condition=available --timeout=300s

# ---------------------------------------------------------------------------
step "Step 5/9: Installing Kueue $KUEUE_VERSION"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml"
info "waiting for kueue-controller-manager to become available..."
kubectl wait deploy/kueue-controller-manager -n kueue-system \
  --for=condition=available --timeout=300s

# ---------------------------------------------------------------------------
step "Step 6/9: Applying Kueue TAS resources (Topology, flavor, queues)"
# Retry: the Kueue webhook may take a few seconds after the deployment is ready.
for attempt in 1 2 3 4 5 6; do
  if kubectl apply -f "$SCRIPT_DIR/manifests/kueue-tas.yaml"; then
    break
  fi
  [ "$attempt" -eq 6 ] && die "failed to apply Kueue TAS resources"
  info "webhook not ready yet, retrying in 5s (attempt $attempt)"
  sleep 5
done

# ---------------------------------------------------------------------------
step "Step 7/9: Submitting the two LWS groups (replicas: 2, size: 4)"
kubectl apply -f "$SCRIPT_DIR/manifests/lws-groups.yaml"
info "waiting for Workloads to be Admitted..."
kubectl wait --for=condition=Admitted workloads --all -n "$NS" --timeout=180s
info "waiting for all group pods to be Ready..."
kubectl wait --for=condition=Ready pods --all -n "$NS" --timeout=180s

# ---------------------------------------------------------------------------
step "Step 8/9: Submitting the overflow group (should stay Pending)"
kubectl apply -f "$SCRIPT_DIR/manifests/lws-overflow.yaml"
info "giving Kueue a few seconds to evaluate admission..."
sleep 10

# ---------------------------------------------------------------------------
step "Step 9/9: Inspection"

echo
echo "--- Workloads (Admitted vs Pending) ---"
kubectl get workloads -n "$NS" \
  -o custom-columns=\
'NAME:.metadata.name,'\
'QUEUE:.spec.queueName,'\
'RESERVED:.status.conditions[?(@.type=="QuotaReserved")].status,'\
'ADMITTED:.status.conditions[?(@.type=="Admitted")].status'

echo
echo "--- Pod placement by topology (each group should sit in ONE block) ---"
printf "%-46s %-8s %-8s %-8s %s\n" POD GROUP BLOCK RACK NODE
kubectl get pods -n "$NS" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{" "}{.metadata.labels.leaderworkerset\.sigs\.k8s\.io/group-index}{"\n"}{end}' \
  | while read -r pod node gidx; do
      [ -z "$node" ] && continue
      block=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.cloud\.provider\.com/topology-block}')
      rack=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.cloud\.provider\.com/topology-rack}')
      printf "%-46s %-8s %-8s %-8s %s\n" "$pod" "${gidx:-?}" "$block" "$rack" "$node"
    done | sort -k3,3 -k4,4

echo
echo "--- ClusterQueue quota usage ---"
kubectl get clusterqueue tas-cluster-queue \
  -o custom-columns=\
'NAME:.metadata.name,'\
'PENDING:.status.pendingWorkloads,'\
'ADMITTED:.status.admittedWorkloads,'\
'RESERVING:.status.reservingWorkloads'
echo
echo "example.com/gpu reserved:"
kubectl get clusterqueue tas-cluster-queue \
  -o jsonpath='{range .status.flavorsReservation[*]}{.name}{": "}{range .resources[*]}{.name}{"="}{.total}{" "}{end}{"\n"}{end}'

echo
echo "--- Why is the overflow group pending? ---"
PENDING_WL=$(kubectl get workloads -n "$NS" \
  -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Admitted")].status!="True")]}{.metadata.name}{"\n"}{end}' \
  | grep overflow || true)
if [ -n "$PENDING_WL" ]; then
  kubectl get workload "$PENDING_WL" -n "$NS" \
    -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.reason}{" - "}{.message}{"\n"}{end}'
else
  echo "  (overflow workload not found or already admitted)"
fi

echo
step "Demo complete."
info "Re-run inspection anytime with the commands in the README."
info "Tear down with: kind delete cluster --name $CLUSTER_NAME"
