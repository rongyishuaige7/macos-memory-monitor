#!/bin/zsh
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"
umask 077
if (( $# > 1 )); then
	print -u2 "Usage: $0 [new-absolute-log-directory]"
	exit 2
fi
console_uid="$(stat -f '%u' /dev/console)"
current_uid="$(id -u)"
if [[ "$console_uid" != "$current_uid" ]] || ! launchctl print "gui/$current_uid" >/dev/null 2>&1; then
	print -u2 "Native tests require this user's active macOS desktop session"
	exit 2
fi
if (( $# )); then
	native_output="$1"
	if [[ "$native_output" != /* || -e "$native_output" || -L "$native_output" ]]; then
		print -u2 "Log directory must be a new absolute path: $native_output"
		exit 2
	fi
	mkdir -m 0700 -- "$native_output"
else
	native_output="$(mktemp -d "${TMPDIR:-/tmp}/memory-monitor-native-tests.XXXXXX")"
	chmod 0700 "$native_output"
fi
native_output="${native_output:A}"
git -C "$project_root" rev-parse HEAD > "$native_output/source-revision.txt"
git -C "$project_root" status --porcelain > "$native_output/checkout-state.txt"
sw_vers > "$native_output/platform.txt"
scratch_args=()
if [[ -n "${SWIFT_SCRATCH_PATH:-}" ]]; then scratch_args=(--scratch-path "$SWIFT_SCRATCH_PATH"); fi
test_flags=()
if [[ -n "${SWIFT_TEST_FLAGS:-}" ]]; then test_flags=(${=SWIFT_TEST_FLAGS}); fi
suites=(CleanupMotionTests DesktopMotionTests DesktopWindowTests SmartCleanupNativeTests DesktopScrollTests)
expected_counts=(2 1 3 1 1)
for (( index = 1; index <= ${#suites[@]}; index++ )); do
	suite="$suites[$index]"
	log="$native_output/$suite.log"
	print "Running native suite in its own process: $suite"
	if ! swift test "${test_flags[@]}" --package-path "$project_root" "${scratch_args[@]}" --filter "$suite" > "$log" 2>&1; then
		tail -n 40 "$log" >&2
		print -u2 "Native validation failed; logs retained at $native_output"
		exit 1
	fi
	if ! grep -Eq "Executed $expected_counts[$index] tests?, with 0 failures" "$log"; then
		print -u2 "Native suite did not execute the expected cases; see $log"
		exit 1
	fi
done
native_total=0
for expected_count in "${expected_counts[@]}"; do
	native_total=$(( native_total + expected_count ))
done
print "Native validation passed: $native_total tests across ${#suites[@]} isolated suites"
print "Logs: $native_output"
