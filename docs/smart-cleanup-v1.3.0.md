# Intelligent memory cleanup v1.3.0

## Scope

Replace the release page's single-process workflow with an application-level,
one-click cleanup. Applications are explicitly opted in, with no default
approvals. Protect foreground/recently active applications, system processes,
unknown identities and busy applications. Request normal AppKit termination,
observe exit, and report actual before/after available-memory estimates.
Add a central brand instrument and stage-driven, bounded particle animation.

## Non-goals

No SIGTERM/SIGKILL in intelligent cleanup, privileged helper, global automatic
termination, disk-cache purge, synthetic memory pressure, browser extension,
guaranteed reclaimed-byte totals or universal unsaved-document detection.
Existing manual process controls remain available in the process page.
Do not terminate real user applications during verification.

## Architecture

- A testable main-actor runtime resolves regular NSRunningApplications and
  samples their main-process identities off the main thread. Authorization
  binds the bundle identifier and canonical bundle/executable locations.
- A bounded activity tracker protects apps activated/launched within two
  minutes and treats initial observation as recent. Two CPU samples inform
  busy detection; low CPU is not a guarantee of no background work.
- A cleanup controller owns scan, planning, sequential normal-quit requests,
  waiting/skip, cancellation, measurement and a bounded result list. Revalidate
  immediately before each request. Never signal helpers using display groups.
- Shared operation exclusion prevents cleanup, manual termination and memory
  tests from overlapping. Shutdown cancels pending cleanup and releases state.
- Measure short multi-sample windows using the existing system-memory
  estimate. Keep processed-app counts separate from signed observed change.
- Core Animation owns motion, independent of polling and SwiftUI frame ticks.
  Hidden/inactive/reduced-motion views stop. Elevated pressure reduces effects;
  critical pressure keeps static status. No fabricated progress or success.

## Risks And Acceptance

Normal quit may prompt for saving, be refused, time out or be followed by an
automatic relaunch. Sending the request is not success. Cancellation cannot
undo sent requests. Unknown or changed identity must prevent termination.
Authorization is revocable and persists locally; failures cannot silently
authorize an app. Do not claim arbitrary third-party caches were reclaimed.

Verify default-deny, authorization persistence/revocation, recent activity,
busy/foreground changes, identity reuse, refusal, timeout/skip, cancellation,
relaunch, measurement failures, negative/no benefit and cross-operation locks.
Use fake runtimes and owned disposable apps for quit integration. Run native
layout captures in light/dark at minimum/default window sizes, particle pixel
and lifecycle checks, relevant regressions and the full Swift test suite.
Build/sign a versioned release, verify desktop integration and switch the
running app only after checks. Preserve prior packages and user scratch files.

## Staged Delivery

1. Cleanup engine, authorization UI, static instrument and behavioral tests;
   verify, commit and push this independently usable slice.
2. Stage-driven particle instrument, native visual/lifecycle verification,
   full regression, versioned signed 1.3.0 build and runtime integration;
   verify, commit and push, then switch to the verified app.

## Verification

Stage 1: 43 focused tests passed (13 cleanup behavior cases, 20 existing
process-action cases and 10 desktop presentation/window cases). Covered
default deny, authorization persistence/location binding, activity protection,
pre-request identity/activity/revocation changes, refusal, timeout, skip,
cancellation, relaunch, signed measured change, unavailable measurements,
bounded batches, cooldown and operation exclusion. The native layout test
rendered all six pages in light/dark at default/minimum sizes.

The first slice uses main-process CPU activity as a conservative busy signal;
it cannot detect every helper/background job or unsaved document. Opt-in is
therefore limited to applications the user is willing to quit. New/initially
observed applications receive the same two-minute activity protection.
Own-process malloc pressure relief is included, without claiming a guaranteed
benefit or attributing its byte counter to global available-memory change.

Stage 2 native quit integration, visual/motion captures and release verification
are pending.
