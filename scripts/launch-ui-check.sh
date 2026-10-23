#!/bin/zsh
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"
script_name="$0"

usage() {
	print -u2 "Usage: $script_name --output-dir <new-or-empty-temporary-directory>"
	print -u2 "The directory must be an explicit absolute path below the system Darwin user temporary root or /tmp."
}

if (( $# == 1 )) && [[ "$1" == "--help" || "$1" == "-h" ]]; then
	usage
	exit 0
fi
if (( $# != 2 )) || [[ "$1" != "--output-dir" ]]; then
	usage
	exit 2
fi

requested_output_argument="$2"
if [[ -z "$requested_output_argument" ]]; then
	print -u2 -- "--output-dir must be a non-empty absolute path"
	exit 2
fi

# Keep the shell-side path parser in lockstep with
# `MemoryMonitorStoragePaths.canonicalTemporaryPath`: trim surrounding
# whitespace, reject embedded line breaks, and resolve existing symlink
# components before applying a complete path-component boundary. Keep both
# the trimmed lexical spelling and the resolved spelling: the former is used
# for filesystem checks so a final symlink cannot disappear into `${path:A}`;
# `REPLY` avoids command substitution changing paths that contain spaces.
canonicalize_absolute_path() {
	setopt localoptions extendedglob
	local raw_path="$1"
	local trimmed_path="$raw_path"
	trimmed_path="${trimmed_path##[[:space:]]##}"
	trimmed_path="${trimmed_path%%[[:space:]]##}"
	[[ -n "$trimmed_path" && "$trimmed_path" == /* ]] || return 1
	[[ "$trimmed_path" != *$'\n'* && "$trimmed_path" != *$'\r'* ]] || return 1
	local lexical_path="${trimmed_path:a}"
	local resolved_path="${trimmed_path:A}"
	[[ -n "$resolved_path" && "$resolved_path" == /* && "$resolved_path" != "/" ]] || return 1
	[[ -n "$lexical_path" && "$lexical_path" == /* ]] || return 1
	RAW_REPLY="$trimmed_path"
	LEXICAL_REPLY="$lexical_path"
	REPLY="$resolved_path"
}

# `${path:A}` can leave a dangling symlink followed by a not-yet-created suffix
# looking lexical. Walk every raw prefix and reject ordinary symlink components
# before `mkdir -p` can follow a link whose destination might later be created
# elsewhere. The only existing links allowed here are macOS's `/tmp` and `/var`
# aliases; verify their resolved destinations instead of trusting their names.
is_allowed_system_alias() {
	local alias_path="$1"
	case "$alias_path" in
		/tmp)
			[[ "${alias_path:A}" == "/private/tmp" && -d "/private/tmp" ]]
			;;
		/var)
			[[ "${alias_path:A}" == "/private/var" && -d "/private/var" ]]
			;;
		*)
			return 1
			;;
	esac
}

has_unsafe_symlink_prefix() {
	local probe="$1"
	while :; do
		while [[ "$probe" == */ && "$probe" != "/" ]]; do
			probe="${probe%/}"
		done
		if [[ -L "$probe" ]] && ! is_allowed_system_alias "$probe"; then
			return 0
		fi
		[[ "$probe" == "/" ]] && return 1
		probe="${probe%/*}"
		[[ -n "$probe" ]] || probe="/"
	done
}

if ! canonicalize_absolute_path "$requested_output_argument"; then
	print -u2 -- "--output-dir must be a non-empty absolute path without embedded line breaks"
	exit 2
fi
requested_output_root="$RAW_REPLY"
lexical_output_root="$LEXICAL_REPLY"
canonical_output_root="$REPLY"

canonical_project_root="${project_root:A}"

# `getconf DARWIN_USER_TEMP_DIR` is the shell equivalent of Darwin's
# `confstr(_CS_DARWIN_USER_TEMP_DIR)`. Do not use the caller-controlled
# `TMPDIR` as a trust anchor. A failed or malformed query deliberately leaves
# only canonical `/tmp` in the trust set, matching Core's fail-closed rule.
darwin_path_max=1024
getconf_binary="/usr/bin/getconf"
darwin_temp_root_raw=""
if [[ -x "$getconf_binary" ]]; then
	path_max_value="$($getconf_binary PATH_MAX / 2>/dev/null || true)"
	if [[ "$path_max_value" == <-> && "$path_max_value" -gt 1 ]]; then
		darwin_path_max="$path_max_value"
	fi
	darwin_temp_root_raw="$($getconf_binary DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
fi

trusted_temporary_roots=()
if [[ -n "$darwin_temp_root_raw" ]]; then
	# Core's fixed PATH_MAX buffer accepts a confstr value only when the
	# returned length is strictly less than the buffer size. confstr reports
	# the terminating NUL in that length, so the shell equivalent is
	# `payloadBytes + 1 < PATH_MAX` (not `<=`). Paths returned by getconf are
	# normally ASCII; C locale length is the byte count that matters here.
	local_path_locale="${LC_ALL-}"
	LC_ALL=C
	darwin_temp_root_bytes=${#darwin_temp_root_raw}
	if (( darwin_temp_root_bytes + 1 < darwin_path_max )) &&
		canonicalize_absolute_path "$darwin_temp_root_raw"; then
		trusted_temporary_roots+=("$REPLY")
	fi
	if [[ -n "$local_path_locale" ]]; then
		LC_ALL="$local_path_locale"
	else
		unset LC_ALL
	fi
fi

tmp_root="/tmp"
if ! canonicalize_absolute_path "$tmp_root"; then
	print -u2 "Unable to resolve the canonical /tmp trust root"
	exit 2
fi
canonical_tmp_root="$REPLY"
if (( ${#trusted_temporary_roots[@]} == 0 )) ||
	[[ "${trusted_temporary_roots[1]}" != "$canonical_tmp_root" ]]; then
	trusted_temporary_roots+=("$canonical_tmp_root")
fi

# Resolve existing symlink components and dot segments before applying the
# safety boundaries. The final directory may not exist yet.
if [[ -z "$canonical_output_root" || "$canonical_output_root" == "/" ||
	"$canonical_output_root" == "$canonical_project_root" ||
	"$canonical_output_root" == "$canonical_project_root"/* ]]; then
	print -u2 "Refusing an unsafe output directory: $requested_output_root"
	exit 2
fi

is_temporary=0
trusted_output_root=""
for temporary_root in "${trusted_temporary_roots[@]}"; do
	if [[ "$canonical_output_root" == "$temporary_root"/* ]]; then
		is_temporary=1
		trusted_output_root="$temporary_root"
		break
	fi
done
if (( ! is_temporary )); then
	print -u2 -- "--output-dir must be below the system Darwin user temporary root or /tmp: $canonical_output_root"
	exit 2
fi

if has_unsafe_symlink_prefix "$requested_output_root" ||
	has_unsafe_symlink_prefix "$lexical_output_root"; then
	print -u2 "Refusing an output directory with an unsafe symlink ancestor: $requested_output_root"
	exit 2
fi

for command_name in swift plutil codesign file ps pgrep open env mkdir chmod find sleep date sed stat awk; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		print -u2 "Required command not found: $command_name"
		exit 2
	fi
done

if [[ -L "$lexical_output_root" ]]; then
	print -u2 "Refusing a symlink output directory: $requested_output_root"
	exit 2
fi
if [[ -e "$lexical_output_root" ]]; then
	if [[ ! -d "$lexical_output_root" ]]; then
		print -u2 "Output path is not a directory: $requested_output_root"
		exit 2
	fi
	if [[ -n "$(find "$lexical_output_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
		print -u2 "Output directory must be empty to prevent stale UI-check data: $requested_output_root"
		exit 2
	fi
else
	mkdir -p -- "$lexical_output_root"
fi

# Re-resolve after creation so a concurrent symlink replacement cannot move
# generated artifacts into the source tree or another non-temporary location.
if [[ -L "$lexical_output_root" ]] ||
	has_unsafe_symlink_prefix "$requested_output_root" ||
	has_unsafe_symlink_prefix "$lexical_output_root"; then
	print -u2 "Output directory changed to a symlink or unsafe ancestor: $requested_output_root"
	exit 2
fi
canonical_output_after_mkdir="${lexical_output_root:A}"
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

# Keep SwiftPM/build staging and the fixture writer away from a caller's
# potentially persistent TMPDIR. The selected anchor is already one of the
# fixed trusted roots and remains compatible with the fixture writer's paired
# storage check; the launched App receives the narrower sibling `isolated_tmp`
# below.
build_temporary_root="$trusted_output_root"

print "Building isolated fixture writer..."
env TMPDIR="$build_temporary_root" swift build \
	--package-path "$project_root" \
	--configuration release \
	--product memory-monitor-fixture
fixture_bin_dir="$(env TMPDIR="$build_temporary_root" swift build \
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
if ! env TMPDIR="$build_temporary_root" "$fixture_binary" --storage-root "$storage_root" >"$fixture_log_path" 2>&1; then
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
history_segments="$storage_root/history.json.segments"
if [[ ! -d "$history_segments" || -L "$history_segments" ||
      "$(stat -f '%Lp' "$history_segments")" != "700" ]]; then
	print -u2 "Fixture history segments directory is missing or unsafe"
	exit 1
fi
fixture_paths=(
	"$history_file"
	"$history_journal"
	"$history_clock"
	"$history_lock"
	"$audit_file"
	"$audit_clock"
	"$audit_lock"
	"$storage_root/.maintenance.lock"
	"$history_segments"/*.json(N)
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
if [[ "$storage_entry_count" != "9" ]]; then
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
	TMPDIR="$build_temporary_root" \
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
# be reported as this UI-check process. macOS `pgrep -x` anchors the full
# command line but still interprets its pattern as a regular expression, so
# escape the path before using `-fx` (for example, `[` and `+` are valid path
# characters but have special regex meaning).
app_binary_pattern="$(printf '%s' "$app_binary" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
pid=""
started=0
for _ in {1..50}; do
	for candidate_pid in ${(f)"$(pgrep -fx "$app_binary_pattern" 2>/dev/null || true)"}; do
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
# Add explicit separators so a command/path or similarly named variable cannot
# satisfy a check as a substring (for example, `NOT_HOME=...`).
launch_process_environment=" $(ps eww "$pid" 2>/dev/null || true) "
if [[ "$launch_process_environment" != *" HOME=$isolated_home "* ||
	"$launch_process_environment" != *" CFFIXED_USER_HOME=$isolated_home "* ||
	"$launch_process_environment" != *" TMPDIR=$isolated_tmp "* ||
	"$launch_process_environment" != *" MEMORY_MONITOR_UI_CHECK_STORAGE_ROOT=$storage_root "* ||
	"$launch_process_environment" != *" MEMORY_MONITOR_UI_CHECK_FIXTURE=1 "* ]]; then
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
