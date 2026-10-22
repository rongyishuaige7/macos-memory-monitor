#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"
source "$script_dir/build-provenance.zsh"
source_plist="$project_root/Resources/Info.plist"

app_path=""
output_path=""
include_audit_token=0

usage() {
	print -u2 "Usage: $0 --app /absolute/path/MemoryMonitor.app --output /absolute/path/report.json [--audit-token]"
}

while (( $# > 0 )); do
	case "$1" in
		--app)
			(( $# >= 2 )) || { usage; exit 2; }
			[[ -z "$app_path" ]] || { print -u2 "--app may be specified only once"; exit 2; }
			app_path="$2"
			shift 2
			;;
		--output)
			(( $# >= 2 )) || { usage; exit 2; }
			[[ -z "$output_path" ]] || { print -u2 "--output may be specified only once"; exit 2; }
			output_path="$2"
			shift 2
			;;
		--audit-token)
			(( include_audit_token == 0 )) || { print -u2 "--audit-token may be specified only once"; exit 2; }
			include_audit_token=1
			shift
			;;
		*)
			usage
			exit 2
			;;
	esac
done

if [[ -z "$app_path" || -z "$output_path" ]]; then
	usage
	exit 2
fi
if [[ "$app_path" != /* || "$output_path" != /* ]]; then
	print -u2 "--app and --output must be absolute paths"
	exit 2
fi
if [[ -e "$output_path" || -L "$output_path" ]]; then
	print -u2 "Refusing to overwrite an existing report: $output_path"
	exit 2
fi
if (( include_audit_token )) && [[ "${MEMORY_MONITOR_ALLOW_AUDIT_TOKEN_TEST:-}" != "1" ]]; then
	print -u2 "--audit-token requires MEMORY_MONITOR_ALLOW_AUDIT_TOKEN_TEST=1"
	exit 2
fi

for command_name in awk codesign env file git install mktemp plutil python3 shasum; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		print -u2 "Required command not found: $command_name"
		exit 2
	fi
done

if [[ ! -d "$app_path" || -L "$app_path" ]]; then
	print -u2 "App bundle is missing or is a symlink: $app_path"
	exit 2
fi
app_path="${app_path:A}"
app_plist="$app_path/Contents/Info.plist"
if [[ ! -f "$app_plist" || -L "$app_plist" ]]; then
	print -u2 "App Info.plist is missing or is a symlink"
	exit 2
fi
plutil -lint "$source_plist" >/dev/null
plutil -lint "$app_plist" >/dev/null

bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$app_plist")"
bundle_executable="$(plutil -extract CFBundleExecutable raw -o - "$app_plist")"
bundle_package_type="$(plutil -extract CFBundlePackageType raw -o - "$app_plist")"
bundle_version="$(plutil -extract CFBundleShortVersionString raw -o - "$app_plist")"
bundle_build="$(plutil -extract CFBundleVersion raw -o - "$app_plist")"
bundle_minimum_system="$(plutil -extract LSMinimumSystemVersion raw -o - "$app_plist")"
bundle_ui_element="$(plutil -extract LSUIElement raw -o - "$app_plist")"
bundle_multiple_instances="$(plutil -extract LSMultipleInstancesProhibited raw -o - "$app_plist")"
source_version="$(plutil -extract CFBundleShortVersionString raw -o - "$source_plist")"
source_build="$(plutil -extract CFBundleVersion raw -o - "$source_plist")"
if [[ "$bundle_identifier" != "com.rongyi.MemoryMonitor" || \
	"$bundle_executable" != "memory-monitor-app" || \
	"$bundle_package_type" != "APPL" || \
	"$bundle_minimum_system" != "14.0" || \
	"$bundle_ui_element" != "true" || \
	"$bundle_multiple_instances" != "true" ]]; then
	print -u2 "Unexpected app identity: $bundle_identifier / $bundle_executable"
	exit 2
fi
if [[ "$bundle_version" != "$source_version" || "$bundle_build" != "$source_build" ]]; then
	print -u2 "App version does not match the source Info.plist"
	exit 2
fi

app_binary="$app_path/Contents/MacOS/$bundle_executable"
if [[ ! -x "$app_binary" || -L "$app_binary" ]]; then
	print -u2 "App executable is missing or is a symlink"
	exit 2
fi
binary_description="$(file -b "$app_binary")"
if [[ "$binary_description" != *arm64* ]]; then
	print -u2 "App executable is not arm64: $binary_description"
	exit 2
fi
codesign --verify --deep --strict "$app_path"

output_parent="${output_path:h}"
if [[ ! -d "$output_parent" || -L "$output_parent" ]]; then
	print -u2 "Report parent directory is missing or is a symlink: $output_parent"
	exit 2
fi
output_parent="${output_parent:A}"
output_path="$output_parent/${output_path:t}"

provenance_file="$app_path/Contents/Resources/BuildProvenance.json"
if [[ ! -f "$provenance_file" ]]; then
	print -u2 "Signed build provenance is missing from the app bundle"
	exit 1
fi
artifact_revision="$(build_provenance_value "$provenance_file" sourceRevision)"
artifact_state="$(build_provenance_value "$provenance_file" checkoutState)"
artifact_digest="$(build_provenance_value "$provenance_file" buildInputsDigest)"
current_revision="$(build_source_revision "$project_root")"
current_state="$(build_checkout_state "$project_root")"
current_digest="$(build_inputs_digest "$project_root")"
if [[ "$artifact_state" != "clean" || "$current_state" != "clean" ]]; then
	print -u2 "Desktop integration verification requires clean artifact and checkout inputs"
	exit 1
fi
if [[ "$artifact_digest" != "$current_digest" ]]; then
	print -u2 "Artifact build inputs do not match the current checkout"
	exit 1
fi
# A documentation-only commit can change HEAD without changing build inputs.
# Keep the artifact's real revision and report the input-equivalence check
# instead of relabelling the artifact as the newer commit.
if [[ "$artifact_revision" != "$current_revision" ]]; then
	print -u2 "Artifact revision $artifact_revision differs from HEAD $current_revision; build inputs are equivalent"
fi

report_root="$(mktemp -d "${TMPDIR:-/tmp}/memory-monitor-desktop.XXXXXX")"
trap 'if [[ -n "${report_root:-}" && -d "$report_root" ]]; then rm -rf -- "$report_root"; fi' EXIT
report_file="$report_root/report.json"
report_plist="$report_root/report.plist"

report_arguments=(--desktop-integration-json)
if (( include_audit_token )); then
	report_arguments+=(--audit-token-dedicated-child)
fi

print -u2 "Collecting desktop integration report from $app_path..."
report_status=0
env \
	MEMORY_MONITOR_ALLOW_AUDIT_TOKEN_TEST="${MEMORY_MONITOR_ALLOW_AUDIT_TOKEN_TEST:-0}" \
	"$app_binary" "${report_arguments[@]}" >"$report_file" || report_status=$?

# Install the raw output before parsing it. A crash, non-zero exit, or malformed
# JSON is still useful evidence and must remain available at the explicit path.
install -m 0600 "$report_file" "$output_path"
if (( report_status != 0 )); then
	print -u2 "Desktop integration command failed with status $report_status; report retained at $output_path"
	exit 1
fi

parse_failed=0
if ! plutil -convert xml1 -o "$report_plist" -- "$report_file"; then
	parse_failed=1
fi

if (( ! parse_failed )); then
	if ! schema_version="$(plutil -extract schemaVersion raw -o - "$report_plist")" || \
		! reported_version="$(plutil -extract product.version raw -o - "$report_plist")" || \
		! reported_build="$(plutil -extract product.build raw -o - "$report_plist")" || \
		! reported_revision="$(plutil -extract product.sourceRevision raw -o - "$report_plist")" || \
		! reported_digest="$(plutil -extract product.buildInputsDigest raw -o - "$report_plist")" || \
		! reported_source="$(plutil -extract product.provenanceSource raw -o - "$report_plist")" || \
		! reported_architecture="$(plutil -extract platform.architecture raw -o - "$report_plist")" || \
		! process_quality="$(plutil -extract processes.quality raw -o - "$report_plist")" || \
		! process_usable="$(plutil -extract processes.usable raw -o - "$report_plist")" || \
		! process_scan="$(plutil -extract processes.samplingPerformed raw -o - "$report_plist")" || \
		! sampled_count="$(plutil -extract processes.sampledCount raw -o - "$report_plist")" || \
		! listed_count="$(plutil -extract processes.listedCount raw -o - "$report_plist")" || \
		! coverage_fraction="$(plutil -extract processes.coverageFraction raw -o - "$report_plist")" || \
		! audit_result="$(plutil -extract auditToken.result raw -o - "$report_plist")" || \
		! audit_target="$(plutil -extract auditToken.target raw -o - "$report_plist")" || \
		! audit_signal="$(plutil -extract auditToken.signal raw -o - "$report_plist")" || \
		! login_state="$(plutil -extract loginItem.state raw -o - "$report_plist")" || \
		! limitation_count="$(plutil -extract limitations raw -o - "$report_plist")"; then
		parse_failed=1
	fi
fi
if (( parse_failed )); then
	print -u2 "Desktop integration report is missing required fields or is not valid JSON; report retained at $output_path"
	exit 1
fi

login_state_valid=1

if [[ "$schema_version" != "1" || \
	"$reported_version" != "$bundle_version" || \
	"$reported_build" != "$bundle_build" || \
	"$reported_revision" != "$artifact_revision" || \
	"$reported_digest" != "$artifact_digest" || \
	"$reported_source" != "bundle" || \
	"$reported_architecture" != "arm64" || \
	("$process_quality" != "available" && "$process_quality" != "estimated") || \
	"$process_usable" != "true" || \
	"$process_scan" != "true" || \
	"$sampled_count" != <-> || \
	"$listed_count" != <-> || \
	"$coverage_fraction" == "" || \
	"$audit_target" != "dedicated_child" || \
	"$audit_signal" != "SIGKILL" ]]; then
	print -u2 "Desktop integration report failed structural validation"
	exit 1
fi

if (( sampled_count <= 0 || listed_count < sampled_count )); then
	print -u2 "Desktop integration report has invalid process counts: $sampled_count/$listed_count"
	exit 1
fi
if ! awk -v sampled="$sampled_count" -v listed="$listed_count" \
	-v coverage="$coverage_fraction" \
	'BEGIN {
		if (coverage !~ /^[0-9]+(\.[0-9]+)?$/ || coverage < 0 || coverage > 1) exit 1
		expected = sampled / listed
		delta = coverage - expected
		if (delta < 0) delta = -delta
		exit !(delta <= 0.00001)
	}'; then
	print -u2 "Desktop integration report has invalid process coverage: $coverage_fraction"
	exit 1
fi

expected_limitations=(
	login_item_state_only
	login_after_restart_not_run
	system_permissions_not_changed
)
if (( include_audit_token == 0 )); then
	expected_limitations+=(audit_token_signal_not_run)
fi
if [[ "$limitation_count" != "${#expected_limitations[@]}" ]]; then
	print -u2 "Desktop integration report has unexpected limitation count: $limitation_count"
	exit 1
fi
for (( index = 1; index <= ${#expected_limitations[@]}; index++ )); do
	limitation_value="$(plutil -extract "limitations.$((index - 1))" raw -o - "$report_plist")"
	if [[ "$limitation_value" != "${expected_limitations[index]}" ]]; then
		print -u2 "Desktop integration report has unexpected limitation at index $((index - 1))"
		exit 1
	fi
done
case "$login_state" in
	not_registered|enabled|requires_approval) ;;
	not_found)
		login_state_valid=0
		print -u2 "Login-item service was not found for this signed app bundle"
		;;
	unavailable|failed)
		login_state_valid=0
		print -u2 "Login-item status could not be validated: $login_state"
		;;
	*)
		print -u2 "Unexpected login-item state: $login_state"
		exit 1
		;;
esac

validation_failed=0
if (( ! login_state_valid )); then
	validation_failed=1
fi
if (( include_audit_token )); then
	if [[ "$audit_result" != "passed" ]]; then
		print -u2 "Audit-token dedicated-child check did not pass: $audit_result"
		validation_failed=1
	fi
else
	if [[ "$audit_result" != "not_run" ]]; then
		print -u2 "Read-only desktop report unexpectedly ran the audit-token check"
		validation_failed=1
	fi
fi

if (( validation_failed )); then
	print -u2 "Desktop integration verification failed; report retained at $output_path"
	exit 1
fi

print "Desktop integration verification passed"
print "Report: $output_path"
print "Login item: $login_state"
print "Audit token: $audit_result"
