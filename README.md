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
