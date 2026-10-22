#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"
source "$script_dir/build-provenance.zsh"

configuration="${CONFIGURATION:-release}"
output_was_explicit=0
if [[ -n "${OUTPUT_DIR+x}" ]]; then
	output_root="$OUTPUT_DIR"
	output_was_explicit=1
else
	# Desktop is an iCloud File Provider location on many Macs. Keep the
	# default bundle on the local APFS volume so Finder metadata cannot break
	# the signature after the build completes.
	output_root="$HOME/Library/Application Support/MemoryMonitor/dist"
fi
binary_name="memory-monitor-app"
app_name="MemoryMonitor.app"
info_plist="$project_root/Resources/Info.plist"
app_icon="$project_root/Resources/MemoryMonitor.icns"

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
	print -u2 "CONFIGURATION must be debug or release"
	exit 2
fi

if [[ "$(uname -m)" != "arm64" ]]; then
	print -u2 "MemoryMonitor.app is limited to Apple Silicon (arm64)"
	exit 2
fi

system_major="$(sw_vers -productVersion | awk -F. '{print $1}')"
if (( system_major < 14 )); then
	print -u2 "MemoryMonitor.app requires macOS 14 or newer"
	exit 2
fi

for command_name in swift plutil file install codesign xattr ditto mktemp shasum python3; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		print -u2 "Required command not found: $command_name"
		exit 2
	fi
done

plutil -lint "$info_plist" >/dev/null
if [[ ! -s "$app_icon" ]]; then
	print -u2 "App icon not found: $app_icon"
	exit 2
fi

# Keep the bundle's default version in one source of truth. Release tooling
# can still override either value explicitly without modifying the source plist.
if ! default_app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist" 2>/dev/null)" ||
	! default_build_number="$(plutil -extract CFBundleVersion raw -o - "$info_plist" 2>/dev/null)" ||
	[[ -z "$default_app_version" || -z "$default_build_number" ]]; then
	print -u2 "Info.plist is missing a bundle version"
	exit 2
fi
app_version="${APP_VERSION:-$default_app_version}"
build_number="${BUILD_NUMBER:-$default_build_number}"
signing_identity="${CODE_SIGN_IDENTITY:--}"
skip_signing="${SKIP_SIGNING:-0}"

if [[ -z "$output_root" ]]; then
	print -u2 "Refusing to use an empty OUTPUT_DIR"
	exit 2
