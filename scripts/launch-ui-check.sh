#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"
script_name="$0"

usage() {
	print -u2 "Usage: $script_name --output-dir <new-or-empty-temporary-directory>"
	print -u2 "The directory must be an explicit absolute path below TMPDIR or /tmp."
}

if (( $# == 1 )) && [[ "$1" == "--help" || "$1" == "-h" ]]; then
	usage
	exit 0
fi
if (( $# != 2 )) || [[ "$1" != "--output-dir" ]]; then
	usage
	exit 2
fi

requested_output_root="$2"
if [[ -z "$requested_output_root" || "$requested_output_root" != /* ]]; then
	print -u2 -- "--output-dir must be a non-empty absolute path"
	exit 2
fi
if [[ "$requested_output_root" == *$'\n'* || "$requested_output_root" == *$'\r'* ]]; then
	print -u2 -- "--output-dir must not contain line breaks"
	exit 2
fi

# Resolve existing symlink components and dot segments before applying the
# safety boundaries. The final directory may not exist yet.
canonical_output_root="${requested_output_root:A}"
canonical_project_root="${project_root:A}"
if [[ -z "$canonical_output_root" || "$canonical_output_root" == "/" ||
	"$canonical_output_root" == "$canonical_project_root" ||
	"$canonical_output_root" == "$canonical_project_root"/* ]]; then
	print -u2 "Refusing an unsafe output directory: $requested_output_root"
	exit 2
fi

temporary_root_candidates=("${TMPDIR:-/tmp}" "/tmp")
is_temporary=0
for temporary_root in "${temporary_root_candidates[@]}"; do
	[[ -n "$temporary_root" && "$temporary_root" == /* ]] || continue
	canonical_temporary_root="${temporary_root:A}"
	if [[ "$canonical_output_root" == "$canonical_temporary_root"/* ]]; then
		is_temporary=1
		break
	fi
done
if (( ! is_temporary )); then
	print -u2 -- "--output-dir must be below TMPDIR or /tmp: $canonical_output_root"
	exit 2
fi

for command_name in swift plutil codesign file ps pgrep open env mkdir find sleep date sed; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		print -u2 "Required command not found: $command_name"
		exit 2
	fi
done

if [[ -L "$requested_output_root" ]]; then
	print -u2 "Refusing a symlink output directory: $requested_output_root"
	exit 2
fi
if [[ -e "$requested_output_root" ]]; then
	if [[ ! -d "$requested_output_root" ]]; then
		print -u2 "Output path is not a directory: $requested_output_root"
		exit 2
	fi
	if [[ -n "$(find "$requested_output_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
		print -u2 "Output directory must be empty to prevent stale UI-check data: $requested_output_root"
		exit 2
	fi
else
	mkdir -p -- "$requested_output_root"
fi

# Re-resolve after creation so a concurrent symlink replacement cannot move
# generated artifacts into the source tree or another non-temporary location.
canonical_output_after_mkdir="${requested_output_root:A}"
if [[ "$canonical_output_after_mkdir" != "$canonical_output_root" ||
	"$canonical_output_after_mkdir" == "$canonical_project_root" ||
	"$canonical_output_after_mkdir" == "$canonical_project_root"/* ]]; then
	print -u2 "Output directory changed or resolves into the project: $requested_output_root"
	exit 2
fi
canonical_output_root="$canonical_output_after_mkdir"

app_output_root="$canonical_output_root/app-output"
storage_root="$canonical_output_root/storage"
isolated_home="$canonical_output_root/home"
isolated_tmp="$canonical_output_root/tmp"
launch_log_path="$canonical_output_root/launch-services.log"
if [[ -e "$app_output_root" || -L "$app_output_root" ]]; then
	print -u2 "Refusing an existing app output path: $app_output_root"
	exit 2
fi
mkdir -m 700 -- "$storage_root" "$isolated_home" "$isolated_tmp"

bundle_id="com.rongyi.MemoryMonitorUICheck.$(date -u +%Y%m%d%H%M%S).$$"
build_script="$project_root/scripts/build-app.sh"
if [[ ! -x "$build_script" ]]; then
	print -u2 "Build script is missing or not executable: $build_script"
	exit 2
fi

print "Building isolated UI-check bundle..."
env -u APP_VERSION -u BUILD_NUMBER \
	CONFIGURATION=release \
	OUTPUT_DIR="$app_output_root" \
	SKIP_SIGNING=1 \
	"$build_script"

app_path="$app_output_root/MemoryMonitor.app"
app_plist="$app_path/Contents/Info.plist"
app_binary="$app_path/Contents/MacOS/memory-monitor-app"
if [[ ! -d "$app_path" || -L "$app_path" || ! -f "$app_plist" || ! -x "$app_binary" ]]; then
	print -u2 "Built UI-check bundle is incomplete: $app_path"
	exit 1
fi

plutil -replace CFBundleIdentifier -string "$bundle_id" "$app_plist"
plutil -replace CFBundleDisplayName -string "Memory Monitor UI Check" "$app_plist"
plutil -replace CFBundleName -string "MemoryMonitorUICheck" "$app_plist"
plutil -lint "$app_plist" >/dev/null

# The build helper intentionally skipped its first signature so this script
# can assign a unique bundle identifier before signing the final artifact.
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"

actual_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app_plist")"
if [[ "$actual_bundle_id" != "$bundle_id" ]]; then
	print -u2 "Bundle identifier update did not stick: $actual_bundle_id"
	exit 1
fi
binary_description="$(file -b "$app_binary")"
if [[ "$binary_description" != *arm64* ]]; then
	print -u2 "Built UI-check executable is not arm64: $binary_description"
	exit 1
fi

print "Launching isolated UI-check process through Launch Services..."
if ! env \
	HOME="$isolated_home" \
	CFFIXED_USER_HOME="$isolated_home" \
	TMPDIR="$isolated_tmp" \
	MEMORY_MONITOR_UI_CHECK_STORAGE_ROOT="$storage_root" \
	open -n -g "$app_path" > /dev/null 2>"$launch_log_path"; then
	print -u2 "Launch Services could not open the UI-check bundle"
	if [[ -s "$launch_log_path" ]]; then
		print -u2 -- "$(sed -n '1,20p' "$launch_log_path")"
	fi
	exit 1
fi

# `open` returns before the application process is observable. Match the
# exact executable path so a concurrently running formal instance can never
# be reported as this UI-check process.
pid=""
started=0
for _ in {1..50}; do
	for candidate_pid in ${(f)"$(pgrep -f "$app_binary" 2>/dev/null || true)"}; do
		[[ "$candidate_pid" == <-> ]] || continue
		candidate_command="$(ps -p "$candidate_pid" -o command= 2>/dev/null | sed 's/^[[:space:]]*//')"
		if [[ "$candidate_command" == "$app_binary" ]]; then
			pid="$candidate_pid"
			started=1
			break 2
		fi
	done
	sleep 0.1
done
if (( ! started )); then
	print -u2 "UI-check process was not observable after Launch Services request"
	if [[ -s "$launch_log_path" ]]; then
		print -u2 -- "$(sed -n '1,20p' "$launch_log_path")"
	fi
	exit 1
fi

print "UI_CHECK_PID=$pid"
print "UI_CHECK_BUNDLE_ID=$bundle_id"
print "UI_CHECK_APP_PATH=$app_path"
print "UI_CHECK_STORAGE_ROOT=$storage_root"
print "UI_CHECK_HOME=$isolated_home"
print "UI_CHECK_LAUNCH_LOG=$launch_log_path"
print "UI_CHECK_LAUNCH_MODE=launch-services"
print "UI_CHECK_ARCHITECTURE=arm64"
print "UI_CHECK_SIGNATURE=ad-hoc"
print "No UI actions or process signals were issued by this launcher."
