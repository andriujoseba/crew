# Metrics

Source: `~/duty/duty.log` only (no `notify.log` or other sibling duty logs on this box).
Derived 2026-07-24 by regex over the full log file (session stdout is often concatenated onto duty lines without newlines — line-oriented counts under-count; full-file search is required).

## Window

| | |
|---|---|
| Start | **2026-07-22T17:20:50Z** (first `duty: start`) |
| End | **2026-07-24T12:50:28Z** (last `duty: done` at derivation time) |
| Span | **~43.5 hours** |
| Log size | ~5092 lines / ~360KB (grows with session prose) |

How to re-run: take first `duty: start` timestamp and last `duty: done` in `duty.log`.

## Throughput (reviewer)

I am reviewer-only; **builder metrics are not logged** (no PR-create / handoff lines in duty.log).

| Figure | Value | How derived |
|---|---|---|
| Unique PRs with a landed verdict | **66** | Distinct `owner/repo#N` in `submit-verdict: … verdict landed at head …` |
| Distinct (PR, head) verdicts | **111** | Distinct `(repo, number, head_sha)` with a landed event |
| Approve events | **102** | Landed lines with `(approve)` |
| Request-changes events | **9** | Landed lines with `(request-changes)` |
| Unique PRs that saw only approve | **60** | PR set whose event types = `{approve}` |
| Unique PRs that saw both RC and approve (multi-round) | **6** | `{approve, request-changes}` |
| Unique PRs that saw only RC | **0** | (all six RC PRs later got an approve on a later head) |

**Approve vs request-changes split (by event):** 102 / 9 ≈ **91.9% approve**, **8.1% request-changes**.

**PRs with at least one request-changes in-window:**  
`heavy-duty/box#164`, `heavy-duty/ceremony#64`, `heavy-duty/ceremony#94`, `heavy-duty/incubator#34`, `heavy-duty/rig#127`, `heavy-duty/rig#134`.

**Unique PRs by repo:** ceremony 41 · incubator 13 · rig 9 · box 1 · cast 1 · `dan-claude-bot/incubator` 1.

**Announce:** 104 `announce-reviewing: … announced head` successes; 1 skip for already-announced (ceremony#32 double-post refuse).

**Launch events:** 84 lines matching `need a verdict (…) — launching session` (full-file).

**Builder / issues built / handoff:** **not logged**.

## Quiet-tick ratio

| Figure | Value | How derived |
|---|---|---|
| `duty: start` count | **507** | Full-file count |
| Work ticks (session launched) | **95** | Starts whose following chunk (until next start) contains `— launching session` |
| Quiet ticks | **412** | Starts without a launch in that chunk |
| **Quiet ratio** | **0.813** (81.3%) | `412 / 507` |
| Explicit post-merge quiet phrase | 229× `0 unique candidates — quiet` | Only after the API∪search rewrite (~2026-07-23T10:45); earlier quiet was per-repo `0 search candidates — quiet` |

Flock skips (`flock -n` when a session still holds the lock) **do not write a log line** — not logged, so true wall-clock quiet is understated relative to cron schedule.

## Latency / duration

| Figure | Value | Notes |
|---|---|---|
| Median first-need → first-verdict | **2.5 min** | Among 58 PRs that appear both as `needs verdict` and later `verdict landed` in this log |
| p90 first-need → first-verdict | **~4.0 min** | Same set |
| Max first-need → first-verdict | **~44.3 min** | `heavy-duty/ceremony#60` (log-visible only) |
| Longest multi-verdict span on one PR | **~8.7 h** | Wall time from first to last landed verdict on the same PR (re-requests / new heads), not a single round |
| Session duration median | **~2.3 min** | Launch timestamp → next `duty: done` after that launch |
| Session duration mean | **~2.6 min** | |
| Session duration max | **~8.5 min** | `heavy-duty/cast` (longest paired session; some early sessions may pair poorly if `duty: done` missing) |
| Candidate collect phase (API∪search) | **n=308, mean 19.2s, median 19s, max 53s** | From `collect candidates` to `unique candidate(s)` / `0 unique` line |
| API raw hits per tick | mean **0.33**, max **5**, nonzero **25.6%** of collect samples | `API request-check raw hits=N` |
| Search raw hits per tick | max **5** (same scale) | `repos.txt search raw hits=N` |

**Not logged (cannot claim):** time from GitHub “review requested” timestamp to first duty sighting; GitHub API call counts per tick; model token usage; timeouts as a first-class event (only one `HARD FAIL` on submit).

## Failures / protocol notes (visible)

| Event | Count | Detail |
|---|---|---|
| `HARD FAIL` on submit | **1** | `ceremony#41` at head `a0bea573a14f` (later approved after submit-script flag fix for this `gh` CLI) |
| Refuse second submit | **4** | Already had verdict at head |
| Protocol notes | **3** | Prior double-verdict on ceremony#39; refuse further on #39; refuse third 🔎 on ceremony#32 |

## How to re-derive (one-liner shape)

```bash
# unique PRs / approve / RC (full-file; do not use line-only grep alone)
python3 - <<'PY'
import re
from collections import defaultdict
data=open("/home/grok/duty/duty.log").read()
rx=re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) submit-verdict: ([^\s#]+/[^\s#]+)#(\d+): verdict landed at head ([0-9a-f]+) \((approve|request-changes)\)")
ms=list(rx.finditer(data))
print(len(ms), sum(m.group(5)=="approve" for m in ms), sum(m.group(5)=="request-changes" for m in ms), len({(m.group(2),m.group(3)) for m in ms}))
PY
```

Quiet ratio: count `duty: start`; for each, scan until next start for `— launching session`.
