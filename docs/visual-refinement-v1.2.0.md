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

Stage 2 and packaged runtime verification pending.
