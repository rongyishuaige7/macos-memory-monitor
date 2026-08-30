#!/bin/zsh
set -euo pipefail
umask 077

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

for command_name in swift plutil codesign file ps pgrep open env mkdir find sleep date sed stat awk; do
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
chmod 700 "$canonical_output_root"

app_output_root="$canonical_output_root/app-output"
storage_root="$canonical_output_root/storage"
isolated_home="$canonical_output_root/home"
isolated_tmp="$canonical_output_root/tmp"
launch_log_path="$canonical_output_root/launch-services.log"
fixture_log_path="$canonical_output_root/fixture.log"
if [[ -e "$app_output_root" || -L "$app_output_root" ]]; then
	print -u2 "Refusing an existing app output path: $app_output_root"
	exit 2
fi
mkdir -m 700 -- "$storage_root" "$isolated_home" "$isolated_tmp"

print "Building isolated fixture writer..."
swift build \
	--package-path "$project_root" \
	--configuration release \
	--product memory-monitor-fixture
fixture_bin_dir="$(swift build \
	--package-path "$project_root" \
	--configuration release \
	--show-bin-path)"
fixture_binary="$fixture_bin_dir/memory-monitor-fixture"
if [[ ! -x "$fixture_binary" ]]; then
	print -u2 "Built fixture writer not found: $fixture_binary"
	exit 1
fi
fixture_description="$(file -b "$fixture_binary")"
if [[ "$fixture_description" != *arm64* ]]; then
	print -u2 "Built fixture writer is not arm64: $fixture_description"
	exit 1
fi

print "Generating isolated history and audit fixture..."
if ! "$fixture_binary" --storage-root "$storage_root" >"$fixture_log_path" 2>&1; then
	print -u2 "Fixture writer failed"
	if [[ -s "$fixture_log_path" ]]; then
		print -u2 -- "$(sed -n '1,40p' "$fixture_log_path")"
	fi
	exit 1
fi

fixture_history_records="$(sed -n 's/^FIXTURE_HISTORY_RECORDS=//p' "$fixture_log_path")"
fixture_audit_events="$(sed -n 's/^FIXTURE_AUDIT_EVENTS=//p' "$fixture_log_path")"
fixture_journal_records="$(sed -n 's/^FIXTURE_HISTORY_JOURNAL_RECORDS=//p' "$fixture_log_path")"
if [[ "$fixture_history_records" != <-> ||
	"$fixture_audit_events" != <-> ||
	"$fixture_journal_records" != <-> ||
	"$fixture_history_records" -lt 2 ||
	"$fixture_audit_events" -lt 2 ||
	"$fixture_journal_records" -ne $(( fixture_history_records - 1 )) ]]; then
	print -u2 "Fixture writer reported invalid record counts"
	print -u2 -- "$(sed -n '1,40p' "$fixture_log_path")"
	exit 1
fi

history_file="$storage_root/history.json"
history_journal="$storage_root/history.json.journal"
history_clock="$storage_root/history.json.clock"
history_lock="$storage_root/history.json.lock"
audit_file="$storage_root/actions.jsonl"
audit_clock="$storage_root/actions.jsonl.clock"
audit_lock="$storage_root/actions.jsonl.lock"
fixture_paths=(
	"$history_file"
	"$history_journal"
	"$history_clock"
	"$history_lock"
	"$audit_file"
	"$audit_clock"
	"$audit_lock"
)
for fixture_path in "${fixture_paths[@]}"; do
	if [[ ! -f "$fixture_path" || -L "$fixture_path" ]]; then
		print -u2 "Fixture output is missing or not a regular file: $fixture_path"
		exit 1
	fi
	fixture_permissions="$(stat -f '%Lp' "$fixture_path" 2>/dev/null || true)"
	if [[ "$fixture_permissions" != "600" ]]; then
		print -u2 "Fixture output has unexpected permissions ($fixture_permissions): $fixture_path"
		exit 1
	fi
