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

## Sample output

Captured from a fresh `./demo.sh kueue-wait-for-pods-ready` run (the inspection step):

```text
==> Inspection: kueue-wait-for-pods-ready
--- Workloads in 'wait-ready' (priority / reserved / admitted) ---
NAME                    QUEUE              PRIORITY   RESERVED   ADMITTED
job-never-ready-fa57c   wait-ready-queue   0          False      False

--- Workload conditions (PodsReady=False -> Evicted: PodsReadyTimeout) ---
    QuotaReserved=False (Pending)
    Evicted=True (PodsReadyTimeout)
    Admitted=False (NoReservation)
    Requeued=False (PodsReadyTimeout)
    PodsReady=False (WaitForStart)
    requeue count: 1

--- Eviction / requeue events ---
    REASON                         COUNT    MESSAGE
    QuotaReserved                  <none>   Quota reserved in ClusterQueue wait-ready-cq, wait time since queued was 0s
    Admitted                       <none>   Admitted by ClusterQueue wait-ready-cq, wait time since reservation was 0s
    EvictedDueToPodsReadyTimeout   <none>   Exceeded the PodsReady timeout wait-ready/job-never-ready-fa57c

--- Pods (Running but READY 0/1: the failing readiness probe) ---
    NAME                READY   STATUS        RESTARTS   AGE
    never-ready-8tnws   0/1     Terminating   0          2m1s
    never-ready-gbf5w   0/1     Terminating   0          2m1s
```

**What it shows:** The Job was admitted and its pods started, but a deliberately
failing readiness probe keeps them at `READY 0/1` forever. After the 120s
`waitForPodsReady` timeout, Kueue **evicted** the whole gang (`Evicted=True`,
reason `PodsReadyTimeout`) and requeued it (`requeue count: 1`) — freeing the
quota instead of letting a wedged job hold GPUs. At the captured moment the pods
are `Terminating` (being torn down for the requeue) and the Workload is back to
un-admitted, waiting to try again. This is the timing-dependent state; re-running
may catch it mid-cycle with a higher requeue count.
