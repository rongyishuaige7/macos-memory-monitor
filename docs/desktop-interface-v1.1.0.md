# Desktop interface v1.1.0

## Scope

Replace the menu-only workflow with a persistent, resizable macOS window and
a compact menu-bar companion, following the supplied September 7 design.
Provide memory overview, processes, memory release, history, bounded memory
test, and settings. Settings must remain visible and interactive when the
menu-bar panel closes or the application loses focus.

## Architecture

- One AppKit window coordinator owns a normal NSWindow and SwiftUI navigation.
  Menu-bar actions route to it; no settings or detail sheets belong to a
  transient MenuBarExtra.
- Reuse MonitorViewModel, native sampling, history storage, login integration,
  and validated process actions. Track desktop and popover visibility separately.
- Use native materials, SF Symbols, a blue accent, cyan memory chart, purple,
  amber and green component keys. Charts contain actual observations only.
- Limit chart points and cache process filtering outside row rendering. Keep
  allocation and sampling work away from the main actor.

## Non-goals and behavior boundaries

No disk/cache deletion, speculative "reclaimable" totals, automatic process
termination, or invented process CPU/energy metrics. Memory release opens the
existing per-process confirmation flow. A test allocates only its own bounded
memory, supports cancellation, releases on completion/exit, and refuses to
start under high memory pressure. No new dependencies or unrelated refactors.

## Risks

Menu-bar focus and SwiftUI sheet ownership require native-window regression
checks. Multiple visible surfaces must not incorrectly lower sampling cadence.
The reference is a visual concept, not evidence that all illustrated metrics
exist. Large histories must not generate unbounded chart paths. Login launch
requires a stable application path; version identity must match the delivered
bundle. Memory tests must never allocate on the UI thread.

## Staged delivery

1. Persistent window routing and focus regression fix; tests, commit and push.
2. Desktop visual rebuild and functional pages; tests, Release build, native
   interaction checks and screenshots, commit and push, switch running app.

## Acceptance

- Settings controls, menus and navigation remain usable after panel dismissal
  and application deactivation; window close leaves menu monitoring alive.
- All sidebar destinations work at default and minimum window sizes, with
  no overlapping text or clipped actions.
- Process search and sorting work; destructive actions retain confirmation
  and identity revalidation. Unavailable/stale data remains distinguishable.
- History ranges display real retained records with bounded chart complexity.
- Memory test limits, cancellation and refusal conditions have regression tests.
- Swift tests and strict-concurrency Release build pass; delivered app is signed,
  has an explicit new version, and runs with fixture mode disabled.

## Verification log

Stage 1: independent NSWindow routing implemented. Two window lifecycle and
visibility tests plus 65 integration/presentation tests passed. Settings now
routes out of the menu panel; closing/reopening reuses the retained window.
The desktop page content is replaced in stage 2.
