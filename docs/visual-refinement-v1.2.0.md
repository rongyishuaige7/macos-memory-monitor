# Visual refinement v1.2.0

## Scope

Refine the desktop and menu companion against the supplied reference: readable
typography, native glass hierarchy, compact overview, grouped processes,
dedicated release workflow, useful initial history range, and a test instrument.
Add short numeric/control transitions and local event-driven particle effects.

## Architecture

Reuse existing sampling, workload grouping, identity-validated actions and
history retention. Shared surface/button styles provide consistent chrome.
Process groups expand to individual actionable rows; no group termination API.
The release page selects one process and opens the existing confirmation flow.
Charts remain bounded to 240 extrema-preserving points and use real samples.
Core Animation owns particles in a small NSView; no per-frame model updates.

## Non-goals

No fake reclaimed-memory totals, automatic application termination, file
deletion, synthetic charts, dependency changes, or continuously animated window
backgrounds. Do not run large memory loads on this already busy Mac.

## Stages

1. Static surfaces, layout, page distinction and data presentation. Test,
   inspect native-size captures, commit and push.
2. Motion and particle lifecycle, reduced-motion/pressure gates, verification,
   versioned signed app, commit/push and switch the live application.

## Risks and verification

- Settings retain independent window ownership and remain mouse-interactive.
- Group totals are attributed sums, not deduplicated or guaranteed reclaimable
  RAM. All mutations still target exactly one revalidated process identity.
- First overview fits the default window; minimum window supports scrolling
  without clipped controls. Validate all six pages, light/dark and menu.
- Particle effects must stop when hidden, minimized, inactive, off-page, under
  pressure, or when reduced motion is requested. No success effect on failure.
- Compare idle and local-animation resource use, and exercise list scrolling.
  Performance observations are measurements, not guarantees on a loaded host.
- Run relevant regression tests, full suite, strict Release build, signature
  check, desktop integration and native mouse/menu interactions.

## Verification

Stage 1: 10 focused presentation/window tests passed. Captured all six pages
at 960/800-point widths in light and dark appearance plus the menu companion
(`/tmp/memory-monitor-v120-static`). Inspected overview, grouped processes,
release empty state, settings and test instrument; core overview fits the
default size, smaller windows scroll without overlapping controls. Group
membership/search and original-sample gap segmentation have focused coverage.
The fixture release list is intentionally empty under the live action policy;
real-list selection/confirmation will be checked in the versioned app.

Stage 2: full suite passed (302 tests), followed by 8 focused presentation
tests after aligning the motion toggle and correcting nested helper-app icons.
Strict-concurrency Release compilation passed. Native Core Animation tests
run an AppKit event loop and use ScreenCaptureKit pixel comparisons: continuous
particles move, success particles stop emitting at 140 ms and are removed by
850 ms, and hidden/minimized/offscreen/disabled effects stop. A consumed or
suppressed burst never replays. Captures: `/tmp/memory-monitor-v120-motion`.

The isolated particle harness consumed 0.005 CPU seconds idle and 0.002 CPU
seconds with particles over separate 3-second intervals; these are near the
measurement floor and exclude WindowServer/GPU cost. Short native overview
samples on this busy 16 GB Mac were 0-4.5% CPU / 74-108 MB on 1.1.0 and
0-6.4% CPU / 71-110 MB on the 1.2.0 candidate. Different load/timing means these
are smoke measurements, not proof of a speedup or a frame-rate guarantee.
The real session reported elevated pressure and approximately 13.5 GB of
disk swap, so decorative motion was correctly suppressed in that session.

Candidate package passed ad-hoc signature and desktop integration checks.
Real mouse settings toggle, light/dark previews, motion toggle, Finder
deactivation/return, menu-to-settings route, release selection/detail dismissal
and list scrolling passed. No exit signal was sent to a real user process.
Runtime screenshots: `/tmp/memory-monitor-desktop-v120-review`.

The final 1.2.0 (build 120) package passed signature verification and the
complete native interaction sequence again, including group expand/collapse.
Nested Chrome helpers now use the containing application's icon and settings
switches share the same trailing alignment. The running executable was verified
at `~/Library/Application Support/MemoryMonitor/releases/1.2.0-final/MemoryMonitor.app`,
with fixture mode disabled and the normal storage root. The prior candidate
and 1.1.0 packages remain available; only the final app is running.

No Developer ID/notarization, reboot/login-cycle verification, sustained
frame-time benchmark, or large live memory-stress run was performed. This is
a local ad-hoc signed delivery with focused native interaction evidence.
