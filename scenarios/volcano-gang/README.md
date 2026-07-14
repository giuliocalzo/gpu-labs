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
