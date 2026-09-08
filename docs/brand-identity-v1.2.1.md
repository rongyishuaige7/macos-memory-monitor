# Memory Monitor identity v1.2.1

## Scope

Create an original geometric M monogram inside an open monitoring ring.
Use the existing cyan accent, a neutral graphite macOS tile, and a monochrome
variant for small native surfaces. Deliver editable SVG/PDF, transparent PNG,
a complete multi-resolution ICNS, and a visual size/contrast proof.
Apply the mark to the app bundle, sidebar, about row and compact menu-bar mode.

## Architecture

Core Graphics paths are the single editable geometry source. A local Swift
exporter reuses them to produce vector and raster assets; SwiftUI uses the
same paths directly for native symbols. The bundle builder copies the ICNS
declared in Info.plist before signing. No external dependencies or image API.
This is a precise code-native identity, not an AI-generated illustration.
The compact menu-bar label uses a cached, vector-backed template NSImage:
MenuBarExtra extracts Image labels and does not display a custom Shape there.

## Non-goals

No changes to monitoring, process actions, motion, history, sampling or login
preferences. No cache purges, commercial image API calls, or logo animation.
The monitoring ring is a static identity element, not a capacity reading.

## Delivery

One focused 1.2.1 slice: create and inspect the assets, integrate native and
bundle icons, verify, commit/push, and switch to the versioned signed build.

## Risks And Acceptance

- Inspect the mark at 16/32/64/128 px and on light/dark backgrounds.
- All app icon representations retain transparent outer corners and consistent
  optical bounds. Export with deterministic geometry, without cropped shadows.
- Validate the ICNS representations, vector outputs, bundle icon declaration,
  signature and live Dock/native interface appearance.
- Run focused desktop rendering and bundle integration checks. Do not terminate
  real user processes or run a memory stress test for branding verification.
- Preserve existing user files and prior versioned application packages.

## Verification

- Inspected the app icon at 16/32/128/1024 px and the 16/32/64/96 px
  monochrome proof. Shadow offset and blur scale explicitly with export size.
- Checked all 10 source icon representations and all 10 representations
  extracted from the ICNS: correct dimensions, zero-alpha outer corners and
  opaque, nonblank centers. Validated three SVG namespaces, three transparent
  1024 px PNGs and the single-page vector PDF.
- `swift test --filter 'DesktopPresentationTests|DesktopWindowTests'`: 10
  tests passed. The render test covers six pages in two sizes and two
  appearances, plus the menu panel. Inspected default overview and minimum
  settings screenshots in both appearances.
- `plutil -lint`, `zsh -n scripts/build-app.sh` and `git diff --check` passed.
- After the menu-bar template-image correction, reran
  `DesktopPresentationTests.testAllDesktopPagesRenderAtDefaultAndMinimumSizes`:
  passed with all 25 rendered surfaces.
- Built the Release arm64 bundle at
  `~/Library/Application Support/MemoryMonitor/releases/1.2.1-final/MemoryMonitor.app`
  with version 1.2.1, build 121 and ad-hoc signing. Strict codesign verification
  passed; the bundled ICNS is byte-identical to the source asset.
- Desktop integration passed; the existing login item remains enabled. Report:
  `/private/tmp/memory-monitor-v121-final-desktop-integration.json`.
- Live screenshots verified sidebar/about marks in light and dark appearances,
  the Dock icon and the 17 pt menu-bar template mark. The compact status item
  measures 35 x 24 pt, and its screenshot contains 137 distinct colors rather
  than a blank background. The menu-to-settings route also passed. Restored
  dark appearance and enabled percentage display, then returned to overview.
  Screenshots: `/private/tmp/memory-monitor-v121-live/`.
- The final signed bundle is running with UI fixtures disabled. Prior versioned
  app bundles are retained.

The first build waited on existing Desktop module-cache files. The successful
Release build used the temporary environment override
`SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/memory-monitor-v121-module-cache`;
no existing cache or project configuration was removed or replaced.

## Reproduce Assets

On macOS, from the repository root:

```sh
swiftc -parse-as-library Sources/MemoryMonitorApp/BrandArtwork.swift scripts/render-brand.swift -o /tmp/memory-monitor-render-brand
/tmp/memory-monitor-render-brand Resources/Brand
iconutil -c icns Resources/Brand/MemoryMonitor.iconset -o Resources/MemoryMonitor.icns
```

`MemoryMonitor.png` is the 1024 px app icon. `Logo.svg`, `Logo-Black.svg`,
`Logo-White.svg` and matching PNGs have transparent backgrounds; `Logo.pdf`
contains the monochrome vector mark. `Logo-Preview.png` shows the app icon,
wordmark, small glyphs and contrast variants. All iconset images are checked in
so rebuilding the application does not require running the artwork exporter.
