# kai-priority-preemption scenario

Tests **priority-based preemption within a queue** in the **NVIDIA KAI
Scheduler**: when a queue is full, a higher-priority workload preempts (evicts) a
lower-priority, preemptible workload already running in that queue. See the
[KAI priority docs](https://github.com/NVIDIA/KAI-Scheduler/tree/main/docs/priority).

KAI ships predefined priority classes; the two used here are:

| Priority class | Value | Preemptible? |
| -------------- | ----- | ------------ |
| `train`        | 50    | yes (< 100)  |
| `inference`    | 125   | no  (≥ 100)  |

Workloads below priority 100 are *preemptible*; at or above 100 they are not
(and may only consume in-quota resources).

## What it tests

1. **A full queue.** `priority-queue` has `quota == limit == 16` GPUs and no
   over-quota headroom, so it holds exactly 2 of our 8-GPU jobs at once.
2. **Lower priority runs first.** 2 `train` jobs (16 GPUs) fill the queue.
3. **Higher priority preempts.** 2 `inference` jobs arrive. With no free GPUs,
   KAI **preempts** the running `train` pods (lower priority, preemptible) to
   admit the `inference` pods in the same queue.
4. **Preempted work waits.** The evicted `train` jobs are recreated by their Job
   controllers and stay `Pending` until GPUs free up (they cannot preempt the
   higher-priority `inference` pods).

## How it works

- `pre_run` installs the KAI Scheduler (pinned by `KAI_VERSION`).
- `manifests/queues.yaml`: `priority-root → priority-queue` with
  `gpu: {quota: 16, limit: 16}` — a deliberately small, capacity-1 queue so the
  only way in is by preemption.
- `apply` runs two phases: first 2 `train` jobs (`priorityClassName: train`),
  then 2 `inference` jobs (`priorityClassName: inference`). Each job is a `sleep`
  placeholder pod holding a whole 8-GPU node, scheduled by KAI (`schedulerName:
  kai-scheduler`, `kai.scheduler/queue` label).

## Run

```bash
./demo.sh kai-priority-preemption
./demo.sh clean kai-priority-preemption
```

## What to look for

- After phase 1, both `train` pods are `Running` and the queue is full
  (`GPU_ALLOC=16`).
- After phase 2, the 2 `inference` pods are `Running` and the 2 `train` pods are
  `Pending` — preempted to make room.
- The events section lists KAI preemption/eviction events for the `train` pods.

Note: KAI protects a freshly-started workload for a short minimum runtime, so the
preemption typically fires ~1–2 minutes after the `inference` jobs are submitted;
the scenario waits for it before inspecting.

## Sample output

Captured from a fresh `./demo.sh kai-priority-preemption` run (the inspection step):

```text
==> Inspection: kai-priority-preemption
--- KAI queue (quota == limit == 16, so no room without preemption) ---
    QUEUE            GPU_QUOTA   GPU_LIMIT   GPU_ALLOC   GPU_REQ
    priority-root    -1          -1          16          32
    priority-queue   16          16          16          32

--- Pods by priority ('inference' Running, 'train' preempted -> Pending) ---
    POD            PHASE     QUEUE            PRIORITY    NODE
    low-1-7tvlg    Pending   priority-queue   train       <none>
    low-2-wnrgx    Pending   priority-queue   train       <none>
    high-1-wtqvt   Running   priority-queue   inference   gpu-lab-worker3
    high-2-sd9b7   Running   priority-queue   inference   gpu-lab-worker4

--- KAI scheduling events (preemption of 'train' pods) ---
    11s  Evict  podgroup/pg-low-2-... Pod kai-priority/low-2-hrznl was preempted by higher priority workload pg-high-1-...
    11s  Evict  podgroup/pg-low-1-... Pod kai-priority/low-1-tx84s was preempted by higher priority workload pg-high-2-...
```

**What it shows:** The queue's `quota == limit == 16` GPUs, so it holds only the 2
`train` jobs that filled it in phase 1. When the 2 higher-priority `inference` jobs
arrive, KAI **preempts** the running `train` pods (lower priority, preemptible) and
schedules `inference` in their place (`GPU_ALLOC` stays 16, `GPU_REQ` is 32 — twice
the capacity). The evicted `train` jobs are recreated by their Job controllers and
sit `Pending`, unable to preempt the higher-priority `inference` pods, until GPUs
free up. The events name each preemption (`low-*` preempted by `pg-high-*`).
