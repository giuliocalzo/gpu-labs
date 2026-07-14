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
