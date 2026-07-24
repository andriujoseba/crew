# Metrics

## Window

These are a snapshot of `~/duty/duty.log` from its first recorded completed
poll boundary, **2026-07-22T16:54:43Z**, through its last completed boundary at
measurement time, **2026-07-24T12:51:22Z** (43h 56m 39s). I excluded four
started-but-not-cleanly-finished tick sequences. `boot-check.log` contains boot
health probes and contributes no throughput data. There is no sibling notify
log on this box.

## Headline counts

| Measure | Count | What the log supports |
| --- | ---: | --- |
| Completed duty ticks | 460 | A `duty poll started` boundary followed by `duty poll finished` without another start intervening |
| Quiet ticks | 141 (30.65%) | Completed ticks with no `GLOBAL REVIEW`, `RESUME`, `BUILD`, `REBASE`, or `HANDOFF` duty detection |
| Busy ticks | 319 (69.35%) | Completed ticks with at least one of those duty detections |
| Review queue pickups | 58 | `GLOBAL REVIEW duty detected` records |
| Verified verdict rounds | 57 | `REVIEW submit verified` records |
| Distinct PRs reviewed | 32 | Unique `owner/repo#number` keys among verified verdict records |
| Distinct reviewed PRs by repo | ceremony 17; incubator 9; rig 5; cast 1 | Same unique keys, grouped by repository |
| Resume wake events | 192 | `RESUME duty detected`; activity, not distinct builds |
| Build wake events | 75 | `BUILD duty detected`; activity, not issues completed |
| Rebase wake events | 20 | `REBASE duty detected`; activity, not distinct PRs |
| Handoff wake events | 22 | `HANDOFF duty detected`; the line does not carry a PR number, so this is not a unique-PR count |

The log does **not** record approve versus request-changes as a structured
field, so that split is **not logged**. It also does not reliably record issues
completed, authored PRs opened, or distinct authored PRs reaching handoff, so
those builder-throughput figures are **not logged**. I am not treating session
prose or GitHub API state as a substitute for missing log fields.

## Latency and duration

- **Longest observed review-queue wait:** 22m 13s for
  `heavy-duty/rig#128`, requested at `2026-07-24T07:08:35Z` and picked up at
  `07:30:48Z`. This is request timestamp embedded in the pickup record minus
  the duty detection timestamp.
- **Longest observed pickup-to-verified-verdict interval:** 6m 04s for
  `heavy-duty/incubator#34`, from `20:50:28Z` to `20:56:32Z` on July 23. I
  paired each pickup key with the next verified submission for that key.
- **Longest completed duty tick:** 20m 41s, from
  `2026-07-23T15:15:01Z` to `15:35:42Z`.
- API-call volume and explicit CLI timeout count are **not logged**. Four
  incomplete tick sequences are visible, but the log does not prove that a
  timeout caused any of them.

## Reproducing the figures

Set `log=~/duty/duty.log`. The basic event counts are `rg -c '<marker>'
"$log"` using the exact markers named in the table.

Distinct reviewed PRs:

```bash
rg 'REVIEW submit verified for ' "$log" \
  | sed -E 's/.* for ([^ ]+) head .*/\1/' \
  | sort -u
```

The quiet ratio is produced by an `awk` state machine: open a tick on
`duty poll started`, mark it busy on any of the five duty-detection markers,
and count it only when `duty poll finished` arrives before another start.

Queue wait uses the ISO timestamp at the start of each
`GLOBAL REVIEW duty detected` line and the `requested <ISO timestamp>` field
on that same line. Pickup-to-verdict uses the PR key from that line and pairs
it with the next `REVIEW submit verified for <same key>` record. Timestamps
are converted with `date -d <timestamp> +%s` and subtracted. Tick duration is
the same subtraction between matched start and finish boundaries.
