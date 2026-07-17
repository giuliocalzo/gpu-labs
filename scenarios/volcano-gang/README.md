# volcano-gang

[Volcano](https://volcano.sh) is a CNCF batch scheduler for Kubernetes. This
scenario shows its two headline features — **gang scheduling** and **queue-based
capacity** — and contrasts them with how Kueue does the same job.

## What this scenario tests

1. **Gang scheduling (all-or-nothing)** — a Volcano `Job` declares
   `minAvailable`, and Volcano's `gang` plugin only runs it when *all* its pods
   can be placed at once. You never see half a job running while the rest waits.
2. **Queue capacity gating** — a Volcano `Queue` has a hard `capability` cap.
   Two equal-sized gangs are submitted but the queue only fits one, so the second
   waits — even though the cluster still has spare GPUs.

## How it works

- **`manifests/queue.yaml`** — a `Queue` (`scheduling.volcano.sh/v1beta1`)
  `volcano-demo` with `capability: nvidia.com/gpu: 16` (room for exactly one
  16-GPU gang).
- **`manifests/jobs.yaml`** — two `Job`s (`batch.volcano.sh/v1alpha1`),
  `training-a` and `training-b`. Each has `minAvailable: 2` and one `worker` task
  with `replicas: 2`, every pod claiming a whole 8-GPU node (2 × 8 = 16 GPUs per
  job). Volcano auto-creates a `PodGroup` (`minMember: 2`) per job to enforce the
  gang.
- **`scenario.sh`**
  - `pre_run` installs Volcano (its CRDs + a scheduler whose default config
    enables the `gang` and `proportion` plugins);
  - `apply` creates the queue, submits both jobs, and waits for one gang to run;
  - `inspect` prints the `Queue`, the two `PodGroup`s (one `Running`, one
    `Pending`), the `Job`s, and the pods;
  - `cleanup` deletes the jobs + queue and uninstalls Volcano.

## Volcano vs Kueue

| Concept | Volcano | Kueue |
| --- | --- | --- |
| Unit of admission | `PodGroup` (`minMember`) | `Workload` |
| All-or-nothing | `gang` plugin | gang admission of the Workload |
| Quota / capacity | `Queue.spec.capability` | `ClusterQueue` `nominalQuota` |
| Who schedules pods | Volcano scheduler (`schedulerName: volcano`) | default scheduler, after Kueue un-suspends |

Volcano *is* the scheduler (it places the pods itself); Kueue is an admission
layer that gates workloads and hands scheduling back to the default scheduler.
The other `kueue-*` scenarios show the Kueue side of this table.

## Run

```bash
./demo.sh volcano-gang
```

## What to look for

- The `training-a` `PodGroup` is `Running` with both worker pods on two nodes.
- The `training-b` `PodGroup` is `Pending` with **no pods created** — its gang
  doesn't fit the queue's 16-GPU capacity, so Volcano holds the whole group back.
- Free up the first gang (`./demo.sh clean volcano-gang` then re-run, or delete
  `training-a`) and `training-b` is admitted in its place.

## Sample output

Captured from a fresh `./demo.sh volcano-gang` run (the inspection step):

```text
==> Inspection: volcano-gang
--- Volcano Queue (capacity gate) ---
    NAME           STATE   CAP-GPU
    volcano-demo   Open    16

--- PodGroups (one per job; Running = gang admitted, Inqueue/Pending = waiting) ---
    NAME                                              MINMEMBER   PHASE
    training-a-89fe30c8-c93b-4e1f-b1ca-5defbf763e3d   2           Running
    training-b-c1098fc3-8068-4063-ad1f-4e911f6e09a3   2           Pending

--- Volcano Jobs ---
    NAME         QUEUE          MIN   PHASE     RUNNING
    training-a   volcano-demo   2     Running   2
    training-b   volcano-demo   2     Pending   <none>

--- Pods (only the admitted gang has pods; the waiting gang has none yet) ---
    POD                   PHASE     NODE
    training-a-worker-0   Running   gpu-lab-worker4
    training-a-worker-1   Running   gpu-lab-worker7
```

**What it shows:** Volcano gang-admits a whole job at once. `training-a`'s PodGroup
is `Running` with both worker pods (`MINMEMBER 2`) on two nodes. The
`volcano-demo` queue caps capacity at 16 GPUs, which fits exactly one 2-worker
gang, so `training-b`'s PodGroup stays `Pending` and Volcano creates **no pods**
for it — you never see a half-scheduled gang (one worker Running, one Pending).
Like the Kueue gang scenarios, capacity (not raw free GPUs) gates the second gang;
this is the Volcano scheduler's equivalent of Kueue's all-or-nothing admission.
