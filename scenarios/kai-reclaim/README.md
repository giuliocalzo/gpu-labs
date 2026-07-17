# kai-reclaim scenario

Tests **inter-queue reclaim** in the **NVIDIA KAI Scheduler**: a queue that is
below its guaranteed quota can *reclaim* resources that a sibling queue borrowed
as over-quota, by evicting the sibling's preemptible pods — while never pushing
the sibling below its own guaranteed quota. See the
[KAI reclaim docs](https://github.com/NVIDIA/KAI-Scheduler/tree/main/docs/queues).

This is what makes over-quota borrowing safe: idle capacity is lent out for high
utilisation, but the owner can always take its guarantee back.

## What it tests

1. **Over-quota borrowing.** `reclaim-team-a` (quota 32) starts while
   `reclaim-team-b` is idle and borrows the **whole 64-GPU cluster** (32 quota +
   32 over-quota).
2. **Reclaim on demand.** When `reclaim-team-b` (quota 32) submits work, it is
   below its guaranteed share, so KAI **reclaims** 32 GPUs from `team-a` by
   evicting `team-a`'s over-quota pods (they run at the preemptible `train`
   priority).
3. **Quota is protected.** Reclaim stops at `team-a`'s guaranteed 32 GPUs — KAI
   never evicts a queue below its own quota. Both teams end at 32 GPUs.

## How it works

- `pre_run` installs the KAI Scheduler (pinned by `KAI_VERSION`).
- `manifests/queues.yaml`: `reclaim-root → {reclaim-team-a, reclaim-team-b}`, each
  team with `gpu: {quota: 32, limit: -1}` (unbounded, so borrowing is allowed).
- `apply` runs two phases:
  - **Phase 1** — 8 jobs to `team-a` (8 × 8 = 64 GPUs). With `team-b` idle, all 8
    are admitted; `team-a` runs at 64 GPUs (double its quota).
  - **Phase 2** — 4 jobs to `team-b` (32 GPUs). KAI reclaims `team-a`'s over-quota
    to satisfy `team-b`'s guarantee.
- Jobs are `sleep` placeholder pods (one 8-GPU node each) scheduled by KAI
  (`schedulerName: kai-scheduler`, `kai.scheduler/queue` label). Because each job
  has a high `backoffLimit` and the container exits non-zero when evicted, a
  reclaimed pod is recreated by the Job and stays visibly Pending rather than
  disappearing.

## Run

```bash
./demo.sh kai-reclaim
./demo.sh clean kai-reclaim
```

## What to look for

- After phase 1, the queue table shows `reclaim-team-a` `GPU_ALLOC=64` (borrowing).
- After phase 2, both `reclaim-team-a` and `reclaim-team-b` show `GPU_ALLOC=32`.
- In the pod table, `team-a` has 4 pods `Running` and 4 `Pending` (evicted, then
  recreated by their Jobs but with no room), while `team-b` has 4 `Running`.
- The events section lists KAI reclaim/eviction events for `team-a`'s pods.

## Sample output

Captured from a fresh `./demo.sh kai-reclaim` run (the inspection step):

```text
==> Inspection: kai-reclaim
--- KAI queues (both settle at their 32-GPU quota after reclaim) ---
    QUEUE            GPU_QUOTA   GPU_LIMIT   GPU_ALLOC   GPU_REQ
    reclaim-root     -1          -1          64          64
    reclaim-team-a   32          -1          32          32
    reclaim-team-b   32          -1          32          32

--- Pods by queue (team-a: 4 Running + 4 Pending; team-b: 4 Running) ---
    POD         PHASE     QUEUE            PRIORITY   NODE
    a-5-q2g58   Pending   reclaim-team-a   train      <none>
    a-6-5wtkl   Pending   reclaim-team-a   train      <none>
    a-7-ssz75   Pending   reclaim-team-a   train      <none>
    a-8-sr4n4   Pending   reclaim-team-a   train      <none>
    a-1-svtsb   Running   reclaim-team-a   train      gpu-lab-worker
    a-2-wzhmc   Running   reclaim-team-a   train      gpu-lab-worker2
    a-3-qlsmt   Running   reclaim-team-a   train      gpu-lab-worker3
    a-4-4bvtk   Running   reclaim-team-a   train      gpu-lab-worker4
    b-1-7plmc   Running   reclaim-team-b   train      gpu-lab-worker5
    b-2-6rbxc   Running   reclaim-team-b   train      gpu-lab-worker6
    b-3-bjncf   Running   reclaim-team-b   train      gpu-lab-worker7
    b-4-xpttv   Running   reclaim-team-b   train      gpu-lab-worker8

--- KAI scheduling events (reclaim / eviction of team-a's over-quota pods) ---
    (earlier) Evict  pod a-5 ... was preempted by workload pg-b-... (team-b reclaiming)
    ...
    0s  Unschedulable  pg-a-5 ... no nodes with enough resources were found: GPUs
    0s  Unschedulable  pg-a-6 ... no nodes with enough resources were found: GPUs
```

**What it shows:** In phase 1 `reclaim-team-a` borrowed the whole cluster
(`GPU_ALLOC` was 64 — its 32 quota + 32 over-quota). When `reclaim-team-b` submitted
in phase 2, KAI **reclaimed** `team-b`'s guaranteed 32 GPUs by evicting `team-a`'s
over-quota (preemptible) pods — but stopped exactly at `team-a`'s own 32-GPU quota.
Both queues now sit at `GPU_ALLOC=32`: `team-a` keeps 4 pods Running (its protected
quota) while its 4 evicted jobs are recreated and wait `Pending` (Unschedulable —
no free GPUs), and `team-b` runs its 4 pods.
