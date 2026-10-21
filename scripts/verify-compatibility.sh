#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"

if (( $# != 1 )); then
	print -u2 "Usage: EXPECTED_MACOS_MAJOR=<major> EXPECTED_ARCHITECTURE=<architecture> $0 <report-path>"
	exit 2
fi

expected_os_major="${EXPECTED_MACOS_MAJOR:-}"
expected_architecture="${EXPECTED_ARCHITECTURE:-}"
if [[ -z "$expected_os_major" || "$expected_os_major" != <-> ]]; then
	print -u2 "EXPECTED_MACOS_MAJOR must be a non-negative integer"
	exit 2
fi
if [[ -z "$expected_architecture" ]]; then
	print -u2 "EXPECTED_ARCHITECTURE must not be empty"
	exit 2
fi

report_path="$1"
if [[ -z "$report_path" ]]; then
	print -u2 "Report path must not be empty"
	exit 2
fi
if [[ "$report_path" != /* ]]; then
	report_path="$project_root/$report_path"
fi
report_path="${report_path:A}"
report_parent="${report_path:h}"
if [[ ! -d "$report_parent" ]]; then
	print -u2 "Report directory does not exist: $report_parent"
	exit 2
fi
if [[ -e "$report_path" || -L "$report_path" ]]; then
	print -u2 "Refusing to overwrite compatibility report: $report_path"
	exit 2
fi

for command_name in git grep install mktemp plutil swift; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		print -u2 "Required command not found: $command_name"
		exit 2
	fi
done

git -C "$project_root" diff --check
git -C "$project_root" diff --cached --check

print "Running Swift tests..."
test_skip_args=()
if [[ -n "${SWIFT_TEST_SKIP:-}" ]]; then
	# Hosted runners have no foreground desktop/LaunchServices session. Keep
	# the pure logic gate deterministic and run native GUI tests on a real
	# desktop runner instead of treating environment limitations as failures.
	test_skip_args=(--skip "$SWIFT_TEST_SKIP")
	print "Skipping native GUI tests: $SWIFT_TEST_SKIP"
fi
swift test \
	--package-path "$project_root" \
	--parallel \
	"${test_skip_args[@]}"

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

verification_root="$(mktemp -d "${TMPDIR:-/tmp}/memory-monitor-compatibility-gate.XXXXXX")"
trap 'if [[ -n "${verification_root:-}" && -d "$verification_root" ]]; then rm -rf -- "$verification_root"; fi' EXIT

probe_log="$verification_root/probe.log"
print "Running Release probe..."
swift run \
	--package-path "$project_root" \
	--configuration release \
	memory-monitor-probe >"$probe_log"
grep -q '^Memory Monitor Probe$' "$probe_log"
grep -q '^Processes:[[:space:]]' "$probe_log"

temporary_report="$verification_root/compatibility.json"
report_plist="$verification_root/compatibility.plist"
print "Collecting structured compatibility report..."
"$project_root/scripts/collect-compatibility-report.sh" >"$temporary_report"

# Preserve a report that passed the collector's schema and source checks even
# if a later environment or sampling assertion fails in CI.
install -m 0600 "$temporary_report" "$report_path"
plutil -convert xml1 -o "$report_plist" -- "$report_path"

schema_version="$(plutil -extract schemaVersion raw -o - "$report_plist")"
actual_os_major="$(plutil -extract platform.osMajor raw -o - "$report_plist")"
actual_architecture="$(plutil -extract platform.architecture raw -o - "$report_plist")"
checkout_state="$(plutil -extract product.checkoutState raw -o - "$report_plist")"
system_usable="$(plutil -extract sampling.system.usable raw -o - "$report_plist")"
process_scan="$(plutil -extract sampling.processes.samplingPerformed raw -o - "$report_plist")"
limitations_count="$(plutil -extract limitations raw -o - "$report_plist")"
login_item_limitation="$(plutil -extract limitations.0 raw -o - "$report_plist")"
audit_token_limitation="$(plutil -extract limitations.1 raw -o - "$report_plist")"
permissions_limitation="$(plutil -extract limitations.2 raw -o - "$report_plist")"

if [[ "$schema_version" != "1" || "$checkout_state" != "clean" ]]; then
	print -u2 "Compatibility report schema or checkout state is invalid"
	exit 1
fi
if [[ "$actual_os_major" != "$expected_os_major" ]]; then
	print -u2 "Expected macOS $expected_os_major but report observed macOS $actual_os_major"
	exit 1
fi
if [[ "$actual_architecture" != "$expected_architecture" ]]; then
	print -u2 "Expected $expected_architecture but report observed $actual_architecture"
	exit 1
fi
if [[ "$system_usable" != "true" || "$process_scan" != "true" ]]; then
	print -u2 "Compatibility report did not contain usable system data and a completed process scan"
	exit 1
fi
if [[ "$limitations_count" != "3" || \
	"$login_item_limitation" != "login_item_registration_not_run" || \
	"$audit_token_limitation" != "audit_token_signal_not_run" || \
	"$permissions_limitation" != "system_permissions_not_changed" ]]; then
	print -u2 "Compatibility report limitations are incomplete or reordered"
	exit 1
fi

sampled_processes="$(plutil -extract sampling.processes.sampledCount raw -o - "$report_plist")"
listed_processes="$(plutil -extract sampling.processes.listedCount raw -o - "$report_plist")"
system_quality="$(plutil -extract sampling.system.quality raw -o - "$report_plist")"
cpu_quality="$(plutil -extract sampling.cpu.quality raw -o - "$report_plist")"
gpu_quality="$(plutil -extract sampling.gpu.quality raw -o - "$report_plist")"

print "Compatibility verification passed"
print "Platform: macOS $actual_os_major; architecture=$actual_architecture"
print "Sampling: system=$system_quality; cpu=$cpu_quality; gpu=$gpu_quality; processes=$sampled_processes/$listed_processes"
print "Report: $report_path"
