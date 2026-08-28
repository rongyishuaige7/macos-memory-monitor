#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"

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
app_version="${APP_VERSION:-1.0.1}"
build_number="${BUILD_NUMBER:-11}"
signing_identity="${CODE_SIGN_IDENTITY:--}"
skip_signing="${SKIP_SIGNING:-0}"
binary_name="memory-monitor-app"
app_name="MemoryMonitor.app"
info_plist="$project_root/Resources/Info.plist"

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

for command_name in swift plutil file install codesign xattr ditto mktemp; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		print -u2 "Required command not found: $command_name"
		exit 2
	fi
done

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

plutil -lint "$info_plist" >/dev/null

swift build \
	--package-path "$project_root" \
	--configuration "$configuration" \
	--product "$binary_name"

binary_dir="$(swift build \
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

plutil -replace CFBundleShortVersionString -string "$app_version" "$staged_app_path/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$staged_app_path/Contents/Info.plist"
plutil -lint "$staged_app_path/Contents/Info.plist" >/dev/null

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

# Replace only the generated app path. The parent directory is user-selected,
# while the bundle itself is the artifact owned by this script. Never remove a
# symlink here: even though `rm` normally unlinks the link itself, rejecting it
# avoids a race or a surprising replacement of a user-managed alias.
if [[ -L "$app_path" ]]; then
	print -u2 "Refusing to replace a symlink at $app_path"
	exit 2
fi
if [[ -e "$app_path" ]]; then
	rm -rf -- "$app_path"
fi
ditto --norsrc "$staged_app_path" "$app_path"
xattr -r -d com.apple.FinderInfo "$app_path" 2>/dev/null || true
xattr -r -d com.apple.ResourceFork "$app_path" 2>/dev/null || true

if [[ "$skip_signing" != "1" ]]; then
	codesign --verify --deep --strict "$app_path"
fi

print "Built $app_path"
print "Configuration: $configuration"
print "Architecture: arm64"
if [[ "$skip_signing" == "1" ]]; then
	print "Signature: skipped"
else
	print "Signature: $signing_identity"
fi
