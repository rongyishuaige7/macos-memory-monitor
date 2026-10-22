#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"
source "$script_dir/build-provenance.zsh"
info_plist="$project_root/Resources/Info.plist"

for command_name in cat env git mktemp plutil swift shasum python3; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		print -u2 "Required command not found: $command_name"
		exit 2
	fi
done

plutil -lint "$info_plist" >/dev/null
product_version="$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
build_number="$(plutil -extract CFBundleVersion raw -o - "$info_plist")"
source_revision="$(git -C "$project_root" rev-parse HEAD)"
build_digest="$(build_inputs_digest "$project_root")"

checkout_state="clean"
if ! git -C "$project_root" diff --quiet -- || \
	! git -C "$project_root" diff --cached --quiet -- || \
	[[ -n "$(git -C "$project_root" ls-files --others --exclude-standard -- Package.swift Resources Sources scripts)" ]]; then
	checkout_state="modified"
fi

report_root="$(mktemp -d "${TMPDIR:-/tmp}/memory-monitor-compatibility.XXXXXX")"
trap 'if [[ -n "${report_root:-}" && -d "$report_root" ]]; then rm -rf -- "$report_root"; fi' EXIT
report_file="$report_root/report.json"
report_plist="$report_root/report.plist"

print -u2 "Collecting compatibility report for Memory Monitor $product_version (build $build_number)..."
env \
	MEMORY_MONITOR_PRODUCT_VERSION="$product_version" \
	MEMORY_MONITOR_BUILD_NUMBER="$build_number" \
	MEMORY_MONITOR_SOURCE_REVISION="$source_revision" \
	MEMORY_MONITOR_CHECKOUT_STATE="$checkout_state" \
	MEMORY_MONITOR_BUILD_INPUTS_DIGEST="$build_digest" \
	swift run \
		--package-path "$project_root" \
		--configuration release \
		memory-monitor-probe \
		--compatibility-json >"$report_file"
plutil -convert xml1 -o "$report_plist" -- "$report_file"
schema_version="$(plutil -extract schemaVersion raw -o - "$report_plist")"
reported_version="$(plutil -extract product.version raw -o - "$report_plist")"
reported_build="$(plutil -extract product.build raw -o - "$report_plist")"
reported_revision="$(plutil -extract product.sourceRevision raw -o - "$report_plist")"
reported_digest="$(plutil -extract product.buildInputsDigest raw -o - "$report_plist")"
reported_source="$(plutil -extract product.provenanceSource raw -o - "$report_plist")"

if [[ "$schema_version" != "1" ]]; then
	print -u2 "Unexpected compatibility report schema: $schema_version"
	exit 1
fi
if [[ "$reported_version" != "$product_version" || "$reported_build" != "$build_number" ]]; then
	print -u2 "Compatibility report product metadata does not match Info.plist"
	exit 1
fi
if [[ "$reported_revision" != "$source_revision" ]]; then
	print -u2 "Compatibility report source revision does not match the checkout"
	exit 1
fi
if [[ "$reported_digest" != "$build_digest" || "$reported_source" != "invocation" ]]; then
	print -u2 "Compatibility report invocation context is not bound to the current inputs"
	exit 1
fi

cat "$report_file"
