# kueue-tas scenario

Tests **Topology-Aware Scheduling (TAS)** with LeaderWorkerSet groups, plus
Kueue's all-or-nothing group admission and quota gating.

## What it tests

1. **Topology co-location with fallback.** Each pod claims a whole 8-GPU node,
   so a size-4 group needs 4 nodes. A rack holds only 2 nodes, so the requested
   `podset-preferred-topology: rack` can't be satisfied and TAS **falls back to
   the next level up (block)**. All 4 pods of a group land in the same block.
2. **Gang / group admission.** An LWS group is admitted by Kueue as a single
   unit (one Workload per group), not pod-by-pod.
3. **Quota gating.** A third group would exceed the ClusterQueue quota, so it
   stays **Pending** with an explicit "insufficient quota" reason - even though
   admitting individual pods would otherwise be possible.

## How it works

- Uses the `tas-gpu-flavor` ResourceFlavor (the one wired to the `default`
  `Topology`: block → rack → host).
- `tas-cluster-queue` grants `nvidia.com/gpu: 64` (the whole cluster).
- `lws-groups`: `replicas: 2`, `size: 4`, each pod requests `nvidia.com/gpu: 8`
  → 2 groups × 4 nodes = 64 GPUs = both blocks full.
- `lws-overflow`: one more size-4 group (32 GPUs) that no longer fits.

## Run

```bash
./demo.sh kueue-tas
./demo.sh clean kueue-tas
```

## What to look for

- The two `lws-groups` Workloads are `ADMITTED: True`; `lws-overflow` is not.
- In the pod-placement table, all 4 pods of a group share the same `BLOCK`, and
  the two groups occupy different blocks.
- `tas-cluster-queue` shows `nvidia.com/gpu=64` reserved (fully used); the
  overflow Workload's condition explains it is waiting for quota.
