# volcano-network-topology

[Volcano](https://volcano.sh) is a CNCF batch scheduler for Kubernetes. This
scenario shows its **network-topology-aware scheduling** — the `HyperNode` CRD
that models the cluster's network as a tree of performance domains, and a Volcano
`Job`'s `networkTopology` constraint that pins a gang to a chosen tier.

Reference: [Network Topology Aware Scheduling](https://volcano.sh/docs/KeyFeatures/NetworkTopologyAware).

## What this scenario tests

1. **Topology as first-class API** — `HyperNode`s describe racks and blocks
   (leaf HyperNodes select real nodes; non-leaf HyperNodes group child
   HyperNodes), forming a tiered tree where a lower tier = a tighter, faster
   network domain.
2. **Hard topology constraint** — a `Job` with `networkTopology: {mode: hard,
   highestTierAllowed: N}` must fit entirely inside a single tier-≤N HyperNode.
   The same gang is schedulable at one tier and unschedulable at a tighter one.

## The lab topology

The 8 fake-GPU workers are wired into this tree (see `manifests/hypernodes.yaml`):

```
hn-root (tier 3)
├── hn-block-1 (tier 2)          block-1
│   ├── hn-rack-1 (tier 1)       rack-1: worker,  worker2
│   └── hn-rack-2 (tier 1)       rack-2: worker3, worker4
└── hn-block-2 (tier 2)          block-2
    ├── hn-rack-3 (tier 1)       rack-3: worker5, worker6
    └── hn-rack-4 (tier 1)       rack-4: worker7, worker8
```

- **tier 1** (a rack) = 2 nodes = 16 GPUs.
- **tier 2** (a block) = 4 nodes = 32 GPUs.

## How it works

- **Scheduler config (`manifests/scheduler.conf`)** — Volcano's default config
  does not enable the `network-topology-aware` plugin, so `pre_run` swaps in a
  config that adds it (alongside `binpack` for compact placement) and restarts
  the scheduler.
- **`manifests/hypernodes.yaml`** — 4 leaf HyperNodes (tier 1, one per rack, via
  `labelMatch` on the `cloud.provider.com/topology-rack` label), 2 non-leaf
  HyperNodes (tier 2, one per block, via `exactMatch` on child HyperNodes), and 1
  root (tier 3).
- **`manifests/jobs.yaml`** — two identical 4-pod / 32-GPU gangs (each pod claims
  a whole 8-GPU node), differing only in the constraint:
  - `topo-tier2`: `hard`, `highestTierAllowed: 2` → must fit one **block**.
  - `topo-tier1`: `hard`, `highestTierAllowed: 1` → must fit one **rack**.
- **`scenario.sh`** — `pre_run` installs Volcano + config; `apply` creates the
  HyperNodes, queue and both jobs; `inspect` prints the HyperNode tree, the
  PodGroups, and each job's pods annotated with their node's block/rack; `cleanup`
  removes everything and uninstalls Volcano.

## Run

```bash
./demo.sh volcano-network-topology
```

## What to look for

- `topo-tier2`'s PodGroup is **Running**: all 4 whole-node pods land inside a
  **single block** (they may share it across the block's two racks, but never
  cross into the other block).
- `topo-tier1`'s PodGroup stays **Pending/Inqueue**: 4 whole-node pods can't fit
  a 2-node rack, so the hard tier-1 constraint can never be satisfied — even
  though the cluster still has 32 free GPUs in the other block. It's a topology
  failure, not a capacity one.
- `highestTierAllowed` is the knob that trades placement tightness (network
  locality) against schedulability.

## Sample output

Captured from a fresh `./demo.sh volcano-network-topology` run (the inspection step):

```text
==> Inspection: volcano-network-topology
--- HyperNodes (network topology tree; lower tier = tighter domain) ---
    HYPERNODE    TIER
    hn-root      3
    hn-rack-1    1
    hn-rack-2    1
    hn-rack-3    1
    hn-rack-4    1
    hn-block-1   2
    hn-block-2   2

--- PodGroups (one per job; Running = gang admitted, Pending/Inqueue = waiting) ---
    JOB          QUEUE      MINMEMBER   PHASE
    topo-tier1   vol-topo   4           Inqueue
    topo-tier2   vol-topo   4           Running

--- 'topo-tier2' (hard, highestTierAllowed=2): all 4 pods packed into ONE block ---
    POD            NODE               BLOCK     RACK
    topo-tier2-w-0 gpu-lab-worker3    block-1   rack-2
    topo-tier2-w-1 gpu-lab-worker4    block-1   rack-2
    topo-tier2-w-2 gpu-lab-worker     block-1   rack-1
    topo-tier2-w-3 gpu-lab-worker2    block-1   rack-1

--- 'topo-tier1' (hard, highestTierAllowed=1): cannot fit a 2-node rack, stays Pending ---
    POD            NODE               BLOCK     RACK
    topo-tier1-w-0 (Pending)          -         -
    topo-tier1-w-1 (Pending)          -         -
    topo-tier1-w-2 (Pending)          -         -
    topo-tier1-w-3 (Pending)          -         -
```

**What it shows:** `topo-tier2` asked for a tier-2 (block) domain, and Volcano's
`network-topology-aware` plugin packed all 4 whole-node pods inside **block-1**
(spanning its two racks) — minimising cross-block network hops for the job. The
identical `topo-tier1` gang asked for a tier-1 (rack) domain, but no rack holds 4
nodes, so its PodGroup stays waiting despite 32 free GPUs in block-2. The only
difference between the two jobs is `highestTierAllowed`, which sets how tight a
network domain the gang must fit into.
