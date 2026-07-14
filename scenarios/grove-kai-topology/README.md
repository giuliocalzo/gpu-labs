# grove-kai-topology

Grove describes a disaggregated LLM inference stack; the **NVIDIA KAI Scheduler**
turns that description into real, gang-scheduled, topology-aware placement.

## What this scenario tests

1. **Gang scheduling** — KAI admits the whole Grove `PodGang` all-or-nothing.
   Every pod (frontend + prefill leader/workers + decode) goes from `Pending` to
   `Running` together. This is the piece the `grove-podcliques` baseline is
   missing: with the default kube-scheduler the same `PodGang` never schedules.
2. **Topology-aware placement** — the prefill scaling group (leader + 2 workers =
   3 whole-node pods, 24 GPUs) carries a `topologyConstraint` that forces KAI to
   pack it into a **single block**.

## How it works

- **`manifests/topology.yaml`**
  - a KAI `Topology` (`kai.scheduler/v1alpha1`) describing the cluster hierarchy
    `block → rack → host` from the node labels in `cluster/kind-cluster.yaml`;
  - a Grove `ClusterTopologyBinding` mapping the domain names (`block`, `rack`,
    `host`) to those node-label keys and binding them to the KAI Topology;
  - a small KAI `Queue` hierarchy (`grove-root` → `grove-queue`) the pods run under.
  - The KAI Topology's name matches `topologyConstraint.topologyName`: Grove
    passes that name straight through to KAI as the topology reference.
- **`manifests/podcliqueset.yaml`** — the same disaggregated stack as
  `grove-podcliques`, but every clique pod sets `schedulerName: kai-scheduler`
  and carries the `kai.scheduler/queue: grove-queue` label, and the `prefill`
  scaling group adds:

  ```yaml
  topologyConstraint:
    topologyName: gpu-lab-topology
    pack:
      required: block     # the whole gang must fit in one block
      preferred: rack     # ...packed as tightly as possible toward one rack
  ```

- **`scenario.sh`**
  - `pre_run` installs the KAI Scheduler and the Grove operator (with
    Topology-Aware Scheduling enabled — required before any `topologyConstraint`
    is accepted);
  - `apply` creates the topology/queues, submits the `PodCliqueSet`, and waits
    for KAI to bring the gang up;
  - `inspect` shows the Grove `PodGang`, the KAI `PodGroup`, and each pod's
    block/rack so the prefill co-location is visible;
  - `cleanup` removes the workload and uninstalls both operators.

## Topology math (why the constraint is meaningful)

The kind cluster is 8 GPU nodes = 2 blocks × 2 racks × 2 hosts, 8 GPUs each:

| Domain | Nodes | GPUs |
| ------ | ----- | ---- |
| host   | 1     | 8    |
| rack   | 2     | 16   |
| block  | 4     | 32   |

The prefill gang needs 3 nodes (24 GPUs). That **fits in one block (32)** but
**not in one rack (16)**, so `required=block` is satisfiable while `preferred=rack`
can only be partially honored — a perfect, observable demonstration.

## What to look for

Run it:

```bash
./demo.sh grove-kai-topology
```

- All six pods reach `Running` (KAI admitted the gang all-or-nothing).
- In the placement table the three `prefill-*` pods share the **same block**;
  two share a rack and the third is in the other rack of that block.

> Note: in this Grove alpha the `PodGang.status.phase` field stays `Pending` when
> an external scheduler backend (KAI) does the scheduling — the phase field isn't
> advanced by the backend. The real success signals are the pods running as a
> gang and the KAI `PodGroup`, not the Grove phase string.
