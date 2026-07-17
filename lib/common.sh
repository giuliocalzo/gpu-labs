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
KUBERAY_VERSION="${KUBERAY_VERSION:-1.6.2}"
JOBSET_VERSION="${JOBSET_VERSION:-0.12.0}"
KAI_VERSION="${KAI_VERSION:-0.16.3}"
VOLCANO_VERSION="${VOLCANO_VERSION:-1.15.0}"
KUBEFLOW_TRAINER_VERSION="${KUBEFLOW_TRAINER_VERSION:-2.2.1}"
APPWRAPPER_VERSION="${APPWRAPPER_VERSION:-1.2.2}"
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

# create_with_retry <file> [attempts]  - like apply_with_retry, but uses
# `kubectl create` instead of `apply`. Required for objects that rely on
# metadata.generateName (RayJob/JobSet/TrainJob templates submitted N times),
# which `apply` rejects because it needs a concrete name. Defaults to 12
# attempts, 5s apart, to ride out a webhook still settling after a controller
# restart. Each call creates a new, uniquely-named object.
create_with_retry() {
  local f="$1" attempts="${2:-12}" i
  for i in $(seq 1 "$attempts"); do
    kubectl_ctx create -f "$f" && return 0
    info "webhook not ready yet, retrying in 5s (attempt $i/$attempts)"
    sleep 5
  done
  die "failed to create $f"
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
    --wait --timeout 300s >/dev/null
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
# LWS, Kueue, and the shared gpu-flavor every non-TAS scenario builds on.
install_base() {
  ensure_cluster
  patch_fake_gpus
  install_cert_manager
  install_lws
  install_kueue
  step "Applying the shared ResourceFlavor (base/flavors.yaml)"
  apply_with_retry "$REPO_ROOT/base/flavors.yaml"
}

# Install the Grove operator via Helm (scenario-scoped, not part of install_base).
# Idempotent via 'helm upgrade -i'. The chart ships its own CRDs and the operator
# self-manages its webhook TLS, so no extra prerequisites are needed. The chart
# version tag uses a leading "v"; GROVE_VERSION is stored without it.
# Topology Aware Scheduling is always enabled
# (config.topologyAwareScheduling.enabled=true): it is required before a
# PodCliqueSet may carry a topologyConstraint, and it is harmless for the plain
# grove-podcliques baseline (which simply doesn't set any constraint). The
# kai-scheduler backend profile is already enabled by the chart's defaults.
install_grove() {
  step "Installing the Grove operator (helm chart v${GROVE_VERSION})"
  helm_ctx upgrade -i grove oci://ghcr.io/ai-dynamo/grove/grove-charts \
    --version="v${GROVE_VERSION}" \
    --namespace grove-system \
    --create-namespace \
    --set "config.topologyAwareScheduling.enabled=true" \
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

# Install the KubeRay operator via Helm (scenario-scoped, not part of install_base).
# Idempotent via 'helm upgrade -i'. Kueue's ray.io/rayjob integration is already
# enabled in base/kueue-values.yaml, so once this operator is present Kueue can
# manage RayJobs.
install_kuberay() {
  step "Installing the KubeRay operator (helm chart $KUBERAY_VERSION)"
  helm_ctx repo add kuberay https://ray-project.github.io/kuberay-helm/ >/dev/null 2>&1 || true
  helm_ctx repo update kuberay >/dev/null 2>&1 || true
  helm_ctx upgrade -i kuberay-operator kuberay/kuberay-operator \
    --version="$KUBERAY_VERSION" \
    --namespace kuberay-system \
    --create-namespace \
    --wait --timeout 300s
}

# Remove the KubeRay operator installed by install_kuberay.
uninstall_kuberay() {
  step "Uninstalling the KubeRay operator"
  helm_ctx uninstall kuberay-operator --namespace kuberay-system --ignore-not-found --wait || true
  kubectl_ctx delete namespace kuberay-system --ignore-not-found >/dev/null 2>&1 || true
}

# Install the JobSet operator via Helm (scenario-scoped, not part of install_base).
# Idempotent via 'helm upgrade -i'. Kueue's jobset.x-k8s.io/jobset integration is
# already enabled in base/kueue-values.yaml, so once this operator is present
# Kueue can manage JobSets. certManager.enable=true reuses the base cert-manager
# to provision the JobSet webhook certificate.
install_jobset() {
  step "Installing the JobSet operator (helm chart $JOBSET_VERSION)"
  helm_ctx upgrade -i jobset oci://registry.k8s.io/jobset/charts/jobset \
    --version="$JOBSET_VERSION" \
    --namespace jobset-system \
    --create-namespace \
    --set certManager.enable=true \
    --wait --timeout 300s
}

# Remove the JobSet operator installed by install_jobset.
uninstall_jobset() {
  step "Uninstalling the JobSet operator"
  helm_ctx uninstall jobset --namespace jobset-system --ignore-not-found --wait || true
  kubectl_ctx delete namespace jobset-system --ignore-not-found >/dev/null 2>&1 || true
}

# Install the NVIDIA KAI Scheduler via Helm (scenario-scoped, not part of
# install_base). Idempotent via 'helm upgrade -i'. KAI understands Grove
# PodGangs natively (its PodGrouper has a Grove plugin), so it can gang-schedule
# and topology-place the workloads the grove scenarios create.
#
# Two flags matter for this fake-GPU kind lab:
#   global.gpuSharing=false                  - we request whole nvidia.com/gpu
#     units, not fractions, so KAI's GPU-sharing machinery stays off.
#   admission.gpuFractionRuntimeClassName=null - there is no NVIDIA GPU-Operator
#     here (fake GPUs), so KAI must not require its runtime class on GPU pods.
install_kai() {
  step "Installing the KAI Scheduler (helm chart v${KAI_VERSION})"
  helm_ctx upgrade -i kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
    --version="v${KAI_VERSION}" \
    --namespace kai-scheduler \
    --create-namespace \
    --set "global.gpuSharing=false" \
    --set "admission.gpuFractionRuntimeClassName=null" \
    --wait --timeout 300s >/dev/null
}

# Remove the KAI Scheduler installed by install_kai.
uninstall_kai() {
  step "Uninstalling the KAI Scheduler"
  helm_ctx uninstall kai-scheduler --namespace kai-scheduler --ignore-not-found --wait || true
  kubectl_ctx delete namespace kai-scheduler --ignore-not-found >/dev/null 2>&1 || true
}

# Install Volcano (batch scheduler) via Helm (scenario-scoped, not part of
# install_base). Idempotent via 'helm upgrade -i'. The chart ships its own CRDs
# (Job/Queue/PodGroup) and a scheduler whose default config enables the gang and
# proportion plugins - exactly what the volcano-gang scenario relies on for
# all-or-nothing admission and per-queue capacity.
install_volcano() {
  step "Installing Volcano (helm chart v${VOLCANO_VERSION})"
  helm_ctx repo add volcano-sh https://volcano-sh.github.io/helm-charts >/dev/null 2>&1 || true
  helm_ctx repo update volcano-sh >/dev/null 2>&1 || true
  helm_ctx upgrade -i volcano volcano-sh/volcano \
    --version="$VOLCANO_VERSION" \
    --namespace volcano-system \
    --create-namespace \
    --wait --timeout 300s >/dev/null
}

# Remove Volcano installed by install_volcano.
uninstall_volcano() {
  step "Uninstalling Volcano"
  helm_ctx uninstall volcano --namespace volcano-system --ignore-not-found --wait || true
  kubectl_ctx delete namespace volcano-system --ignore-not-found >/dev/null 2>&1 || true
}

# Install Kubeflow Trainer V2 via Helm (scenario-scoped, not part of
# install_base). Idempotent via 'helm upgrade -i'. This is the successor to the
# v1 Training Operator: it ships the trainer.kubeflow.org CRDs (TrainJob,
# ClusterTrainingRuntime, TrainingRuntime) and runs a TrainJob as a JobSet under
# the hood - so the chart also bundles a jobset-controller as a subchart, all in
# the "kubeflow-system" namespace. It self-manages its webhook TLS (no
# cert-manager needed). Kueue's trainer.kubeflow.org/trainjob integration is
# already enabled in base/kueue-values.yaml.
#
# Version note: Kueue v0.18.x unsuspends a TrainJob via the RuntimePatches API
# (spec.runtimePatches), which only exists in Kubeflow Trainer >= v2.2. On v2.1
# Kueue admits the Workload but can't unsuspend it ("kueue runtime patch not
# found"), so the pods never start. Keep this pinned to >= 2.2.0.
install_kubeflow_trainer() {
  step "Installing Kubeflow Trainer (helm chart v${KUBEFLOW_TRAINER_VERSION})"
  helm_ctx upgrade -i kubeflow-trainer oci://ghcr.io/kubeflow/charts/kubeflow-trainer \
    --version="$KUBEFLOW_TRAINER_VERSION" \
    --namespace kubeflow-system \
    --create-namespace \
    --wait --timeout 300s >/dev/null
  kubectl_ctx -n kubeflow-system rollout status deploy/kubeflow-trainer-controller-manager --timeout=180s
}

# Remove Kubeflow Trainer installed by install_kubeflow_trainer.
uninstall_kubeflow_trainer() {
  step "Uninstalling Kubeflow Trainer"
  helm_ctx uninstall kubeflow-trainer --namespace kubeflow-system --ignore-not-found --wait || true
  kubectl_ctx delete namespace kubeflow-system --ignore-not-found >/dev/null 2>&1 || true
}

# Install the CodeFlare AppWrapper operator from its release manifest
# (scenario-scoped, not part of install_base). It ships a single install.yaml
# (namespace appwrapper-system, the appwrappers.workload.codeflare.dev CRD, and
# the controller) and self-manages its webhook TLS (no cert-manager needed).
# --server-side avoids the large-CRD annotation limit; --force-conflicts keeps
# re-applies idempotent. AppWrapper is a built-in Kueue integration
# (workload.codeflare.dev/appwrapper, already enabled in base/kueue-values.yaml),
# so once the operator is present Kueue can manage AppWrappers.
install_appwrapper() {
  step "Installing the AppWrapper operator (release v${APPWRAPPER_VERSION})"
  kubectl_ctx apply --server-side --force-conflicts \
    -f "https://github.com/project-codeflare/appwrapper/releases/download/v${APPWRAPPER_VERSION}/install.yaml" >/dev/null
  kubectl_ctx -n appwrapper-system rollout status deploy/appwrapper-controller-manager --timeout=180s
}

# Remove the AppWrapper operator installed by install_appwrapper.
uninstall_appwrapper() {
  step "Uninstalling the AppWrapper operator"
  kubectl_ctx delete \
    -f "https://github.com/project-codeflare/appwrapper/releases/download/v${APPWRAPPER_VERSION}/install.yaml" \
    --ignore-not-found >/dev/null 2>&1 || true
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

# kai_gpu_job <ns> <queue> <name> <gpus> [priorityClassName]
# Emits a batch/v1 Job (one long-lived pod) scheduled by KAI: the pod carries
# schedulerName=kai-scheduler and the kai.scheduler/queue label so KAI builds a
# PodGroup for it. Unlike gpu_job (Kueue) it is NOT suspended - KAI admits pods
# directly via the scheduler.
#
# The container is a plain `sleep` (busybox), NOT `pause`: when KAI evicts a pod
# for preemption/reclaim, pause installs a SIGTERM handler and exits 0, so the
# Job would count that as success and never recreate it. `sleep` has no handler,
# so eviction kills it with a non-zero exit; with the high backoffLimit the Job
# recreates the pod, which then sits visibly Pending (the preempted work waiting
# for GPUs) instead of vanishing. Default priorityClassName is train
# (preemptible); grace period is short so eviction is quick.
kai_gpu_job() {
  local ns="$1" queue="$2" name="$3" gpus="$4" prio="${5:-train}"
  echo "---"
  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $name
  namespace: $ns
spec:
  parallelism: 1
  completions: 1
  backoffLimit: 100
  template:
    metadata:
      labels:
        kai.scheduler/queue: $queue
        # mirror the priority class as a plain label so waits/inspection can
        # distinguish priorities within a single queue (queue label alone can't)
        gpu-lab/priority: $prio
    spec:
      schedulerName: kai-scheduler
      priorityClassName: $prio
      restartPolicy: Never
      terminationGracePeriodSeconds: 5
      containers:
        - name: c
          image: busybox:1.36
          command: ["sleep", "100000"]
          resources:
            requests:
              cpu: "100m"
              nvidia.com/gpu: "$gpus"
            limits:
              nvidia.com/gpu: "$gpus"
EOF
}

# submit_kai_jobs <ns> <queue> <name-prefix> <count> <gpus> [priorityClassName]
# Applies <count> KAI-scheduled GPU jobs named <prefix>-1 .. <prefix>-<count>.
submit_kai_jobs() {
  local ns="$1" queue="$2" prefix="$3" count="$4" gpus="$5" prio="${6:-train}" i
  for i in $(seq 1 "$count"); do
    kai_gpu_job "$ns" "$queue" "${prefix}-${i}" "$gpus" "$prio"
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

# show_first_pending_reason <ns> - print the conditions of the first workload in
# the namespace that is not yet Admitted (i.e. the quota-blocked one).
show_first_pending_reason() {
  local ns="$1" wl admitted
  for wl in $(kubectl_ctx get workloads -n "$ns" -o name 2>/dev/null); do
    admitted=$(kubectl_ctx get "$wl" -n "$ns" \
      -o jsonpath='{.status.conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)
    if [ "$admitted" != "True" ]; then
      kubectl_ctx get "$wl" -n "$ns" \
        -o jsonpath='{range .status.conditions[*]}{"    "}{.type}{": "}{.reason}{" - "}{.message}{"\n"}{end}'
      return
    fi
  done
}

# count_admitted <ns>  -> number of workloads with Admitted=True
count_admitted() {
  kubectl_ctx get workloads -n "$1" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Admitted")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c True || true
}

# ---------------------------------------------------------------------------
# KAI Scheduler inspection helpers (shared by the kai-* queue scenarios)
# ---------------------------------------------------------------------------
# wait_for_pods_phase <count> <phase> <ns> [label-selector] [tries] - poll until
# at least <count> pods in <ns> (optionally matching a label selector) reach
# <phase>. Polls <tries> times (default 60) 2s apart. Returns non-zero on timeout
# so callers can decide whether that is fatal.
wait_for_pods_phase() {
  local want="$1" phase="$2" ns="$3" sel="${4:-}" tries="${5:-60}" i n
  for i in $(seq 1 "$tries"); do
    if [ -n "$sel" ]; then
      n=$(kubectl_ctx get pods -n "$ns" -l "$sel" \
        --field-selector "status.phase=$phase" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    else
      n=$(kubectl_ctx get pods -n "$ns" \
        --field-selector "status.phase=$phase" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    fi
    [ "$n" -ge "$want" ] && return 0
    sleep 2
  done
  return 1
}

# inspect_kai_queues <queue>... - table of KAI queues showing each queue's gpu
# quota (guaranteed share), hard limit, and the live allocated/requested gpu from
# .status, so quota vs over-quota borrowing is visible at a glance. A limit of
# -1 means "unbounded" (borrow up to cluster capacity).
inspect_kai_queues() {
  kubectl_ctx get queues.scheduling.run.ai "$@" -o custom-columns=\
'QUEUE:.metadata.name,'\
'GPU_QUOTA:.spec.resources.gpu.quota,'\
'GPU_LIMIT:.spec.resources.gpu.limit,'\
'GPU_ALLOC:.status.allocated.nvidia\.com/gpu,'\
'GPU_REQ:.status.requested.nvidia\.com/gpu' 2>/dev/null | sed 's/^/    /' \
    || echo "    (none)"
}

# inspect_kai_pods <ns> - pods in <ns> with their phase, KAI queue, priority
# class and node, sorted by queue then phase so Running vs Pending per queue is
# easy to read.
inspect_kai_pods() {
  local ns="$1" out
  out=$(kubectl_ctx get pods -n "$ns" -o custom-columns=\
'POD:.metadata.name,'\
'PHASE:.status.phase,'\
'QUEUE:.metadata.labels.kai\.scheduler/queue,'\
'PRIORITY:.spec.priorityClassName,'\
'NODE:.spec.nodeName' 2>/dev/null)
  if [ -z "$out" ]; then echo "    (none)"; return; fi
  # print the header, then the body sorted by queue then phase (no head/tail on a
  # single pipe - that races and can drop rows)
  { printf '%s\n' "$out" | head -n1
    printf '%s\n' "$out" | tail -n +2 | sort -k3,3 -k2,2
  } | sed 's/^/    /'
}

# inspect_kai_events <ns> - recent scheduling events in <ns> that reveal KAI
# preemption/reclaim/eviction activity (empty if none happened).
inspect_kai_events() {
  local ns="$1" out
  out=$(kubectl_ctx get events -n "$ns" --sort-by=.lastTimestamp 2>/dev/null \
    | grep -Ei 'evict|reclaim|preempt' | tail -n 15 || true)
  if [ -n "$out" ]; then
    echo "$out" | sed 's/^/    /'
  else
    echo "    (no preemption/reclaim events yet)"
  fi
}
