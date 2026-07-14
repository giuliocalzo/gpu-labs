# kueue-demo-lab: a multi-scenario Kueue lab on kind

A self-contained local lab that shows how **Kueue** wires together with
**LeaderWorkerSet (LWS)** and its scheduling features. Everything runs on a
single **kind** cluster; there is **no real workload** (all pods are `pause`
placeholders) and **no real GPU** (each worker advertises **8** fake
`nvidia.com/gpu`, like a real 8-GPU node).

One shared cluster hosts several independent scenarios, each in its own folder
under `scenarios/`, driven by a single `demo.sh` CLI.

## Scenarios

| Scenario            | What it shows |
|---------------------|---------------|
| `tas`               | Topology-Aware Scheduling: LWS groups co-locate, falling back rack → block; a 3rd group is quota-blocked and stays Pending. |
| `fair-sharing`      | Two teams in one cohort: Team A borrows the whole cohort, then fair sharing reclaims ~half for Team B. |
| `workload-priority` | `WorkloadPriorityClass` controls admission **order** when quota is scarce (high before low). |
| `preemption`        | A high-priority job **evicts** a running low-priority job to fit within quota. |
| `dra`               | Documented **stub** for Dynamic Resource Allocation (needs feature gates + a driver). See `scenarios/dra/README.md`. |

## Prerequisites

- Docker (running)
- [kind](https://kind.sigs.k8s.io/) and `kubectl` in your `PATH`
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
./demo.sh tas
./demo.sh fair-sharing
./demo.sh preemption
```

The first scenario you run creates the cluster and installs LWS + Kueue (with
`fairSharing` enabled at the controller level) and the shared ResourceFlavors.
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
base/flavors.yaml       # shared Topology + ResourceFlavors
scenarios/<name>/
  scenario.sh           # describe / apply / inspect / cleanup hooks
  manifests/*.yaml      # scenario-specific Kueue objects & workloads
```

## Pinned versions

Set at the top of `lib/common.sh` (overridable via env):
`KUEUE_VERSION`, `LWS_VERSION`, `CLUSTER_NAME`.

## Cleanup

```bash
./demo.sh clean <scenario>          # just one scenario
kind delete cluster --name kueue-tas-demo   # or: ./demo.sh down
```
