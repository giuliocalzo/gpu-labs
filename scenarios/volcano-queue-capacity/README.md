# volcano-queue-capacity

[Volcano](https://volcano.sh) is a CNCF batch scheduler for Kubernetes. This
scenario shows its **queue resource management** — the `capacity` plugin's
three-level resource model (`deserved` / `capability`) and the `reclaim` action
that rebalances borrowed resources between queues. It is the Volcano counterpart
to the `kai-reclaim` scenario.

Reference: [Queue Resource Management](https://volcano.sh/docs/KeyFeatures/QueueResourceManagement).

## What this scenario tests

1. **Resource borrowing** — a queue may exceed its `deserved` (fair) share and
   use idle cluster resources when no one else wants them.
2. **Inter-queue reclaim** — when a second queue submits and demands its own
   `deserved` share, Volcano's `reclaim` action evicts the first queue's
   **over-deserved** work to give it back — but never drops a queue below its own
   `deserved` amount.

## How it works

- **Scheduler config (`manifests/scheduler.conf`)** — Volcano's default config
  enables neither the `reclaim` action nor the `capacity` plugin, so `pre_run`
  swaps in a config with `actions: "enqueue, allocate, backfill, reclaim"` and
  the `capacity` plugin (replacing `proportion`), then restarts the scheduler.
- **`manifests/queues.yaml`** — two queues, `vol-queue-a` and `vol-queue-b`, each
  with `deserved: nvidia.com/gpu: 32` (fair share), `capability: nvidia.com/gpu:
  64` (may borrow the whole cluster) and `reclaimable: true`. `cpu` is set large
  so GPUs are the only binding/reclaimable resource.
- **Jobs** — single-pod, 8-GPU Volcano `Job`s built by `volcano_gpu_job` (a
  `sleep` placeholder, plus a `PodEvicted → RestartPod` policy so reclaimed jobs
  reappear as Pending instead of vanishing).
- **`scenario.sh`**
  - `pre_run` installs Volcano and applies the custom scheduler config;
  - `apply` — **phase 1:** team-a submits 8 jobs (64 GPUs) and borrows the whole
    cluster while team-b is idle; **phase 2:** team-b submits 4 jobs (32 GPUs),
    triggering reclaim of team-a's over-deserved GPUs;
  - `inspect` prints the queues (deserved / capability / live allocated), the
    PodGroups per job, the running pods, and the reclaim events;
  - `cleanup` deletes the jobs + queues and uninstalls Volcano.

## Volcano vs KAI vs Kueue

| Concept | Volcano | KAI | Kueue |
| --- | --- | --- | --- |
| Fair share | `Queue.spec.deserved` (capacity plugin) | `Queue` quota | `ClusterQueue` `nominalQuota` |
| Hard cap | `Queue.spec.capability` | `Queue` limit | `borrowingLimit` + lending |
| Give borrowed back | `reclaim` action | reclaim | preemption (`borrowWithinCohort` / reclaim) |

## Run

```bash
./demo.sh volcano-queue-capacity
```

## What to look for

- After phase 1, team-a runs all 8 jobs (64 GPUs) — it borrowed team-b's idle
  half on top of its own 32 deserved.
- After phase 2, both queues settle at **32 allocated GPUs**: team-a keeps 4 jobs
  Running and its other 4 are reclaimed (Pending/Inqueue), team-b runs 4.
- The events stream shows `Evict … because of reclaim` for team-a's PodGroups.
- Reclaim stops exactly at `deserved`: team-a is never pushed below its own 32.

## Sample output

Captured from a fresh `./demo.sh volcano-queue-capacity` run (the inspection step):

```text
==> Inspection: volcano-queue-capacity
--- Volcano queues (deserved = fair share, capability = hard cap, allocated = live) ---
    QUEUE         DESERVED-GPU   CAP-GPU   ALLOC-GPU   STATE
    vol-queue-a   32             64        32          Open
    vol-queue-b   32             64        32          Open

--- PodGroups per job (team-a: 4 Running + 4 waiting; team-b: 4 Running) ---
    JOB   QUEUE         MINMEMBER   PHASE
    a-7   vol-queue-a   1           Inqueue
    a-1   vol-queue-a   1           Pending
    a-4   vol-queue-a   1           Pending
    a-6   vol-queue-a   1           Pending
    a-2   vol-queue-a   1           Running
    a-3   vol-queue-a   1           Running
    a-5   vol-queue-a   1           Running
    a-8   vol-queue-a   1           Running
    b-1   vol-queue-b   1           Running
    b-2   vol-queue-b   1           Running
    b-3   vol-queue-b   1           Running
    b-4   vol-queue-b   1           Running

--- Running pods & their nodes (admitted work only) ---
    POD       QUEUE         NODE
    a-2-w-0   vol-queue-a   gpu-lab-worker6
    a-3-w-0   vol-queue-a   gpu-lab-worker4
    a-5-w-0   vol-queue-a   gpu-lab-worker
    a-8-w-0   vol-queue-a   gpu-lab-worker7
    b-1-w-0   vol-queue-b   gpu-lab-worker8
    b-2-w-0   vol-queue-b   gpu-lab-worker5
    b-3-w-0   vol-queue-b   gpu-lab-worker2
    b-4-w-0   vol-queue-b   gpu-lab-worker3

--- Reclaim / eviction events ---
    24s       Warning   Evict   pod/a-4-w-0                  Pod is evicted, because of reclaim
    24s       Normal    Evict   podgroup/a-4-...             reclaim
    17s       Warning   Evict   pod/a-6-w-0                  Pod is evicted, because of reclaim
    10s       Warning   Evict   pod/a-1-w-0                  Pod is evicted, because of reclaim
```

**What it shows:** team-a first borrowed all 64 GPUs (its 32 `deserved` + 32
over-deserved) while team-b was idle. When team-b submitted its 32-GPU workload,
Volcano's `reclaim` action evicted team-a's over-deserved PodGroups until team-b
reached its `deserved` 32 GPUs. Both queues end at exactly 32 allocated GPUs —
reclaim rebalances borrowed capacity back to the fair share, and team-a's evicted
jobs wait (Pending/Inqueue) for GPUs to free up again.
