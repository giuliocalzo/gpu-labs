# gpu-lab: a multi-scenario GPU on kind

A self-contained local lab that shows how **Kueue** wires together with common
Kubernetes batch/AI building blocks — **LeaderWorkerSet (LWS)**, **RayJob**,
**JobSet**, **Kubeflow Trainer (TrainJob)**, **CodeFlare AppWrapper**, **Dynamic
Resource Allocation (DRA)**, **NVIDIA Grove**, the **NVIDIA KAI Scheduler**, and
**Volcano** — plus Kueue's own scheduling features (topology-aware scheduling,
fair sharing, workload priority, preemption).
Everything runs on a single **kind** cluster
with **no real GPU** (each worker advertises **8** fake `nvidia.com/gpu`, like a
real 8-GPU node). Pods are `pause` placeholders — **no real compute** — the one
exception being `kueue-rayjob`, which runs an actual Ray image to form a real
cluster.

One shared cluster hosts several independent scenarios, each in its own folder
under `scenarios/`, driven by a single `demo.sh` CLI.

## Scenarios

| Scenario            | What it shows |
|---------------------|---------------|
| [`kueue-tas`](scenarios/kueue-tas/README.md)         | Topology-Aware Scheduling: LWS groups co-locate, falling back rack → block; a 3rd group is quota-blocked and stays Pending. |
| [`kueue-fair-sharing`](scenarios/kueue-fair-sharing/README.md)| Two teams in one cohort: Team A borrows the whole cohort, then fair sharing reclaims ~half for Team B. |
| [`kueue-borrowing-lending`](scenarios/kueue-borrowing-lending/README.md) | Cohort borrowing: one queue borrows an idle peer's quota up to its `borrowingLimit`, then further jobs stay Pending despite free GPUs. |
| [`kueue-wait-for-pods-ready`](scenarios/kueue-wait-for-pods-ready/README.md) | `waitForPodsReady`: an admitted gang whose pods never become Ready is evicted (`PodsReadyTimeout`) and requeued, freeing its quota. |
| [`kueue-partial-admission`](scenarios/kueue-partial-admission/README.md) | Partial admission: a Job asking for more than the quota is admitted at reduced parallelism (shrink-to-fit) instead of staying Pending. |
| [`kueue-workload-priority`](scenarios/kueue-workload-priority/README.md) | `WorkloadPriorityClass` controls admission **order** when quota is scarce (high before low). |
| [`kueue-preemption`](scenarios/kueue-preemption/README.md)  | A high-priority job **evicts** a running low-priority job to fit within quota. |
| [`kueue-dra`](scenarios/kueue-dra/README.md)         | Dynamic Resource Allocation: claim-based GPU devices (via the DRA example driver) put under Kueue quota. |
| [`kueue-rayjob`](scenarios/kueue-rayjob/README.md)   | Kueue + **RayJob**: a whole Ray cluster (head + GPU worker) is gang-admitted under GPU quota; a 2nd RayJob stays Pending. |
| [`kueue-jobset`](scenarios/kueue-jobset/README.md)   | Kueue + **JobSet**: a whole JobSet (all its child Jobs) is gang-admitted under GPU quota; a 2nd JobSet stays Pending. |
| [`kueue-appwrapper`](scenarios/kueue-appwrapper/README.md) | Kueue + **AppWrapper**: a whole AppWrapper (its wrapped resources) is gang-admitted under GPU quota; a 2nd stays Pending. |
| [`kueue-training-operator`](scenarios/kueue-training-operator/README.md) | Kueue + **Kubeflow Trainer (TrainJob)**: a whole TrainJob (all its nodes) is gang-admitted under GPU quota; a 2nd stays Pending. |
| [`grove-podcliques`](scenarios/grove-podcliques/README.md)  | NVIDIA **Grove**: one `PodCliqueSet` expands into role cliques, a scaling group, a PodGang, and pods started in order (frontend → prefill → decode). |
| [`grove-kai-topology`](scenarios/grove-kai-topology/README.md) | NVIDIA **Grove + KAI Scheduler**: KAI gang-schedules the whole PodGang (which the default scheduler can't) and packs the prefill gang into a single topology **block**. |
| [`kai-lws-topology`](scenarios/kai-lws-topology/README.md) | **KAI Scheduler + LeaderWorkerSet**: KAI gang-schedules the LWS into one topology **block** (required) and packs it **2 pods per rack** (preferred). |
| [`kai-queues-quota-overquota`](scenarios/kai-queues-quota-overquota/README.md) | **KAI** queue model: a queue borrows idle GPUs **past its quota** (over-quota), but its hard **limit** caps it below cluster capacity so the rest stay Pending. |
| [`volcano-gang`](scenarios/volcano-gang/README.md) | **Volcano** batch scheduler: a Job group is gang-admitted all-or-nothing under a Volcano `Queue`'s capacity; a 2nd equal gang waits (comparison to Kueue). |

Each scenario links to its own `README.md` above, describing exactly what it
tests, how it's wired, and what to look for.

> Not every scenario is about Kueue. The lab is a general Kubernetes demo
> cluster: `grove-podcliques`, for example, showcases NVIDIA Grove and installs
> its own operator via the scenario's `pre_run`/`post_run` hooks.

## Prerequisites

- Docker (running)
- [kind](https://kind.sigs.k8s.io/), `kubectl`, and `helm` in your `PATH`
- ~9 containers' worth of resources (1 control-plane + 8 workers)

## Usage

```bash
./demo.sh list                # list available scenarios
./demo.sh <scenario>          # ensure cluster + base install, then run & inspect
./demo.sh clean <scenario>    # remove a scenario's resources (keep the cluster)
./demo.sh down                # delete the kind cluster
FORCE_RECREATE=1 ./demo.sh <scenario>   # rebuild the cluster first
```

Examples:

```bash
./demo.sh kueue-tas
./demo.sh kueue-fair-sharing
./demo.sh kueue-preemption
```

The first scenario you run creates the cluster and installs cert-manager, LWS,
and Kueue (with `fairSharing` enabled at the controller level) and the shared
`gpu-flavor`. Scenarios that need extra operators (RayJob, JobSet, Kubeflow Trainer, AppWrapper, DRA, Grove, KAI, Volcano)
install them on demand via their `pre_run` hook and leave them running afterward
for inspection (`clean <scenario>` or `down` tears everything down).
Subsequent runs reuse everything. Scenarios are isolated (separate namespaces,
queues and priority classes), so you can run them in any order, though they all
draw from the same 64 fake GPUs — `clean` one before running another if you want
a clean slate.

## Topology (shared cluster)

```
block-1                          block-2
├─ rack-1: worker (gpu:8) x2     ├─ rack-3: worker (gpu:8) x2
└─ rack-2: worker (gpu:8) x2     └─ rack-4: worker (gpu:8) x2

8 nodes x 8 GPUs = 64 GPUs total   (rack = 16, block = 32)
```

Every worker also carries the common `nvidia.com/*` labels GPU Feature Discovery
would apply on a real 8× H100 node (inert here — no device plugin — but makes the
nodes look realistic).

## About GPU requests

Pods request a whole node's worth of GPUs (`nvidia.com/gpu: 8`), mirroring
multinode inference/training where each pod pins to one 8-GPU node.

`nvidia.com/gpu` is a Kubernetes *extended resource*, scheduled in whole-integer
units, so a pod **can** request just a portion of a node (e.g. `2` of `8`).
Fractional units (`0.5`) are not allowed; real sub-GPU sharing (MIG /
time-slicing) works by advertising more integer units per node.

## Layout

```
demo.sh                 # CLI dispatcher
lib/common.sh           # shared helpers: install, workload/job builders, inspectors
cluster/kind-cluster.yaml   # 1 control-plane + 8 labelled workers
base/flavors.yaml       # shared gpu-flavor (TAS Topology/flavor live with kueue-tas)
scenarios/<name>/
  scenario.sh           # hooks: describe / apply / inspect / cleanup (+ optional pre_run / post_run)
  manifests/*.yaml      # scenario-specific Kueue objects & workloads
```

## Pinned versions

Set at the top of `lib/common.sh` (overridable via env):
`KUEUE_VERSION`, `LWS_VERSION`, `CERT_MANAGER_VERSION`, `GROVE_VERSION`,
`KUBERAY_VERSION`, `JOBSET_VERSION`, `KAI_VERSION`, `VOLCANO_VERSION`,
`KUBEFLOW_TRAINER_VERSION`, `APPWRAPPER_VERSION`, `CLUSTER_NAME`.

## CI

`.github/workflows/scenarios.yml` runs **every scenario in parallel**, each in
its own matrix job on its own kind cluster (full isolation, unlike the shared
local cluster). The matrix is discovered dynamically from `scenarios/`, so new
scenarios are picked up automatically. It runs on push, pull request, and
manual `workflow_dispatch`.

## Cleanup

```bash
./demo.sh clean <scenario>          # just one scenario
kind delete cluster --name gpu-lab          # or: ./demo.sh down
```
