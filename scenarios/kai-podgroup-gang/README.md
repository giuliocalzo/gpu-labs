# kai-podgroup-gang scenario

Tests the **NVIDIA KAI Scheduler's `PodGroup`** primitive directly: an
**explicit, hand-authored `PodGroup`** with a `minMember` gates its member pods
as a **gang** — KAI admits them **all-or-nothing**. See the
[KAI gang-scheduling docs](https://github.com/NVIDIA/KAI-Scheduler/tree/main/docs/gang-scheduling).

The other `kai-*` scenarios let KAI's *PodGrouper* auto-synthesise a `PodGroup`
per workload. This one writes the `PodGroup` object itself and attaches pods to
it, so the gang contract is explicit in the manifests.

## What it tests

1. **Explicit `PodGroup`.** A `scheduling.run.ai/v2alpha2` `PodGroup` with
   `minMember: 3` is created directly (not synthesised). Its member pods join it
   via the `pod-group-name` annotation.
2. **All-or-nothing admission.** `gang-1` (3 pods × 8 GPUs = 24) fits under the
   queue's 32-GPU limit, so KAI admits the **whole** gang and all 3 pods run.
3. **A partial gang never runs.** `gang-2` also wants 24 GPUs, but only 8 (one
   node) are free under the limit. One pod *would* fit that node — but a gang is
   all-or-nothing, so KAI schedules **zero** of `gang-2`'s pods; all 3 stay
   `Pending` until the whole gang can be placed.

## How it works

- `pre_run` installs the KAI Scheduler (pinned by `KAI_VERSION`).
- `manifests/queues.yaml`: `kai-gang-root → kai-gang-queue` with
  `gpu: {quota: 32, limit: 32}`. One 24-GPU gang leaves exactly 8 GPUs (one node)
  of headroom — enough for a single pod, not a whole gang.
- `apply` submits two gangs via the shared `kai_podgroup_gang` helper, which
  emits an explicit `PodGroup` (`minMember: 3`) plus 3 **bare** `sleep` pods that
  reference it. Bare pods are deliberate: a hand-authored `PodGroup` is only
  authoritative for pods KAI does not own — for `Job`/`Deployment` pods KAI's
  PodGrouper synthesises its own group and ignores the annotation.

## Run

```bash
./demo.sh kai-podgroup-gang
./demo.sh clean kai-podgroup-gang
```

## What to look for

- Two `PodGroup`s (`gang-1`, `gang-2`), each `MIN=3`.
- `gang-1`'s 3 pods are all `Running`; `gang-2`'s 3 pods are all `Pending`.
- The queue shows `GPU_ALLOC=24` against a `GPU_LIMIT=32` — 8 GPUs sit idle, yet
  `gang-2` runs nothing: that idle node can't hold a whole 3-pod gang.

## Sample output

Captured from a fresh `./demo.sh kai-podgroup-gang` run (the inspection step):

```text
==> Inspection: kai-podgroup-gang
--- KAI PodGroups (the explicit gangs; MIN = minMember = all-or-nothing threshold) ---
    PODGROUP   MIN   QUEUE            PRIORITY
    gang-1     3     kai-gang-queue   train
    gang-2     3     kai-gang-queue   train

--- KAI queue (limit 32 GPUs; gang-1 uses 24, leaving 8 = one idle node) ---
    QUEUE            GPU_QUOTA   GPU_LIMIT   GPU_ALLOC   GPU_REQ
    kai-gang-root    -1          -1          24          48
    kai-gang-queue   32          32          24          48

--- Pods by gang ('gang-1' all Running, 'gang-2' all Pending) ---
    POD        PHASE     GANG     NODE
    gang-1-1   Running   gang-1   gpu-lab-worker2
    gang-1-2   Running   gang-1   gpu-lab-worker3
    gang-1-3   Running   gang-1   gpu-lab-worker
    gang-2-1   Pending   gang-2   <none>
    gang-2-2   Pending   gang-2   <none>
    gang-2-3   Pending   gang-2   <none>
```

**What it shows:** Both gangs are explicit `PodGroup`s with `minMember: 3`.
`gang-1` fits under the 32-GPU queue limit, so KAI admits it all-or-nothing and
all 3 pods run (`GPU_ALLOC=24`). `gang-2` requests another 24 GPUs (`GPU_REQ=48`
total) but only 8 GPUs (one node) remain under the limit. A single pod would fit
that node, yet **zero** of `gang-2`'s pods run — a gang is admitted all-or-nothing
— so all 3 stay `Pending` until the whole gang can be placed at once.
