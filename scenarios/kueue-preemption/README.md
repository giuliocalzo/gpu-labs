# kueue-preemption scenario

Tests Kueue **preemption**: a higher-priority workload evicting a running
lower-priority one to fit within the same ClusterQueue's quota.

## What it tests

- With the queue already full of low-priority work, submitting high-priority
  workloads causes Kueue to **evict (preempt) running low-priority workloads**
  to make room.
- This is the active counterpart to `kueue-workload-priority`: there the queue starts
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

## Sample output

Captured from a fresh `./demo.sh kueue-preemption` run (the inspection step):

```text
==> Inspection: kueue-preemption
--- Workloads in 'preemption' (priority / reserved / admitted) ---
NAME               QUEUE              PRIORITY   RESERVED   ADMITTED
job-high-1-3a5e7   preemption-queue   1000       True       True
job-high-2-9f5bc   preemption-queue   1000       True       True
job-low-1-4eb61    preemption-queue   100        True       True
job-low-2-4368e    preemption-queue   100        True       True
job-low-3-f31cb    preemption-queue   100        False      False
job-low-4-9dd00    preemption-queue   100        False      False

--- ClusterQueue 'preemption-cq' ---
NAME            PENDING   ADMITTED   RESERVING
preemption-cq   2         4          4
    reserved gpu-flavor: cpu=200m nvidia.com/gpu=32

--- Preempted workloads (evicted to make room) ---
    WORKLOAD          MESSAGE
    job-low-3-f31cb   Preempted to accommodate a workload (UID: b5743c4d-4f61-4c4f-ad4c-b88b0ba861b0, JobUID: 0152b2bb-6bfe-4e7a-b8b7-371ce3d4dbf0)
    job-low-4-9dd00   Preempted to accommodate a workload (UID: 5798f8d7-fb4d-40c3-92fe-d8b9b6ee7913, JobUID: bc48821e-cb3c-4964-ae50-4a5e842d891e)
```

**What it shows:** The four low-priority jobs were admitted first and filled the
quota (`nvidia.com/gpu=32`). When the two `job-high-*` (priority 1000) workloads
arrived, Kueue **evicted** two running low-priority workloads (`job-low-3`,
`job-low-4` — see the "Preempted to accommodate a workload" messages) to make
room. The final state: both high-priority workloads plus two surviving
low-priority ones are `ADMITTED: True`, while the two preempted ones are back to
`PENDING`. Unlike `kueue-workload-priority`, here priority acts on *already
running* work — that is preemption.
