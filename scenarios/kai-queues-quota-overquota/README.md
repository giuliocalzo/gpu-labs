# kai-queues-quota-overquota scenario

Tests the **NVIDIA KAI Scheduler's queue model**: guaranteed **quota**,
**over-quota borrowing** of idle capacity, and the per-queue **hard limit** that
caps borrowing — see the
[KAI scheduling docs](https://github.com/NVIDIA/KAI-Scheduler/tree/main/docs/queues).

A KAI `Queue` has three knobs per resource:

- **`quota`** — the queue's *guaranteed* share. It can always get up to this much.
- **`limit`** — the *hard cap* on total consumption (quota + borrowed). `-1` = unbounded.
- **`overQuotaWeight`** — how idle surplus is divided between sibling queues.

## What it tests

1. **Guaranteed quota.** `quota-team-a` is guaranteed 16 GPUs.
2. **Over-quota borrowing.** With `quota-team-b` idle, its 16-GPU share (and the
   rest of the cluster) is surplus. `team-a` borrows past its own 16-GPU quota.
3. **The hard limit caps borrowing.** `team-a`'s `limit` is 32, so KAI admits
   exactly 32 GPUs (4 jobs) and leaves the rest Pending — **even though the
   cluster still has free GPUs**. The limit, not capacity, is the bottleneck.

## How it works

- `pre_run` installs the KAI Scheduler (pinned by `KAI_VERSION`).
- `manifests/queues.yaml`: a queue hierarchy `quota-root → {quota-team-a,
  quota-team-b}`. `team-a` has `gpu: {quota: 16, limit: 32}`; `team-b` has
  `gpu: {quota: 16, limit: -1}` and stays idle. cpu/memory are unbounded so GPU
  is the only binding resource.
- The scenario submits **5 jobs** to `team-a`, each a `sleep` placeholder pod
  holding a whole 8-GPU node (40 GPUs wanted). Jobs carry `schedulerName: kai-scheduler` and the
  `kai.scheduler/queue` label, so KAI builds a `PodGroup` per job and schedules
  the pods directly (no Kueue suspend involved).

## Run

```bash
./demo.sh kai-queues-quota-overquota
./demo.sh clean kai-queues-quota-overquota
```

## What to look for

- In the queue table, `quota-team-a` shows `GPU_QUOTA=16`, `GPU_LIMIT=32` and
  `GPU_ALLOC=32`: it is using **twice its quota** by borrowing over-quota.
- 4 of the 5 jobs' pods are `Running`; 1 pod stays `Pending`.
- The Pending pod is blocked by `team-a`'s 32-GPU limit, not by cluster capacity
  (the cluster has 64 GPUs and `team-b` is using none).

## Sample output

Captured from a fresh `./demo.sh kai-queues-quota-overquota` run (the inspection step):

```text
==> Inspection: kai-queues-quota-overquota
--- KAI queues (quota = guaranteed, limit = hard cap, alloc = live usage) ---
    QUEUE          GPU_QUOTA   GPU_LIMIT   GPU_ALLOC   GPU_REQ
    quota-root     -1          -1          32          40
    quota-team-a   16          32          32          40
    quota-team-b   16          -1          <none>      <none>

--- Jobs submitted to 'quota-team-a' ---
    NAME   STATUS    COMPLETIONS   DURATION   AGE
    a-1    Running   0/1           33s        33s
    a-2    Running   0/1           33s        33s
    a-3    Running   0/1           33s        33s
    a-4    Running   0/1           33s        33s
    a-5    Running   0/1           33s        33s

--- Pods (4 Running up to the limit, 1 Pending above it) ---
    POD         PHASE     QUEUE          PRIORITY   NODE
    a-5-mmvvw   Pending   quota-team-a   train      <none>
    a-1-ncwt9   Running   quota-team-a   train      gpu-lab-worker
    a-2-hpk5q   Running   quota-team-a   train      gpu-lab-worker2
    a-3-2pfs2   Running   quota-team-a   train      gpu-lab-worker3
    a-4-wprzz   Running   quota-team-a   train      gpu-lab-worker4
```

**What it shows:** `quota-team-a` has a 16-GPU quota but is *allocated 32* GPUs —
it has borrowed 16 GPUs of **over-quota** from the idle cluster capacity (`team-b`
uses none). It requested 40 (`GPU_REQ`), so 4 jobs run (32 GPUs) and the 5th pod
(`a-5`) stays `Pending`: `team-a`'s hard **limit** of 32 caps it, even though 32
GPUs are still free cluster-wide. Raising `team-a`'s `limit` would admit `a-5`.
