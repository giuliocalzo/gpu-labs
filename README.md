# kueue-demo-lab: LeaderWorkerSet + Kueue + Topology-Aware Scheduling on kind

A self-contained local lab that shows how **LeaderWorkerSet (LWS)**, **Kueue**, and
**Topology-Aware Scheduling (TAS)** fit together. It stands up every resource needed —
there is **no real workload** (all pods are `pause` placeholders) and **no real GPU**
(each node advertises **8** fake `nvidia.com/gpu`, like a real 8-GPU node).

## What it demonstrates

- Kueue admission via a ClusterQueue/LocalQueue and a TAS-enabled ResourceFlavor.
- LWS groups admitted as a unit by Kueue.
- TAS co-location: each pod claims a whole 8-GPU node (canonical multinode serving),
  so a size-4 group needs 4 nodes. A 2-node rack can't hold it, so TAS falls back to a
  **block** (4 nodes) and all 4 pods land in the same block. Two groups fill the two
  blocks.
- Admission gating: a third group would exceed the `nvidia.com/gpu` quota (64) and the
  available capacity, so it stays **Pending**.

## Topology

```
block-1                          block-2
├─ rack-1: worker (gpu:8) x2     ├─ rack-3: worker (gpu:8) x2
└─ rack-2: worker (gpu:8) x2     └─ rack-4: worker (gpu:8) x2

8 nodes x 8 GPUs = 64 GPUs total   (rack = 16, block = 32)
```

## About GPU requests

The pods request a whole node's worth of GPUs (`nvidia.com/gpu: 8`), mirroring
multinode inference/training where each pod pins to one 8-GPU node.

`nvidia.com/gpu` is a Kubernetes *extended resource*, scheduled in whole-integer
units, so a pod **can** request just a portion of a node instead (e.g. `2` of `8`, so
4 pods share a node). You cannot request fractional units (`0.5`); real sub-GPU
sharing (MIG / time-slicing) works by advertising more integer units per node.

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

If the cluster already exists, `run.sh` reuses it. To delete and rebuild it (so
changes to `kind/kind-cluster.yaml`, e.g. node labels, take effect):

```bash
FORCE_RECREATE=1 ./run.sh
```

Pinned versions live at the top of `run.sh` (`KUEUE_VERSION`, `LWS_VERSION`,
`CLUSTER_NAME`).

## What to look for

- **Workloads**: the two `lws-groups` workloads show `ADMITTED: True`; the
  `lws-overflow` workload does not.
- **Pod placement**: every pod in a group shares the same `BLOCK`, and the two groups
  use different blocks.
- **ClusterQueue**: `nvidia.com/gpu` reserved is `64` (fully used); the overflow
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
