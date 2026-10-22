#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"
info_plist="$project_root/Resources/Info.plist"

for command_name in git plutil swift awk grep mktemp file codesign env; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		print -u2 "Required command not found: $command_name"
		exit 2
	fi
done

plutil -lint "$info_plist" >/dev/null
source_version="$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
source_build="$(plutil -extract CFBundleVersion raw -o - "$info_plist")"
if [[ -z "$source_version" || -z "$source_build" ]]; then
	print -u2 "Info.plist is missing a bundle version"
	exit 2
fi

# This is a release gate, so whitespace errors in tracked files are failures.
# Untracked user experiments do not affect this check.
git -C "$project_root" diff --check
git -C "$project_root" diff --cached --check

zsh "$script_dir/test-bundle-replacement.sh"
print "Running Swift tests..."
# Isolate native suites: AppKit activation state survives NSApp.stop() and can
# otherwise contaminate the next suite in a single XCTest process.
swift test --package-path "$project_root" \
	--skip 'CleanupMotionTests|DesktopMotionTests|SmartCleanupNativeTests|DesktopWindowTests'
"$script_dir/verify-native-tests.sh"

print "Building Debug with strict concurrency..."
swift build \
	--package-path "$project_root" \
	--configuration debug \
	-Xswiftc -strict-concurrency=complete

print "Building Release with strict concurrency..."
swift build \
	--package-path "$project_root" \
	--configuration release \
	-Xswiftc -strict-concurrency=complete

verification_root="$(mktemp -d "${TMPDIR:-/tmp}/memory-monitor-release.XXXXXX")"
trap 'if [[ -n "${verification_root:-}" && -d "$verification_root" ]]; then rm -rf -- "$verification_root"; fi' EXIT

probe_log="$verification_root/probe.log"
print "Running Release probe..."
swift run \
	--package-path "$project_root" \
	--configuration release \
	memory-monitor-probe >"$probe_log"
grep -q '^Memory Monitor Probe$' "$probe_log"
grep -q '^Processes:[[:space:]]' "$probe_log"

compatibility_report="$verification_root/compatibility.json"
compatibility_plist="$verification_root/compatibility.plist"
print "Collecting structured compatibility report..."
"$project_root/scripts/collect-compatibility-report.sh" >"$compatibility_report"
plutil -convert xml1 -o "$compatibility_plist" -- "$compatibility_report"
compatibility_schema="$(plutil -extract schemaVersion raw -o - "$compatibility_plist")"
compatibility_architecture="$(plutil -extract platform.architecture raw -o - "$compatibility_plist")"
compatibility_os_major="$(plutil -extract platform.osMajor raw -o - "$compatibility_plist")"
compatibility_os_minor="$(plutil -extract platform.osMinor raw -o - "$compatibility_plist")"
compatibility_os_patch="$(plutil -extract platform.osPatch raw -o - "$compatibility_plist")"
compatibility_limitations="$(plutil -extract limitations raw -o - "$compatibility_plist")"
compatibility_process_scan="$(plutil -extract sampling.processes.samplingPerformed raw -o - "$compatibility_plist")"
if [[ "$compatibility_schema" != "1" || \
	"$compatibility_architecture" != "arm64" || \
	"$compatibility_limitations" != "3" || \
	"$compatibility_process_scan" != "true" ]]; then
	print -u2 "Structured compatibility report failed release validation"
	exit 1
fi

artifact_root="$verification_root/dist"
build_log="$verification_root/build.log"
print "Building and signing default App bundle..."
# Ignore inherited candidate-version overrides so this gate specifically tests
# that the source plist remains the default version authority.
env -u APP_VERSION -u BUILD_NUMBER \
	OUTPUT_DIR="$artifact_root" \
	"$project_root/scripts/build-app.sh" >"$build_log"

app_path="$artifact_root/MemoryMonitor.app"
app_plist="$app_path/Contents/Info.plist"
app_binary="$app_path/Contents/MacOS/memory-monitor-app"
[[ -d "$app_path" ]]
[[ -f "$app_plist" ]]
[[ -x "$app_binary" ]]

bundle_version="$(plutil -extract CFBundleShortVersionString raw -o - "$app_plist")"
bundle_build="$(plutil -extract CFBundleVersion raw -o - "$app_plist")"
if [[ "$bundle_version" != "$source_version" || "$bundle_build" != "$source_build" ]]; then
	print -u2 "Generated bundle version does not match Info.plist: $bundle_version/$bundle_build"
	exit 1
fi

binary_description="$(file -b "$app_binary")"
if [[ "$binary_description" != *arm64* ]]; then
	print -u2 "Generated app is not arm64: $binary_description"
	exit 1
fi
codesign --verify --deep --strict "$app_path"

probe_sampling="$(awk '/^Sampling:/{sub(/^Sampling:[[:space:]]*/, ""); print; exit}' "$probe_log")"
probe_processes="$(awk '/^Processes:/{sub(/^Processes:[[:space:]]*/, ""); print; exit}' "$probe_log")"
print "Release verification passed"
print "Version: $bundle_version (build $bundle_build)"
print "Probe: sampling=$probe_sampling; processes=$probe_processes"
print "Compatibility: schema=$compatibility_schema; macOS=$compatibility_os_major.$compatibility_os_minor.$compatibility_os_patch; architecture=$compatibility_architecture"
print "Artifact: $app_path"
