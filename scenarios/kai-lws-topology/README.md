# kai-lws-topology scenario

Tests **topology-aware scheduling** of a **LeaderWorkerSet (LWS)** by the
**NVIDIA KAI Scheduler**: KAI gang-schedules the whole LWS group and places it
inside a single topology domain, packing tightly by rack — driven purely by
[KAI topology annotations](https://github.com/NVIDIA/KAI-Scheduler/blob/main/docs/topology/README.md),
with no hand-written `PodGroup`.

Distributed workloads have hierarchical communication (e.g. tensor-parallel
groups inside a larger job): they want to sit close together in the network
topology. KAI models the cluster as a hierarchy (block → rack → host) and can
constrain a workload to a level (`required`) while packing tighter when possible
(`preferred`).

## What it tests

1. **Gang scheduling of an LWS.** KAI's PodGrouper builds one PodGroup for the LWS
   replica and admits all pods all-or-nothing (`schedulerName: kai-scheduler`,
   `kai.scheduler/queue` label). Pods use the `pause` placeholder, so there is no
   real compute — just the whole-node GPU reservations that make placement visible.
2. **Whole-group co-location (required = block).** The group is 4 pods × 8 GPUs =
   32 GPUs; a block is 2 racks / 4 nodes / 32 GPUs, so `topology-required-placement:
   block` forces all 4 pods into **one block**.
3. **Tight packing (preferred = rack).** `topology-preferred-placement: rack` makes
   KAI pack as tightly as it can within that block. A rack holds 2 nodes, so the
   4 pods pack **2-per-rack** across the block's two racks.

## How it works

- `pre_run` installs the KAI Scheduler (pinned by `KAI_VERSION`). LeaderWorkerSet
  is already part of the base install.
- `manifests/topology.yaml`:
  - a KAI `Topology` (`gpu-lab-topology`) describing the cluster hierarchy
    block → rack → host, from the node labels in `cluster/kind-cluster.yaml`;
  - a KAI `Queue` hierarchy (`lws-root` → `lws-queue`) with best-effort quota
    (`-1`) — this scenario is about placement, not quota gating.
- `manifests/lws.yaml`: a `LeaderWorkerSet` (size 4, one 8-GPU node per pod) whose
  metadata annotations set `kai.scheduler/topology`,
  `...topology-required-placement: ...topology-block`, and
  `...topology-preferred-placement: ...topology-rack`.

## Run

```bash
./demo.sh kai-lws-topology
./demo.sh clean kai-lws-topology
```

## What to look for

- All 4 pods reach `Running` together (KAI admitted the gang all-or-nothing).
- One KAI `PodGroup` exists for the LWS replica.
- In the placement table, every pod shares the **same** `BLOCK`, and the pods
  split **2 per `RACK`** across the two racks of that block.

## Notes on segments

KAI also has a finer-grained **[segment](https://github.com/NVIDIA/KAI-Scheduler/blob/main/docs/topology/segments.md)**
mechanism (`kai.scheduler/segment-size` + `segment-topology-*-placement`, or an
LWS `subGroupPolicy`) that pins fixed-size sub-groups each to their own domain.
It is the natural fit for "N workers per rack" layouts. In the KAI release pinned
by this lab, the LWS segment path produces a PodGroup that nests each segment as a
mid-level SubGroup **with** `minMember`, which KAI's own admission webhook rejects
(`minMember cannot be set on a mid-level SubGroup ...; use minSubGroup instead`),
so the pods never get grouped. Until that is fixed in a KAI release, this scenario
expresses the same intent — one block, 2 pods per rack — with whole-group
`required=block` + `preferred=rack`, which is fully supported today.

## Sample output

Captured from a fresh `./demo.sh kai-lws-topology` run (the inspection step):

```text
==> Inspection: kai-lws-topology
--- LeaderWorkerSet ---
    NAME           READY   DESIRED   UP-TO-DATE   AGE
    lws-topology   1       1         1            5s

--- KAI PodGroup (the scheduler-facing gang, one per LWS replica) ---
    NAME                                                           AGE
    pg-lws-topology-97352457-f156-4f58-86bf-63ddda0d29d1-group-0   4s

--- Pods (all Running = KAI admitted the whole gang all-or-nothing) ---
    POD                PHASE     NODE
    lws-topology-0     Running   gpu-lab-worker3
    lws-topology-0-1   Running   gpu-lab-worker4
    lws-topology-0-2   Running   gpu-lab-worker
    lws-topology-0-3   Running   gpu-lab-worker2

--- Placement (whole group in ONE block, packed 2 pods per rack) ---
    POD                                      BLOCK    RACK     NODE
    lws-topology-0                           block-1  rack-2   gpu-lab-worker3
    lws-topology-0-2                         block-1  rack-1   gpu-lab-worker
    lws-topology-0-3                         block-1  rack-1   gpu-lab-worker2
    lws-topology-0-1                         block-1  rack-2   gpu-lab-worker4
```

**What it shows:** KAI built one `PodGroup` for the LWS replica and gang-scheduled
all 4 pods to Running together. `required=block` put the whole group in a single
block (`block-1`), and `preferred=rack` packed it **2 pods per rack** — two pods
on `rack-1`, two on `rack-2` (each rack is 2 nodes, so a rack holds exactly one
pair). This is the same "2 per rack in one block" layout the segment mechanism
would produce, achieved with whole-group required/preferred placement.
