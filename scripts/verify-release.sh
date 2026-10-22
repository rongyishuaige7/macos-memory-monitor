#!/bin/zsh
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"
source "$script_dir/build-provenance.zsh"
info_plist="$project_root/Resources/Info.plist"

usage() {
	print -u2 "Usage: $0 [new-absolute-evidence-directory]"
}

if (( $# > 1 )); then
	usage
	exit 2
fi

for command_name in git plutil swift awk grep mktemp file codesign env python3 shasum find sed sort chmod; do
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

if (( $# == 1 )); then
	evidence_root="$1"
	if [[ "$evidence_root" != /* ]]; then
		print -u2 "Evidence directory must be an absolute path: $evidence_root"
		exit 2
	fi
	if [[ -e "$evidence_root" || -L "$evidence_root" ]]; then
		print -u2 "Refusing to overwrite an existing evidence directory: $evidence_root"
		exit 2
	fi
	case "$evidence_root" in
		"$project_root"|"$project_root"/*)
			print -u2 "Evidence directory must be outside the checkout: $evidence_root"
			exit 2
			;;
	esac
	mkdir -m 0700 -- "$evidence_root"
else
	evidence_root="$(mktemp -d "${TMPDIR:-/tmp}/memory-monitor-release.XXXXXX")"
	chmod 0700 "$evidence_root"
fi
evidence_root="${evidence_root:A}"
logs_dir="$evidence_root/logs"
mkdir -m 0700 -- "$logs_dir"
steps_file="$evidence_root/steps.tsv"
: > "$steps_file"
chmod 0600 "$steps_file"

started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
source_revision="$(build_source_revision "$project_root")"
checkout_state="$(build_checkout_state "$project_root")"
build_digest="$(build_inputs_digest "$project_root")"
verification_digest_before="$(verification_inputs_digest "$project_root")"
verification_digest_after=""
artifact_path="$evidence_root/dist/MemoryMonitor.app"
probe_log="$evidence_root/probe.log"
compatibility_report="$evidence_root/compatibility.json"
desktop_report="$evidence_root/desktop-report.json"
native_logs="$evidence_root/native-tests"
manifest_path="$evidence_root/manifest.json"

record_step() {
	local id="$1"
	local step_status="$2"
	local log="$3"
	local detail="$4"
	printf '%s\t%s\t%s\t%s\n' "$id" "$step_status" "$log" "$detail" >> "$steps_file"
}

run_step() {
	local id="$1"
	shift
	local log="$logs_dir/$id.log"
	print "== $id =="
	if "$@" >"$log" 2>&1; then
		record_step "$id" passed "${log#$evidence_root/}" ""
	else
		local code=$?
		record_step "$id" failed "${log#$evidence_root/}" "exit $code"
		print -u2 "Step failed: $id (exit $code)"
		tail -n 40 "$log" >&2 || true
		return "$code"
	fi
}

step_git_checks() {
	git -C "$project_root" diff --check
	git -C "$project_root" diff --cached --check
}

step_bundle_replacement() {
	zsh "$script_dir/test-bundle-replacement.sh"
}

step_non_gui_tests() {
	swift test "${test_flags[@]}" --package-path "$project_root" \
		--skip 'CleanupMotionTests|DesktopMotionTests|SmartCleanupNativeTests|DesktopWindowTests'
}

step_native_tests() {
	"$script_dir/verify-native-tests.sh" "$native_logs"
}

step_debug_build() {
	swift build "${build_flags[@]}" --package-path "$project_root" \
		--configuration debug -Xswiftc -strict-concurrency=complete
}

step_release_build() {
	swift build "${build_flags[@]}" --package-path "$project_root" \
		--configuration release -Xswiftc -strict-concurrency=complete
}

step_probe() {
	swift run "${build_flags[@]}" --package-path "$project_root" \
		--configuration release memory-monitor-probe >"$probe_log"
	grep -q '^Memory Monitor Probe$' "$probe_log"
	grep -q '^Processes:[[:space:]]' "$probe_log"
}

step_compatibility() {
	"$script_dir/collect-compatibility-report.sh" >"$compatibility_report"
	plutil -convert xml1 -o "$evidence_root/compatibility.plist" -- "$compatibility_report"
	local plist="$evidence_root/compatibility.plist"
	local schema architecture limitations process_scan
	schema="$(plutil -extract schemaVersion raw -o - "$plist")"
	architecture="$(plutil -extract platform.architecture raw -o - "$plist")"
	limitations="$(plutil -extract limitations raw -o - "$plist")"
	process_scan="$(plutil -extract sampling.processes.samplingPerformed raw -o - "$plist")"
	if [[ "$schema" != "1" || "$architecture" != "arm64" || \
		"$limitations" != "3" || "$process_scan" != "true" ]]; then
		return 1
	fi
}

step_build_app() {
	env -u APP_VERSION -u BUILD_NUMBER \
		OUTPUT_DIR="$evidence_root/dist" \
		"$script_dir/build-app.sh"
}

step_validate_app() {
	local app_plist="$artifact_path/Contents/Info.plist"
	local app_binary="$artifact_path/Contents/MacOS/memory-monitor-app"
	[[ -d "$artifact_path" && -f "$app_plist" && -x "$app_binary" ]]
	local bundle_version bundle_build
	bundle_version="$(plutil -extract CFBundleShortVersionString raw -o - "$app_plist")"
	bundle_build="$(plutil -extract CFBundleVersion raw -o - "$app_plist")"
	[[ "$bundle_version" == "$source_version" && "$bundle_build" == "$source_build" ]]
	[[ "$(file -b "$app_binary")" == *arm64* ]]
	codesign --verify --deep --strict "$artifact_path"

	local provenance_file="$artifact_path/Contents/Resources/BuildProvenance.json"
	[[ -f "$provenance_file" ]]
	local artifact_revision artifact_state artifact_digest artifact_version artifact_build expected_digest
	artifact_revision="$(build_provenance_value "$provenance_file" sourceRevision)"
	artifact_state="$(build_provenance_value "$provenance_file" checkoutState)"
	artifact_digest="$(build_provenance_value "$provenance_file" buildInputsDigest)"
	artifact_version="$(build_provenance_value "$provenance_file" productVersion)"
	artifact_build="$(build_provenance_value "$provenance_file" productBuild)"
	expected_digest="$(build_inputs_digest "$project_root")"
	[[ "$artifact_state" == "clean" && \
		"$artifact_version" == "$bundle_version" && \
		"$artifact_build" == "$bundle_build" && \
		"$artifact_digest" == "$expected_digest" ]]
}

step_desktop_report() {
	"$script_dir/verify-desktop-integration.sh" \
		--app "$artifact_path" \
		--output "$desktop_report"
}

build_flags=()
if [[ -n "${SWIFT_BUILD_FLAGS:-}" ]]; then
	build_flags=(${=SWIFT_BUILD_FLAGS})
fi
test_flags=()
if [[ -n "${SWIFT_TEST_FLAGS:-}" ]]; then
	test_flags=(${=SWIFT_TEST_FLAGS})
fi

write_manifest() {
	local gate_status="$1"
	local exit_code="$2"
	python3 - "$manifest_path" "$gate_status" "$exit_code" "$started_at" \
		"$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$evidence_root" \
		"$source_revision" "$checkout_state" "$build_digest" \
		"$verification_digest_before" "$verification_digest_after" \
		"$source_version" "$source_build" "$steps_file" \
		"$artifact_path" "$probe_log" "$compatibility_report" \
		"$desktop_report" "$native_logs" <<'PY'
import json
import os
import sys

(
    manifest_path,
    status,
    exit_code,
    started_at,
    finished_at,
    evidence_root,
    source_revision,
    checkout_state,
    build_digest,
    verification_before,
    verification_after,
    product_version,
    product_build,
    steps_file,
    artifact_path,
    probe_log,
    compatibility_report,
    desktop_report,
    native_logs,
) = sys.argv[1:]

steps = []
if os.path.exists(steps_file):
    with open(steps_file, encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) != 4:
                continue
            step_id, step_status, log, detail = fields
            steps.append({
                "id": step_id,
                "status": step_status,
                "log": log or None,
                "detail": detail or None,
            })

def rel(path):
    if not path:
        return None
    try:
        value = os.path.relpath(path, evidence_root)
    except ValueError:
        value = path
    return value if not value.startswith("..") else path

payload = {
    "schemaVersion": 1,
    "status": status,
    "exitCode": int(exit_code),
    "startedAt": started_at,
    "finishedAt": finished_at,
    "evidenceRoot": evidence_root,
    "sourceRevision": source_revision or None,
    "checkoutState": checkout_state or None,
    "buildInputsDigest": build_digest or None,
    "verificationInputsDigestBefore": verification_before or None,
    "verificationInputsDigestAfter": verification_after or None,
    "productVersion": product_version,
    "productBuild": product_build,
    "steps": steps,
    "artifacts": {
        "app": rel(artifact_path) if os.path.exists(artifact_path) else None,
        "probeLog": rel(probe_log) if os.path.exists(probe_log) else None,
        "compatibilityReport": rel(compatibility_report) if os.path.exists(compatibility_report) else None,
        "desktopReport": rel(desktop_report) if os.path.exists(desktop_report) else None,
        "nativeTestLogs": rel(native_logs) if os.path.isdir(native_logs) else None,
    },
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
os.chmod(manifest_path, 0o600)
PY
}

finalize() {
	local exit_code=$?
	trap - EXIT
	local gate_status="passed"
	if (( exit_code != 0 )); then
		gate_status="failed"
	fi
	if [[ -n "${evidence_root:-}" && -d "$evidence_root" ]]; then
		if [[ -z "${verification_digest_after:-}" ]]; then
			verification_digest_after="$(verification_inputs_digest "$project_root" 2>/dev/null || true)"
		fi
		write_manifest "$gate_status" "$exit_code" || true
		print -u2 "Evidence retained: $evidence_root"
	fi
	exit "$exit_code"
}
trap finalize EXIT

run_step git_checks step_git_checks
run_step bundle_replacement step_bundle_replacement
run_step non_gui_tests step_non_gui_tests
run_step native_tests step_native_tests
run_step debug_build step_debug_build
run_step release_build step_release_build
run_step probe step_probe
run_step compatibility_report step_compatibility
run_step build_app step_build_app
run_step validate_app step_validate_app
run_step desktop_report step_desktop_report

verification_digest_after="$(verification_inputs_digest "$project_root")"
if [[ "$verification_digest_after" != "$verification_digest_before" ]]; then
	record_step verification_inputs_stable failed "" "verification inputs changed during the gate"
	print -u2 "Verification inputs changed during the gate"
	exit 1
fi
record_step verification_inputs_stable passed "" ""

print "Release verification passed"
print "Version: $source_version (build $source_build)"
print "Evidence: $evidence_root"
print "Manifest: $manifest_path"
