# LWS + Kueue + TAS on kind — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a one-command, reproducible kind lab that shows LeaderWorkerSet, Kueue, and Topology-Aware Scheduling working together — admitting two co-located groups and blocking a third on quota — using placeholder pods and a fake per-node accelerator.

**Architecture:** A kind cluster (1 control-plane + 8 labeled workers in a block→rack→host hierarchy) where each worker advertises a fake `example.com/gpu` extended resource. Kueue (v0.18.3) manages a TAS-enabled ResourceFlavor/ClusterQueue/LocalQueue; LWS (v0.9.0) groups are admitted by Kueue and placed by TAS. A single `run.sh` orchestrates everything with narrated steps and a rich inspection at the end.

**Tech Stack:** kind, kubectl, bash, Kueue v0.18.3, LeaderWorkerSet v0.9.0, kind node image v1.33.1.

---

## File Structure

```
run.sh                        # orchestrator: preflight → cluster → gpus → installs → resources → workloads → inspect
README.md                     # what it is, prerequisites, how to run, what to look for, cleanup
kind/kind-cluster.yaml        # 1 control-plane + 8 workers with topology labels
manifests/kueue-tas.yaml      # Namespace, Topology, ResourceFlavor, ClusterQueue, LocalQueue
manifests/lws-groups.yaml     # LeaderWorkerSet, replicas: 2, size: 4 (the two admitted groups)
manifests/lws-overflow.yaml   # LeaderWorkerSet, replicas: 1, size: 4 (the quota-blocked group)
.gitignore
```

Confirmed upstream facts (2026-07):
- Kueue objects use `apiVersion: kueue.x-k8s.io/v1beta2` at v0.18.x.
- TAS is beta/on-by-default since v0.14; the LWS integration is on-by-default (no custom Kueue config needed).
- Install URLs (both use internal certs, no cert-manager):
  - LWS: `https://github.com/kubernetes-sigs/lws/releases/download/v0.9.0/manifests.yaml` → Deployment `lws-controller-manager` in ns `lws-system`.
  - Kueue: `https://github.com/kubernetes-sigs/kueue/releases/download/v0.18.3/manifests.yaml` → Deployment `kueue-controller-manager` in ns `kueue-system`.
- TAS annotations on **both** LWS leader & worker templates: `kueue.x-k8s.io/podset-preferred-topology` + `kueue.x-k8s.io/podset-group-name` (same value).

---

## Task 1: Repo scaffolding

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# Editor / OS
.DS_Store
*.swp

# Local kubeconfig exports if any
*.kubeconfig
kubeconfig
```

- [ ] **Step 2: Verify the file exists**

Run: `ls -la .gitignore`
Expected: file is listed.

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -s -m "chore: add .gitignore"
```

---

## Task 2: kind cluster config

**Files:**
- Create: `kind/kind-cluster.yaml`

- [ ] **Step 1: Create `kind/kind-cluster.yaml`**

8 workers across 2 blocks × 2 racks × 2 hosts. Every worker carries `cloud.provider.com/node-group: tas-group` (the ResourceFlavor selector) plus block/rack labels.

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kueue-tas-demo
nodes:
  - role: control-plane
  # ---- block-1 / rack-1 ----
  - role: worker
    labels:
      cloud.provider.com/node-group: tas-group
      cloud.provider.com/topology-block: block-1
      cloud.provider.com/topology-rack: rack-1
  - role: worker
    labels:
      cloud.provider.com/node-group: tas-group
      cloud.provider.com/topology-block: block-1
      cloud.provider.com/topology-rack: rack-1
  # ---- block-1 / rack-2 ----
  - role: worker
    labels:
      cloud.provider.com/node-group: tas-group
      cloud.provider.com/topology-block: block-1
      cloud.provider.com/topology-rack: rack-2
  - role: worker
    labels:
      cloud.provider.com/node-group: tas-group
      cloud.provider.com/topology-block: block-1
      cloud.provider.com/topology-rack: rack-2
  # ---- block-2 / rack-3 ----
  - role: worker
    labels:
      cloud.provider.com/node-group: tas-group
      cloud.provider.com/topology-block: block-2
      cloud.provider.com/topology-rack: rack-3
  - role: worker
    labels:
      cloud.provider.com/node-group: tas-group
      cloud.provider.com/topology-block: block-2
      cloud.provider.com/topology-rack: rack-3
  # ---- block-2 / rack-4 ----
  - role: worker
    labels:
      cloud.provider.com/node-group: tas-group
      cloud.provider.com/topology-block: block-2
      cloud.provider.com/topology-rack: rack-4
  - role: worker
    labels:
      cloud.provider.com/node-group: tas-group
      cloud.provider.com/topology-block: block-2
      cloud.provider.com/topology-rack: rack-4
