# kueue-workload-priority scenario

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
./demo.sh kueue-workload-priority
./demo.sh clean kueue-workload-priority
```

## What to look for

- After release: the 4 `high-*` Workloads are `ADMITTED: True`; the 4 `low-*`
  Workloads stay Pending.
- The Workload table shows `PRIORITY` 1000 vs 100.
- `priority-cq` reserves `nvidia.com/gpu=32` (4 × 8), fully consumed by the
  high-priority jobs.

## Sample output

Captured from a fresh `./demo.sh kueue-workload-priority` run (the inspection step):

```text
==> Inspection: kueue-workload-priority
--- Workloads in 'priority' (priority / reserved / admitted) ---
NAME               QUEUE            PRIORITY   RESERVED   ADMITTED
job-high-1-f9bfe   priority-queue   1000       True       True
job-high-2-7cb4b   priority-queue   1000       True       True
job-high-3-4826c   priority-queue   1000       True       True
job-high-4-f76ac   priority-queue   1000       True       True
job-low-1-d5309    priority-queue   100        False      <none>
job-low-2-77750    priority-queue   100        False      <none>
job-low-3-cf7ea    priority-queue   100        False      <none>
job-low-4-1abcd    priority-queue   100        False      <none>

--- ClusterQueue 'priority-cq' ---
NAME          PENDING   ADMITTED   RESERVING
priority-cq   4         4          4
    reserved gpu-flavor: cpu=200m nvidia.com/gpu=32
```

**What it shows:** All 8 jobs target the same queue, but the `WorkloadPriorityClass`
values (`PRIORITY` 1000 vs 100) set the admission order. The quota
(`nvidia.com/gpu=32` = 4 × 8 GPUs) only fits four jobs, so Kueue admits the four
`job-high-*` workloads (`ADMITTED: True`) and leaves the four `job-low-*` ones
`PENDING`. This is ordering-by-priority at admission time (not preemption — the
low-priority jobs simply never got in); `priority-cq` shows 4 admitted / 4 pending
with all 32 GPUs reserved by the high-priority jobs.
