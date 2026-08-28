# Reliability Hardening v1.0.2

## Scope

- Make equal-minute history merges deterministic while preferring the newest
  source sample for system metrics.
- Reject or prune implausibly future history and audit records without losing
  valid older data.
- Make JSONL appends and crash-truncated UTF-8 tails recoverable.
- Keep failed history writes retryable and avoid dropping queued refreshes or
  out-of-order audit results in the app coordinator.
- Reject short `sysctl` payloads instead of accepting zero-filled tail fields.
- Keep process sample quality consistent with its payload, including scans
  that enumerate processes but cannot read any complete row.
- Let users stop tracking a timed-out graceful exit, and distinguish force
  signal delivery from the subsequent verification wait.
- Recover immediately after a wall-clock rollback without allowing an older
  in-flight sampling pass to overwrite the new clock generation.
- Generate workload-growth advice only from complete, recent process
  inventories, using process capture instants instead of enclosing pass times.
- Keep recovery and Swap-growth wording consistent with measured deltas, and
  let materially changed evidence replace a same-ID recommendation card.
- Keep process-trend baselines advancing when only the system source fails, and
  exclude the monitor's own process group from actionable recommendations.

## Non-goals

- No change to process-control authorization semantics or public process
  identity fields.
- No cross-process database migration or dependency addition.
- No UI redesign or change to the documented 24-hour/7-day retention policy.
- No promise that cancellation can interrupt a kernel or injected runtime call
  that never resumes; stale operation tokens still prevent late publication.
- No application-termination redesign or guarantee that an async history flush
  completes after the view model has begun deinitializing.
- No persistence format migration or new cross-process storage coordination.

## Architecture

`MemoryHistoryRecord` carries an optional source-sample timestamp in addition
to its minute bucket. `HistoryStore` uses that marker for newest-wins system
fields and a canonical tie-break for legacy records. JSONL readers continue to
accept complete final lines without a newline and repair only a demonstrably
incomplete tail. The monitor view model uses a one-slot refresh queue, while
audit publication is guarded by monotonically increasing operation generations.
Native `sysctl` reads validate both the return code and exact payload length.
Process scans reserve usable quality for results containing at least one row,
while the app publishes attempted-scan coverage independently from row
replacement. The process-action state machine treats a graceful timeout as an
actionable but dismissible state and records force-signal verification as a
separate phase after delivery succeeds. Refresh requests carry a wall-clock
generation in addition to their sequence: a backwards clock step invalidates
cross-sample CPU, pressure, process-trend, and recommendation baselines, while
results from an older generation are rejected. Recommendation growth baselines
carry explicit process-inventory completeness and use bounded process-sample
intervals.
Process baselines advance independently from optional paired system evidence;
the paired system value is used only when a Swap delta is temporally valid.

## Risks

- Older history files have no source timestamp; ties remain deterministic but
  cannot recover which physical sample was newer.
- A bounded future-skew allowance may discard data from a badly adjusted clock;
  this is preferable to retaining records forever.
- A write failure can still leave the store unavailable until a later retry.
- A native or test runtime that ignores cooperative cancellation can retain its
  detached operation until that call returns; operation tokens protect state,
  but cannot make an uninterruptible call finish.
- A `0/N` process scan is diagnostic evidence only. It updates coverage and
  health status but does not replace the last usable process rows.
- A wall-clock rollback intentionally clears derived trend state; retained
  rows and persisted history remain visible until the new generation samples.
- A failed or very old process inventory cannot produce growth advice, even if
  its retained rows still look plausible.
- Best-effort loop finalization still cannot guarantee a durable flush once the
  model is being destroyed; explicit termination coordination is separate.

## Verification criteria

- Existing and new XCTest suites pass.
- History and audit JSONL tests cover no-newline appends, truncated UTF-8,
  future timestamps, and retry after failed writes.
- Sampler tests cover exact native payload sizes and zero-row process results.
- Process-action tests cover abandoning a timeout and cancelling verification
  only after a force signal has already been sent.
- App tests cover clock rollback with an older pass in flight, rejection of an
  older snapshot within one generation, and same-ID recommendation upgrades.
- Recommendation tests cover incomplete and expired process baselines, process
  capture-time intervals, rising Swap during recovery, and a zero Swap-growth
  threshold.
- Recommendation tests cover a system-source failure between process samples
  and exclusion of monitor-owned or system-marked workload groups.
- Debug/release builds, strict-concurrency builds, probe execution, and app
  bundle packaging complete where the host supports them.

## Staged delivery

1. Harden core history/audit persistence and add regression tests.
2. Harden app refresh, timeout display, login status, and recommendation
   baselines.
3. Run the full verification matrix and record remaining risks.
4. Tighten native payload validation and finish process sample/action state
   semantics discovered by the residual audit.