done
storage_permissions="$(stat -f '%Lp' "$storage_root" 2>/dev/null || true)"
if [[ "$storage_permissions" != "700" ]]; then
	print -u2 "Fixture storage root has unexpected permissions: $storage_permissions"
	exit 1
fi
storage_entry_count="$(find "$storage_root" -mindepth 1 -maxdepth 1 -print | awk 'END { print NR }')"
if [[ "$storage_entry_count" != "7" ]]; then
	print -u2 "Fixture storage root contains an unexpected number of files: $storage_entry_count"
	exit 1
fi
history_line_count="$(awk 'END { print NR }' "$history_journal")"
audit_line_count="$(awk 'END { print NR }' "$audit_file")"
if [[ "$history_line_count" != "$fixture_journal_records" ||
	"$audit_line_count" != "$fixture_audit_events" ]]; then
	print -u2 "Fixture file line counts do not match writer output"
	exit 1
fi
if [[ ! -s "$history_file" || ! -s "$history_journal" ||
	! -s "$history_clock" || ! -s "$audit_file" || ! -s "$audit_clock" ]]; then
	print -u2 "Fixture data or clock file is empty"
	exit 1
fi
# The fixture writer has already decoded the JSON snapshot, journal, JSONL
# events, and both clock sidecars through the production store actors. Keep
# this shell layer format-agnostic: `plutil -lint` only accepts plist syntax
# on the supported macOS versions and would reject these valid JSON files.

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
if ! env -i \
	PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
	HOME="$isolated_home" \
	CFFIXED_USER_HOME="$isolated_home" \
	TMPDIR="$isolated_tmp" \
	MEMORY_MONITOR_UI_CHECK_STORAGE_ROOT="$storage_root" \
	MEMORY_MONITOR_UI_CHECK_FIXTURE=1 \
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

# Launch Services is an external boundary: fail closed if it drops any of the
# paths or the explicit fixture switch. Keep the complete `ps` payload in
# memory only and never echo it, since unrelated inherited values are private.
launch_process_environment="$(ps eww "$pid" 2>/dev/null || true)"
if [[ "$launch_process_environment" != *"HOME=$isolated_home"* ||
	"$launch_process_environment" != *"CFFIXED_USER_HOME=$isolated_home"* ||
	"$launch_process_environment" != *"TMPDIR=$isolated_tmp"* ||
	"$launch_process_environment" != *"MEMORY_MONITOR_UI_CHECK_STORAGE_ROOT=$storage_root"* ||
	"$launch_process_environment" != *"MEMORY_MONITOR_UI_CHECK_FIXTURE=1"* ]]; then
	unset launch_process_environment
	print -u2 "UI-check process did not inherit the required isolated environment"
	exit 1
fi
unset launch_process_environment

launch_log_permissions="$(stat -f '%Lp' "$launch_log_path" 2>/dev/null || true)"
if [[ "$launch_log_permissions" != "600" ]]; then
	print -u2 "Launch Services log has unexpected permissions: $launch_log_permissions"
	exit 1
fi

print "UI_CHECK_PID=$pid"
print "UI_CHECK_BUNDLE_ID=$bundle_id"
print "UI_CHECK_APP_PATH=$app_path"
print "UI_CHECK_STORAGE_ROOT=$storage_root"
print "UI_CHECK_HOME=$isolated_home"
print "UI_CHECK_LAUNCH_LOG=$launch_log_path"
print "UI_CHECK_FIXTURE_LOG=$fixture_log_path"
print "UI_CHECK_FIXTURE_HISTORY_RECORDS=$fixture_history_records"
print "UI_CHECK_FIXTURE_AUDIT_EVENTS=$fixture_audit_events"
print "UI_CHECK_FIXTURE_JOURNAL_RECORDS=$fixture_journal_records"
print "UI_CHECK_LAUNCH_MODE=launch-services"
print "UI_CHECK_ARCHITECTURE=arm64"
print "UI_CHECK_SIGNATURE=ad-hoc"
print "UI_CHECK_ENVIRONMENT=minimal"
print "No UI actions or process signals were issued by this launcher."
