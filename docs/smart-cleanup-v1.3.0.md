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

Stage 2 verification:

- All 320 Swift tests passed, including 14 cleanup behavior cases, native
  AppKit quit/refusal integration, operation exclusion and fixture isolation.
  The disposable test application received `applicationShouldTerminate`; a
  refusal kept it running. No user application was a cleanup test target.
- Debug and Release builds passed with `-strict-concurrency=complete`.
- Native layout captures cover all six pages in both appearances at default
  and minimum sizes, plus cleanup scanning/waiting/measurement/results and
  authorization. The primary cleanup action remains visible at 800 x 560;
  secondary content can scroll. Captures: `/private/tmp/memory-monitor-v130-layout/`.
- Actual screen-pixel captures confirmed moving, nonblank particles. Lifecycle
  tests cover visibility, activation, minimization, scrolling, pressure tiers,
  bounded layers and no success replay. Captures:
  `/private/tmp/memory-monitor-v130-motion/`.
- A short isolated animation-process sample used 0.069 CPU seconds while idle
  and 0.075 while active, over three seconds each. This excludes WindowServer
  and GPU work and is not a frame-rate guarantee.
- Native window tests now reactivate their test application after restoring a
  minimized/hidden window. Release verification runs these tests serially
  because they share desktop focus; production activation rules remain intact.
- Cleanup now tracks departure from the foreground as recent use, checks
  consistent physical-memory totals across measurement windows, and cannot
  celebrate cancellation during the final sample. Fixture mode cannot execute
  cleanup or read/write real cleanup authorizations.

The original release verification completed all tests and Debug strict build,
then blocked while the compiler read a response file in the Desktop build
cache. Its test log is
`/private/tmp/memory-monitor-v130-release-verification-final.log`.
The successful strict Release build used
`SWIFTPM_BUILD_DIR=/private/tmp/memory-monitor-v130-build` and
`SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/memory-monitor-v130-module-cache`.
Existing caches and user scratch directories were preserved. The remaining
release gates passed separately: Release probe, structured compatibility,
bundle version/architecture and strict signature verification. Log:
`/private/tmp/memory-monitor-v130-release-remaining.log`. The interrupted script
is not counted as a successful end-to-end run.

- Built and ad-hoc signed version 1.3.0 (build 130), arm64, at
  `~/Library/Application Support/MemoryMonitor/releases/1.3.0-final/MemoryMonitor.app`.
  Desktop integration passed; the existing login item remains enabled.
  Report: `/private/tmp/memory-monitor-v130-desktop-integration.json`.
- Live mouse checks passed in light/dark appearances: opening the cleanup list,
  clicking its search field without dismissal, keeping the primary action
  visible at minimum size, changing/restoring the percentage setting, retaining
  settings across deactivation and opening settings from the menu bar.
  No cleanup authorization changed and no cleanup was started. Screenshots:
  `/private/tmp/memory-monitor-v130-live/`; log:
  `/private/tmp/memory-monitor-v130-live-ui.log`.
- The previous 1.2.1 process exited normally. The verified 1.3.0 bundle is
  running with `MEMORY_MONITOR_UI_CHECK_FIXTURE=0`, with the original appearance
  and size restored and the release page selected. Prior bundles are retained.
  The live system reported critical memory pressure during the UI checks, so
  particles were appropriately disabled there; motion was verified separately
  through the controlled native pixel/lifecycle tests above.

Validation was performed on macOS 26.5.1, Apple Silicon. Other supported macOS
versions were not available for this run. The local package uses ad-hoc signing,
without Developer ID notarization.
