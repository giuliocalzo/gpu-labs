# kueue-fair-sharing scenario

Tests Kueue **Fair Sharing** across two tenants in a shared cohort: borrowing
idle capacity and then reclaiming a fair share via preemption.

## What it tests

1. **Borrowing.** When Team B is idle, Team A can borrow beyond its own nominal
   quota and use the entire cohort.
2. **Fair-share reclaim.** When Team B shows up, Fair Sharing preempts enough of
   Team A's *borrowed* workloads so each team converges on a roughly equal share
   of the contended resource - independent of priority or submission time.

## How it works

- Two ClusterQueues, `team-a-cq` and `team-b-cq`, in the same cohort (`teams`),
  each with `nvidia.com/gpu: 32` nominal quota (cohort total = 64).
- Both set `fairSharing.weight: 1`, `preemption.reclaimWithinCohort: Any`, and
  `withinClusterQueue: LowerPriority`.
- Fair Sharing itself is enabled cluster-wide in `base/kueue-values.yaml`
  (`fairSharing.preemptionStrategies`).
- Team A submits 8 jobs × 8 GPUs (tries to grab all 64); then Team B submits
  4 jobs × 8 GPUs (wants its 32).

## Run

```bash
./demo.sh kueue-fair-sharing
./demo.sh clean kueue-fair-sharing
```

## What to look for

- Right after Team A submits: `team-a-cq` reserves ~64 GPUs (borrowing into
  Team B's quota).
- After Team B submits and things settle: an even **~4 vs ~4** admitted split
  (32 GPUs each). The inspection prints the admitted count per team.
- Some Team A workloads move back to Pending - they were preempted so Team B
  could reclaim its fair share.

## Sample output

Captured from a fresh `./demo.sh kueue-fair-sharing` run (the inspection step):

```text
==> Inspection: kueue-fair-sharing
=== Team A ===
--- Workloads in 'team-a' (priority / reserved / admitted) ---
NAME            QUEUE          PRIORITY   RESERVED   ADMITTED
job-a-1-f8e37   team-a-queue   0          False      False
job-a-2-2007f   team-a-queue   0          True       True
job-a-3-f8c5f   team-a-queue   0          False      False
job-a-4-87fda   team-a-queue   0          True       True
job-a-5-92778   team-a-queue   0          False      False
job-a-6-8e3e0   team-a-queue   0          True       True
job-a-7-79764   team-a-queue   0          True       True
job-a-8-c3093   team-a-queue   0          False      False

=== Team B ===
--- Workloads in 'team-b' (priority / reserved / admitted) ---
NAME            QUEUE          PRIORITY   RESERVED   ADMITTED
job-b-1-5a3d0   team-b-queue   0          True       True
job-b-2-514b6   team-b-queue   0          True       True
job-b-3-1d2a7   team-b-queue   0          True       True
job-b-4-1c743   team-b-queue   0          True       True

--- ClusterQueue 'team-a-cq' ---
NAME        PENDING   ADMITTED   RESERVING
team-a-cq   4         4          4
    reserved gpu-flavor: cpu=200m nvidia.com/gpu=32

--- ClusterQueue 'team-b-cq' ---
NAME        PENDING   ADMITTED   RESERVING
team-b-cq   0         4          4
    reserved gpu-flavor: cpu=200m nvidia.com/gpu=32

Admitted workloads (each = 8 GPUs):
    Team A admitted: 4
    Team B admitted: 4
    Expect a roughly even split (~4 vs ~4) once B has reclaimed its share.
```

**What it shows:** Team A submitted 8 jobs first and initially borrowed the whole
cluster, but once Team B submitted its 4 jobs, fair sharing rebalanced to an even
**4 vs 4** split — each team ends with `nvidia.com/gpu=32` reserved (4 × 8 GPUs).
Team A now has 4 admitted and 4 back in `PENDING` (they were preempted so Team B
could reclaim its half); Team B has all 4 admitted and 0 pending. The two
ClusterQueues share one cohort, so the total stays at the cluster's 64 GPUs.
