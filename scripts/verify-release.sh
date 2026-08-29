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

print "Running Swift tests..."
swift test --package-path "$project_root" --parallel

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
print "Artifact: $app_path"