```

- [ ] **Step 2: Validate YAML parses**

Run: `python3 -c "import yaml,sys; list(yaml.safe_load_all(open('kind/kind-cluster.yaml')))" && echo OK`
Expected: `OK` (no traceback).

- [ ] **Step 3: Commit**

```bash
git add kind/kind-cluster.yaml
git commit -s -m "feat: add kind cluster config with block/rack topology labels"
```

---

## Task 3: Kueue TAS resources

**Files:**
- Create: `manifests/kueue-tas.yaml`

- [ ] **Step 1: Create `manifests/kueue-tas.yaml`**

`nominalQuota` for `example.com/gpu` is `8` (matches total fake GPUs), so the 3rd group is quota-blocked. The flavor selects worker nodes via `nodeLabels` and enables TAS via `topologyName`.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kueue-demo
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: Topology
metadata:
  name: default
spec:
  levels:
    - nodeLabel: cloud.provider.com/topology-block
    - nodeLabel: cloud.provider.com/topology-rack
    - nodeLabel: kubernetes.io/hostname
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: ResourceFlavor
metadata:
  name: gpu-flavor
spec:
  nodeLabels:
    cloud.provider.com/node-group: tas-group
  topologyName: default
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: tas-cluster-queue
spec:
  namespaceSelector: {}
  resourceGroups:
    - coveredResources: ["cpu", "example.com/gpu"]
      flavors:
        - name: gpu-flavor
          resources:
            - name: cpu
              nominalQuota: "100"
            - name: example.com/gpu
              nominalQuota: "8"
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: LocalQueue
metadata:
  namespace: kueue-demo
  name: tas-local-queue
spec:
  clusterQueue: tas-cluster-queue
```

- [ ] **Step 2: Validate YAML parses**

Run: `python3 -c "import yaml,sys; list(yaml.safe_load_all(open('manifests/kueue-tas.yaml')))" && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add manifests/kueue-tas.yaml
git commit -s -m "feat: add Kueue TAS resources (Topology, flavor, cluster/local queue)"
```

---

## Task 4: Admitted LWS groups

**Files:**
- Create: `manifests/lws-groups.yaml`

- [ ] **Step 1: Create `manifests/lws-groups.yaml`**

`replicas: 2`, `size: 4` → two groups of 4 pods, each pod requesting 1 fake GPU. `preferred-topology: rack` forces rack→block fallback (rack holds only 2 GPUs, a group needs 4). Extended-resource requests and limits are set equal (Kubernetes requires this for extended resources).

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: lws-groups
  namespace: kueue-demo
  labels:
    kueue.x-k8s.io/queue-name: tas-local-queue
spec:
  replicas: 2
  leaderWorkerTemplate:
    size: 4
    leaderTemplate:
      metadata:
        annotations:
          kueue.x-k8s.io/podset-preferred-topology: cloud.provider.com/topology-rack
          kueue.x-k8s.io/podset-group-name: lws-group
      spec:
        containers:
          - name: leader
            image: registry.k8s.io/pause:3.10
            resources:
              requests:
                cpu: "50m"
                example.com/gpu: "1"
              limits:
                example.com/gpu: "1"
    workerTemplate:
      metadata:
        annotations:
          kueue.x-k8s.io/podset-preferred-topology: cloud.provider.com/topology-rack
          kueue.x-k8s.io/podset-group-name: lws-group
      spec:
        containers:
          - name: worker
            image: registry.k8s.io/pause:3.10
            resources:
              requests:
                cpu: "50m"
                example.com/gpu: "1"
              limits:
                example.com/gpu: "1"
