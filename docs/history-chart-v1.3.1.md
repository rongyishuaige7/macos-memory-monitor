# History chart refinement v1.3.1

## Scope

Improve the statistics page and shared compact memory trend. Add period-scoped
latest, sample-average and peak readings, restrained chart fill, an average
reference, a peak marker and exact-sample hover inspection. Keep 1/6/24-hour
ranges, readable percentage/time axes and explicit gaps. Fit the main graph
and controls at the existing 800 x 560 minimum window size.

## Non-goals

No new sampling, retention, cleanup behavior, background animation, dependencies
or fabricated data. Do not add more technical metrics to the statistics page.
Existing on-disk history and user settings remain the data source.

## Architecture

Use the existing Swift Charts renderer and bounded extrema-preserving plot
points. Compute summaries and hover values from original in-range samples.
Cache presentation on input changes; mouse movement affects only chart-local
selection. A fixed inspection strip avoids floating labels covering curves.
Use distinct cyan usage and amber peak accents, subtle dashed grid/reference
lines, and linear interpolation that does not invent extrema.

## Risks And Acceptance

Verify summaries use the selected period and original samples. Never snap a
hover deep inside a missing interval to an unrelated record. Keep empty,
single-point, constant, dense and interrupted histories legible. No curve may
bridge a recording gap longer than two minutes. Check dark/light native
captures at default/minimum sizes, hover at both chart edges and a gap, range
switching, and compact overview/menu regressions. Validate Release build,
signature and desktop integration before switching the running app.

## Delivery

One focused 1.3.1 slice: implement, verify, document evidence, commit/push and
switch to a versioned local bundle. Preserve old bundles and user scratch files.

## Verification

- 16 targeted tests passed: history summaries/inspection, chart point budget,
  gap handling, all desktop-page rendering and native desktop window behavior.
  Command: `swift test --jobs 2 --filter 'HistoryChartTests|DesktopPresentationTests|DesktopWindowTests'`.
  Log: `/private/tmp/memory-monitor-v131-verification.log`.
- Verified full-range summaries and exact hover lookup use original samples,
  including records omitted from the 240-point drawing budget. Future, invalid
  and out-of-range samples cannot affect the summary; duplicate timestamps
  produce one plotted record. Empty and singleton histories remain defined.
- Native captures cover continuous/gapped, empty, single-point and constant
  100% histories in both appearances and two sizes. Six desktop pages and the
  compact menu were also rendered, with existing fixture history loaded for
  representative charts. Captures: `/private/tmp/memory-monitor-v131-layout-final/`.
- Visual review corrected oversized isolated points, inherited blue axis styles
  and clipped edge time labels. The percentage domain remains 0...100; 24-hour
  endpoint labels include the date. Hover publishes only a changed sample or
  gap selection, with no animation timer or extra sampling.
- `git diff --check` and source plist validation passed.

- Release arm64 build and ad-hoc signature verification passed. Version 1.3.1,
  build 131 is running from
  `~/Library/Application Support/MemoryMonitor/releases/1.3.1-final/MemoryMonitor.app`.
  The previous app was quit normally and older bundles were retained.
  Build log: `/private/tmp/memory-monitor-v131-build.log`.
- Desktop integration passed on macOS 26.5.1 / Apple Silicon; the login item
  remains enabled. Report: `/private/tmp/memory-monitor-v131-desktop-integration.json`.
- Live native mouse checks passed in dark and light appearances: 1/6/24-hour
  switching, distinct readings across left/middle/right chart positions,
  restoration of the latest reading on mouse exit, and an unclipped readout
  at 800 x 560. Screenshots were visually reviewed. The original dark appearance
  and 960 x 682 window size were restored, leaving the statistics page open.
  Log: `/private/tmp/memory-monitor-v131-live-ui-final.log`.
  Captures: `/private/tmp/memory-monitor-v131-live/`.
- A separate live check over an unrecorded interval in the 24-hour view showed
  the missing-record state and no unrelated sampled value. Log:
  `/private/tmp/memory-monitor-v131-live-gap.log`.
- The UI helper initially lost the foreground window to a system preview.
  Explicit cursor positioning and mouse events addressed to this app completed
  the checks without changes to production window behavior or system settings.

Validation is limited to the current macOS host and the 16 targeted tests;
the full release gate, restart/login behavior, older macOS versions and
Developer ID signing/notarization were not exercised for this chart-only slice.