fi
if [[ "$output_root" != /* ]]; then
	output_root="$project_root/$output_root"
fi

# `${path:A}` resolves dot segments and every existing symlink component while
# preserving a useful path for directories that have not been created yet.
# Always compare canonical paths: a textual prefix check would let `.`/`..`,
# trailing slashes, or a symlink point the destructive replacement into the
# source tree.
canonical_project_root="${project_root:A}"
canonical_output_root="${output_root:A}"
if [[ -z "$canonical_output_root" || "$canonical_output_root" == "/" || \
	"$canonical_output_root" == "$canonical_project_root" || \
	"$canonical_output_root" == "$canonical_project_root"/* ]]; then
	print -u2 "Refusing to use an unsafe OUTPUT_DIR: $output_root"
	exit 2
fi
output_root="$canonical_output_root"

# Walk every ancestor because OUTPUT_DIR itself may not exist yet. iCloud
# Drive and other File Provider locations expose a domain attribute on one of
# these ancestors, often several levels above the output directory.
file_provider_ancestor=""
probe_path="$output_root"
while :; do
	if [[ -e "$probe_path" ]] && {
		xattr -p com.apple.file-provider-domain-id "$probe_path" >/dev/null 2>&1 || \
		xattr -p 'com.apple.fileprovider.detached#B' "$probe_path" >/dev/null 2>&1
	}; then
		file_provider_ancestor="$probe_path"
		break
	fi
	[[ "$probe_path" == "/" ]] && break
	next_probe_path="$(dirname -- "$probe_path")"
	[[ "$next_probe_path" == "$probe_path" ]] && break
	probe_path="$next_probe_path"
done
if [[ -n "$file_provider_ancestor" ]]; then
	if (( output_was_explicit )); then
		print -u2 "OUTPUT_DIR is inside an iCloud/File Provider location: $output_root"
	else
		print -u2 "Default output location unexpectedly uses a File Provider: $output_root"
	fi
	print -u2 "Choose a local APFS directory, for example:"
	print -u2 "  OUTPUT_DIR=\"$HOME/Library/Application Support/MemoryMonitor/dist\" ./scripts/build-app.sh"
	exit 2
fi

source_revision="$(build_source_revision "$project_root")"
checkout_state="$(build_checkout_state "$project_root")"
if ! build_digest_before="$(build_inputs_digest "$project_root")"; then
	exit 1
fi
toolchain_version="$(swift --version 2>/dev/null | head -n 1 | tr -d '\n')"
[[ -n "$toolchain_version" ]] || toolchain_version="unknown"

build_flags=()
if [[ -n "${SWIFT_BUILD_FLAGS:-}" ]]; then
	build_flags=(${=SWIFT_BUILD_FLAGS})
fi

swift build \
	"${build_flags[@]}" \
	--package-path "$project_root" \
	--configuration "$configuration" \
	--product "$binary_name"

binary_dir="$(swift build \
	"${build_flags[@]}" \
	--package-path "$project_root" \
	--configuration "$configuration" \
	--show-bin-path)"
source_binary="$binary_dir/$binary_name"
if [[ ! -x "$source_binary" ]]; then
	print -u2 "Built executable not found: $source_binary"
	exit 1
fi

binary_description="$(file -b "$source_binary")"
if [[ "$binary_description" != *arm64* ]]; then
	print -u2 "Built executable is not arm64: $binary_description"
	exit 1
fi

if ! build_digest_after="$(build_inputs_digest "$project_root")"; then
	exit 1
fi
if [[ "$build_digest_before" != "$build_digest_after" ]]; then
	print -u2 "Build inputs changed during the build; refusing to label the artifact"
	exit 1
fi

mkdir -p "$output_root"
# `mkdir -p` can follow a symlink created between the initial check and this
# point. Resolve once more and stop if the destination changed underneath us.
canonical_output_after_mkdir="${output_root:A}"
if [[ -z "$canonical_output_after_mkdir" || \
	"$canonical_output_after_mkdir" != "$output_root" || \
	"$canonical_output_after_mkdir" == "$canonical_project_root" || \
	"$canonical_output_after_mkdir" == "$canonical_project_root"/* ]]; then
	print -u2 "OUTPUT_DIR changed or resolves into the project: $output_root"
	exit 2
fi
app_path="$output_root/$app_name"
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/memory-monitor-app.XXXXXX")"
trap 'if [[ -n "${staging_root:-}" && -d "$staging_root" ]]; then rm -rf -- "$staging_root"; fi' EXIT
staged_app_path="$staging_root/$app_name"

mkdir -p "$staged_app_path/Contents/MacOS" "$staged_app_path/Contents/Resources"
install -m 0755 "$source_binary" "$staged_app_path/Contents/MacOS/$binary_name"
install -m 0644 "$info_plist" "$staged_app_path/Contents/Info.plist"
install -m 0644 "$app_icon" "$staged_app_path/Contents/Resources/MemoryMonitor.icns"

plutil -replace CFBundleShortVersionString -string "$app_version" "$staged_app_path/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$staged_app_path/Contents/Info.plist"
plutil -lint "$staged_app_path/Contents/Info.plist" >/dev/null

# Embed provenance before codesigning so the manifest is covered by the
# signature. The app must never infer its source from the invoking shell.
write_build_provenance \
	"$project_root" \
	"$staged_app_path/Contents/Resources/BuildProvenance.json" \
	"$app_version" \
	"$build_number" \
	"arm64" \
	"$toolchain_version" \
	"$source_revision" \
	"$checkout_state" \
	"$build_digest_before"

# Clear inherited metadata before signing. The staging directory is outside
# Desktop/File Provider storage, so it remains stable for final verification.
xattr -rc "$staged_app_path"

if [[ "$skip_signing" != "1" ]]; then
	codesign --force --deep --sign "$signing_identity" "$staged_app_path"
fi

# These attributes are not part of the executable and make strict signing
# verification fail when present.
xattr -r -d com.apple.FinderInfo "$staged_app_path" 2>/dev/null || true
xattr -r -d com.apple.ResourceFork "$staged_app_path" 2>/dev/null || true

if [[ "$skip_signing" != "1" ]]; then
	codesign --verify --deep --strict "$staged_app_path"
fi

verify_replacement_bundle() {
	local bundle="$1"
	xattr -r -d com.apple.FinderInfo "$bundle" 2>/dev/null || true
	xattr -r -d com.apple.ResourceFork "$bundle" 2>/dev/null || true
	[[ -x "$bundle/Contents/MacOS/$binary_name" ]] || return 1
	plutil -lint "$bundle/Contents/Info.plist" >/dev/null || return 1
	if [[ "$skip_signing" != "1" ]]; then
		codesign --verify --deep --strict "$bundle" || return 1
	fi
}
source "$script_dir/bundle-replacement.zsh"
replace_app_bundle "$staged_app_path" "$app_path"

print "Built $app_path"
print "Configuration: $configuration"
print "Architecture: arm64"
print "Source revision: $source_revision ($checkout_state)"
print "Build inputs digest: $build_digest_before"
if [[ "$skip_signing" == "1" ]]; then
	print "Signature: skipped"
else
	print "Signature: $signing_identity"
fi
