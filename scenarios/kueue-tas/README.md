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

## Sample output

Captured from a fresh `./demo.sh kueue-tas` run (the inspection step):

```text
==> Inspection: kueue-tas
--- Workloads in 'tas' (priority / reserved / admitted) ---
NAME                                   QUEUE             PRIORITY   RESERVED   ADMITTED
leaderworkerset-lws-groups-0-71032     tas-local-queue   0          True       True
leaderworkerset-lws-groups-1-53661     tas-local-queue   0          True       True
leaderworkerset-lws-overflow-0-b2077   tas-local-queue   0          False      <none>

--- Pod placement by topology in 'tas' ---
POD                                            GROUP    BLOCK    RACK     NODE
lws-groups-1                                   1        block-1  rack-1   gpu-lab-worker
lws-groups-1-1                                 1        block-1  rack-1   gpu-lab-worker2
lws-groups-1-2                                 1        block-1  rack-2   gpu-lab-worker3
lws-groups-1-3                                 1        block-1  rack-2   gpu-lab-worker4
lws-groups-0                                   0        block-2  rack-3   gpu-lab-worker5
lws-groups-0-1                                 0        block-2  rack-3   gpu-lab-worker6
lws-groups-0-2                                 0        block-2  rack-4   gpu-lab-worker7
lws-groups-0-3                                 0        block-2  rack-4   gpu-lab-worker8

Pods not yet scheduled (gated by Kueue):
    lws-overflow-0 (Pending)
    lws-overflow-0-1 (Pending)
    lws-overflow-0-2 (Pending)
    lws-overflow-0-3 (Pending)

--- ClusterQueue 'tas-cluster-queue' ---
NAME                PENDING   ADMITTED   RESERVING
tas-cluster-queue   1         2          2
    reserved tas-gpu-flavor: cpu=400m nvidia.com/gpu=64

--- Why is the overflow group pending? ---
    QuotaReserved: Pending - couldn't assign flavors to pod set leader: insufficient unused quota for nvidia.com/gpu in flavor tas-gpu-flavor, 32 more needed; couldn't assign flavors to pod set worker: insufficient unused quota for nvidia.com/gpu in flavor tas-gpu-flavor, 32 more needed
    PodsReady: WaitForStart - Not all pods are ready or succeeded
```

**What it shows:** The two `lws-groups` groups are admitted (`ADMITTED: True`)
and their 8 pods are placed so that each 4-pod group sits entirely inside one
block — group 1 in `block-1` (racks 1–2), group 0 in `block-2` (racks 3–4) —
because a rack (2 nodes) can't hold a 4-node group, so TAS falls back to the
block level. Those two groups reserve all `nvidia.com/gpu=64`, so the third
`lws-overflow` group can't be admitted: its Workload is `Pending` with an
explicit "insufficient unused quota ... 32 more needed" message and its 4 pods
stay Kueue-gated (never created as schedulable pods).
