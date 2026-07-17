# kueue-borrowing-lending

How Kueue lets one `ClusterQueue` borrow another's **idle** quota within a
cohort — and how `borrowingLimit` / `lendingLimit` bound exactly how much.

This goes one level deeper than `kueue-fair-sharing`: that scenario shows two
*busy* teams converging on a fair split via preemption; this one isolates the
**borrowing mechanics** with a single active queue and an idle peer.

## What this scenario tests

- A queue can be admitted **beyond its own nominal quota** by borrowing unused
  quota from its cohort.
- `borrowingLimit` is a **hard ceiling** on borrowing: once reached, further
  workloads stay Pending even though the cluster has free GPUs and the lender is
  completely idle. Capacity is not the constraint — the configured limit is.

## How it works

Both queues live in the cohort `borrow-cohort`, each with `nominalQuota: 16` GPUs:

| Queue | Role | Limit | Effective ceiling |
| --- | --- | --- | --- |
| `borrow-a-cq` | borrower | `borrowingLimit: 16` | 16 own + 16 borrowed = **32** |
| `borrow-b-cq` | lender (idle) | `lendingLimit: 16` | may lend all 16 |

`scenario.sh`:

- `apply` creates the queues, then `borrow-a` submits **5** jobs (5 × 8 = 40
  GPUs) while `borrow-b` submits nothing.
- `inspect` shows the borrower's Workloads, both ClusterQueues' usage, the
  admitted count, and the first blocked Workload's reason.

## Run

```bash
./demo.sh kueue-borrowing-lending
```

> Quota admission still needs real node capacity, so free the cluster first if
> other GPU scenarios are running: `./demo.sh clean <other-scenario>`.

## What to look for

- **4 of 5** jobs admitted in `borrow-a` — 32 GPUs = its 16 nominal **plus 16
  borrowed** from idle `borrow-b`.
- `borrow-a-cq` reserves `nvidia.com/gpu=32`; `borrow-b-cq` stays at `0`.
- The 5th Workload is Pending with *"insufficient unused quota for
  nvidia.com/gpu … 8 more needed"* — the `borrowingLimit`, not the cluster's
  spare 32 GPUs, is what stops it.
- Lower `borrow-b`'s `lendingLimit` (e.g. to `8`) and re-run: now the **lender's**
  limit becomes the binding constraint and `borrow-a` only reaches 24 GPUs.

## Sample output

Captured from a fresh `./demo.sh kueue-borrowing-lending` run (the inspection step):

```text
==> Inspection: kueue-borrowing-lending
--- Workloads in 'borrow-a' (priority / reserved / admitted) ---
NAME            QUEUE            PRIORITY   RESERVED   ADMITTED
job-a-1-dd7c0   borrow-a-queue   0          False      <none>
job-a-2-c7c30   borrow-a-queue   0          True       True
job-a-3-2716a   borrow-a-queue   0          True       True
job-a-4-eb906   borrow-a-queue   0          True       True
job-a-5-91870   borrow-a-queue   0          True       True

--- ClusterQueue 'borrow-a-cq' ---
NAME          PENDING   ADMITTED   RESERVING
borrow-a-cq   1         4          4
    reserved gpu-flavor: cpu=200m nvidia.com/gpu=32

--- ClusterQueue 'borrow-b-cq' ---
NAME          PENDING   ADMITTED   RESERVING
borrow-b-cq   0         0          0
    reserved gpu-flavor: cpu=0 nvidia.com/gpu=0

    borrow-a admitted: 4 / 5 jobs (ceiling 32 GPUs = nominal 16 + borrow 16)

First blocked workload's reason:
    PodsReady: WaitForStart - Not all pods are ready or succeeded
    QuotaReserved: Pending - couldn't assign flavors to pod set main: insufficient unused quota for nvidia.com/gpu in flavor gpu-flavor, 8 more needed
```

**What it shows:** `borrow-a` has a nominal quota of 16 GPUs and a `borrowingLimit`
of 16, so its ceiling is 32 GPUs. It submitted 5 jobs (8 GPUs each = 40 GPUs
wanted) but only 4 are admitted (`nvidia.com/gpu=32` reserved) — exactly its
nominal + borrow ceiling. The 5th stays `PENDING` with "insufficient unused quota
... 8 more needed". Crucially, `borrow-b-cq` is completely idle (0 reserved) and
the cluster still has 32 free GPUs: it's the **borrowingLimit**, not physical
capacity, that caps how much `borrow-a` can pull from the shared cohort.