```

- [ ] **Step 2: Validate YAML parses**

Run: `python3 -c "import yaml,sys; list(yaml.safe_load_all(open('manifests/lws-groups.yaml')))" && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add manifests/lws-groups.yaml
git commit -s -m "feat: add admitted LWS groups (2 replicas, size 4, TAS annotations)"
```

---

## Task 5: Overflow LWS group

**Files:**
- Create: `manifests/lws-overflow.yaml`

- [ ] **Step 1: Create `manifests/lws-overflow.yaml`**

Identical shape but `replicas: 1`; submitted after the first two saturate all 8 GPUs so its Workload stays Pending (quota exhausted).

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: lws-overflow
  namespace: kueue-demo
  labels:
    kueue.x-k8s.io/queue-name: tas-local-queue
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 4
    leaderTemplate:
      metadata:
        annotations:
          kueue.x-k8s.io/podset-preferred-topology: cloud.provider.com/topology-rack
          kueue.x-k8s.io/podset-group-name: lws-group
      spec:
        containers:
          - name: leader
            image: registry.k8s.io/pause:3.10
            resources:
              requests:
                cpu: "50m"
                example.com/gpu: "1"
              limits:
                example.com/gpu: "1"
    workerTemplate:
      metadata:
        annotations:
          kueue.x-k8s.io/podset-preferred-topology: cloud.provider.com/topology-rack
          kueue.x-k8s.io/podset-group-name: lws-group
      spec:
        containers:
          - name: worker
            image: registry.k8s.io/pause:3.10
            resources:
              requests:
                cpu: "50m"
                example.com/gpu: "1"
              limits:
                example.com/gpu: "1"
```

- [ ] **Step 2: Validate YAML parses**

Run: `python3 -c "import yaml,sys; list(yaml.safe_load_all(open('manifests/lws-overflow.yaml')))" && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add manifests/lws-overflow.yaml
git commit -s -m "feat: add overflow LWS group to demonstrate quota blocking"
```

---

## Task 6: Orchestrator `run.sh`

**Files:**
- Create: `run.sh`

- [ ] **Step 1: Create `run.sh`**

```bash
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
```

- [ ] **Step 2: Make it executable and shell-check the syntax**

Run: `chmod +x run.sh && bash -n run.sh && echo OK`
Expected: `OK` (no syntax errors).

- [ ] **Step 3: Commit**

```bash
git add run.sh
git commit -s -m "feat: add run.sh orchestrator with narrated steps and inspection"
```

---

## Task 7: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Create `README.md`**

````markdown
# kueue-demo-lab: LeaderWorkerSet + Kueue + Topology-Aware Scheduling on kind

A self-contained local lab that shows how **LeaderWorkerSet (LWS)**, **Kueue**, and
**Topology-Aware Scheduling (TAS)** fit together. It stands up every resource needed —
there is **no real workload** (all pods are `pause` placeholders) and **no real GPU**
(each node advertises a fake `example.com/gpu`).

## What it demonstrates

- Kueue admission via a ClusterQueue/LocalQueue and a TAS-enabled ResourceFlavor.
- LWS groups admitted as a unit by Kueue.
- TAS co-location: each group of 4 can't fit in a 2-GPU rack, so it falls back to a
  **block** and all 4 pods land in the same block. Two groups fill the two blocks.
- Admission gating: a third group exceeds the `example.com/gpu` quota (8) and stays
  **Pending**.

## Topology

```
block-1                         block-2
├─ rack-1: worker (gpu:1) x2    ├─ rack-3: worker (gpu:1) x2
└─ rack-2: worker (gpu:1) x2    └─ rack-4: worker (gpu:1) x2
```

## Prerequisites

