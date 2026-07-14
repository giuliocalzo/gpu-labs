# workload-priority scenario

Tests Kueue **WorkloadPriorityClass** controlling the *order* of admission when
quota is scarce - without preempting anything already running.

## What it tests

- When many workloads are queued and quota only fits some of them, Kueue admits
  **higher-priority workloads first**.
- This is admission ordering only: the ClusterQueue has **no preemption**, so
  the point is purely "who gets in first", not "who evicts whom" (see the
  `kueue-preemption` scenario for eviction).

## How it works

- Two `WorkloadPriorityClass` objects: `wp-high` (value 1000) and `wp-low`
  (value 100).
- `priority-cq` grants `nvidia.com/gpu: 32` → room for exactly 4 of the 8-GPU
  jobs.
- To make the ordering deterministic, the queue is created with
  `stopPolicy: Hold`. All 8 jobs (4 low + 4 high) are submitted while admission
  is paused, then the queue is released so Kueue evaluates them together and
  admits strictly by priority. (Without the hold, whichever jobs are created
  first would grab the free quota.)

## Run

```bash
./demo.sh workload-priority
./demo.sh clean workload-priority
```

## What to look for

- After release: the 4 `high-*` Workloads are `ADMITTED: True`; the 4 `low-*`
  Workloads stay Pending.
- The Workload table shows `PRIORITY` 1000 vs 100.
- `priority-cq` reserves `nvidia.com/gpu=32` (4 × 8), fully consumed by the
  high-priority jobs.
