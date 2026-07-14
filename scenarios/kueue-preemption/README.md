# kueue-preemption scenario

Tests Kueue **preemption**: a higher-priority workload evicting a running
lower-priority one to fit within the same ClusterQueue's quota.

## What it tests

- With the queue already full of low-priority work, submitting high-priority
  workloads causes Kueue to **evict (preempt) running low-priority workloads**
  to make room.
- This is the active counterpart to `workload-priority`: there the queue starts
  empty and priority only sets admission *order*; here priority causes *eviction*
  of already-admitted work.

## How it works

- Two `WorkloadPriorityClass` objects: `pe-high` (value 1000) and `pe-low`
  (value 100).
- `preemption-cq` grants `nvidia.com/gpu: 32` and sets
  `preemption.withinClusterQueue: LowerPriority` (a workload may preempt
  lower-priority workloads in the same queue).
- Step 1: submit 4 low-priority jobs × 8 GPUs → fills the 32-GPU quota.
- Step 2: submit 2 high-priority jobs × 8 GPUs → no free quota, so Kueue
  preempts 2 low-priority workloads.

## Run

```bash
./demo.sh kueue-preemption
./demo.sh clean kueue-preemption
```

## What to look for

- Final state: 2 `high-*` Workloads `ADMITTED: True` and 2 `low-*` Workloads
  evicted (back to Pending); the other 2 low-priority ones keep running.
- The inspection prints `Preempted` events naming which low-priority workloads
  were evicted and the preemptor/preemptee priorities.
- `preemption-cq` stays at `nvidia.com/gpu=32` reserved (2 high + 2 surviving
  low).