- Docker (running)
- [kind](https://kind.sigs.k8s.io/) and `kubectl` in your `PATH`
- ~9 containers' worth of resources (1 control-plane + 8 workers)

## Run

```bash
./run.sh
```

The script narrates each step: preflight → create cluster → advertise fake GPUs →
install LWS → install Kueue → apply TAS resources → submit two groups → submit the
overflow group → inspection.

Pinned versions live at the top of `run.sh` (`KUEUE_VERSION`, `LWS_VERSION`,
`KIND_NODE_IMAGE`, `CLUSTER_NAME`). Override `KIND_NODE_IMAGE` if it isn't compatible
with your installed kind version.

## What to look for

- **Workloads**: the two `lws-groups` workloads show `ADMITTED: True`; the
  `lws-overflow` workload does not.
- **Pod placement**: every pod in a group shares the same `BLOCK`, and the two groups
  use different blocks.
- **ClusterQueue**: `example.com/gpu` reserved is `8` (fully used); the overflow
  workload's condition explains it is waiting for quota.

## Re-inspect later

```bash
kubectl get workloads -n kueue-demo
kubectl get pods -n kueue-demo -o wide
kubectl describe clusterqueue tas-cluster-queue
```

## Cleanup

```bash
kind delete cluster --name kueue-tas-demo
```
````

- [ ] **Step 2: Verify it renders as valid markdown (basic check)**

Run: `test -s README.md && head -1 README.md`
Expected: prints the title line.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -s -m "docs: add README with usage, expectations, and cleanup"
```

---

## Task 8: End-to-end verification

**Files:** none (runtime verification)

- [ ] **Step 1: Run the full demo**

Run: `./run.sh`
Expected: completes without error and prints the inspection sections.

- [ ] **Step 2: Verify the two groups are admitted and co-located**

Run:
```bash
kubectl get workloads -n kueue-demo \
  -o custom-columns=NAME:.metadata.name,ADMITTED:'.status.conditions[?(@.type=="Admitted")].status'
```
Expected: the two `lws-groups-*` workloads show `True`.

Run (co-location check — each group index should map to exactly one block):
```bash
kubectl get pods -n kueue-demo \
  -o jsonpath='{range .items[*]}{.metadata.labels.leaderworkerset\.sigs\.k8s\.io/group-index}{" "}{.spec.nodeName}{"\n"}{end}' \
  | while read -r g n; do b=$(kubectl get node "$n" -o jsonpath='{.metadata.labels.cloud\.provider\.com/topology-block}'); echo "group=$g block=$b"; done | sort -u
```
Expected: group `0` → one block, group `1` → the other block (two distinct lines per group are NOT expected; each group maps to a single block).

- [ ] **Step 3: Verify the overflow group is blocked**

Run:
```bash
kubectl get workloads -n kueue-demo \
  -o custom-columns=NAME:.metadata.name,ADMITTED:'.status.conditions[?(@.type=="Admitted")].status' | grep overflow
```
Expected: the `lws-overflow-*` workload shows a value other than `True` (blank/`<none>`/`False`).

- [ ] **Step 4: If everything passes, tag the working state with a commit**

```bash
git commit -s --allow-empty -m "test: verified end-to-end demo (groups admitted+co-located, overflow blocked)"
```

- [ ] **Step 5: (Optional) Tear down**

Run: `kind delete cluster --name kueue-tas-demo`
Expected: cluster removed.

---

## Notes for the implementer

- **Extended resources** must have `requests == limits` (already reflected in the LWS
  manifests). The JSON-pointer escape for `example.com/gpu` in the node patch is
  `example.com~1gpu` (`~1` = `/`).
- **`kubectl wait --for=condition=Admitted`** works because Workloads expose a standard
  `Admitted` condition. If a timing flake occurs, re-running `run.sh` on the existing
  cluster is safe (it reuses the cluster and re-applies manifests).
- **Do not** add a custom Kueue Configuration for the LWS integration — it is enabled by
  default at v0.18.x. Adding one would require also re-enabling other default frameworks.
- If a machine can't handle 8 workers, reduce to 2 blocks × 2 racks × 1 node and set
  `example.com/gpu` quota to 4, with `size: 2` groups — but the default 8-worker layout
  is the intended demo.
```
