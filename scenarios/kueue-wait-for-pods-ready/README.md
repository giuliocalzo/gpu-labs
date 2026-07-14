# kueue-wait-for-pods-ready

Kueue's `waitForPodsReady` gives Jobs **time-based all-or-nothing** semantics:
after admission, if a Workload's pods don't *all* become Ready within a timeout,
Kueue **evicts and requeues** the whole gang — freeing its quota instead of
letting a wedged job sit on GPUs forever.

## What this scenario tests

- An admitted Workload whose pods run but never reach `Ready` is **evicted**
  with reason `PodsReadyTimeout`.
- The whole gang is **requeued** (not just the failing pod), and Kueue records
  the requeue on the Workload (`requeueState.count`) and via an event.

## How it works

- **Config (cluster-wide)** — `waitForPodsReady` is enabled for the whole lab in
  `base/kueue-values.yaml` with `timeout: 120s`: short enough for a snappy demo,
  yet still a 2-minute grace for slow-but-healthy workloads (e.g. `kueue-rayjob`'s
  real `rayproject/ray` image pull), which `requeuingStrategy` would just requeue
  if it ever tripped. In the v1beta2 config the feature is enabled by the block's
  presence — there is no `enable` field, and `timeout` is required. This scenario
  adds no Kueue config of its own; it just submits a gang that can never become
  Ready.
- **`manifests/queues.yaml`** — a ClusterQueue with room for exactly one 2-pod /
  16-GPU gang, so admission is instant and the demo is purely about readiness.
- **`manifests/job.yaml`** — a 2-pod gang (each claiming a whole 8-GPU node)
  whose container runs fine but has an **always-failing readiness probe**
  (`exec: ["false"]`), so the pods are `Running` but never `Ready`.
- **`scenario.sh`** submits the job, waits for the first requeue, and prints the
  Workload conditions, the requeue count, the eviction event, and the pods.

## Run

```bash
./demo.sh kueue-wait-for-pods-ready
./demo.sh clean kueue-wait-for-pods-ready
```

> `waitForPodsReady` uses a 2m timeout, so the eviction takes a couple minutes to
> appear — the scenario waits for the first requeue before printing its report.

## What to look for

- The Workload is admitted, then after the ~2m `timeout` its conditions flip to
  `Evicted=True (PodsReadyTimeout)` and `PodsReady=False`, with
  `requeue count: 1` (and climbing on each retry).
- An event `EvictedDueToPodsReadyTimeout` — *"Exceeded the PodsReady timeout"*.
- The pods show `READY 0/1` (the failing probe) and are terminated as the gang
  is evicted, then recreated when the Workload is requeued.

> Because the pods can never become Ready, the gang is evicted and requeued
> repeatedly (up to `requeuingStrategy.backoffLimitCount`). That's expected — it
> models a genuinely broken job that Kueue keeps cycling rather than letting it
> squat on quota.
