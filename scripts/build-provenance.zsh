#!/bin/zsh
# Shared build-source helpers. Sourced by build-app.sh and verification tools.
# The digest covers ordered relative paths and file bytes only: no usernames,
# absolute checkout paths, environment variables, timestamps, or credentials.

build_source_revision() {
	local root="$1"
	git -C "$root" rev-parse HEAD
}

build_checkout_state() {
	local root="$1"
	if ! git -C "$root" diff --quiet -- || \
		! git -C "$root" diff --cached --quiet -- || \
		[[ -n "$(git -C "$root" ls-files --others --exclude-standard -- Package.swift Resources Sources scripts)" ]]; then
		print "modified"
	else
		print "clean"
	fi
}

build_inputs_digest() {
	local root="$1"
	reject_symlink_inputs "$root" Package.swift Sources Resources \
		scripts/build-app.sh scripts/bundle-replacement.zsh scripts/build-provenance.zsh || return 1
	local manifest
	manifest="$(mktemp "${TMPDIR:-/tmp}/memory-monitor-build-inputs.XXXXXX")"
	trap 'rm -f -- "${manifest:-}"' EXIT

	local -a files
	files=(Package.swift)
	[[ -f "$root/scripts/build-app.sh" ]] && files+=("scripts/build-app.sh")
	[[ -f "$root/scripts/bundle-replacement.zsh" ]] && files+=("scripts/bundle-replacement.zsh")
	[[ -f "$root/scripts/build-provenance.zsh" ]] && files+=("scripts/build-provenance.zsh")
	[[ -f "$root/Package.resolved" ]] && files+=("Package.resolved")

	local relative_path
	while IFS= read -r relative_path; do
		case "$relative_path" in
			*.DS_Store|*/.DS_Store|*/BuildProvenance.json) continue ;;
		esac
		files+=("$relative_path")
	done < <(find "$root/Sources" "$root/Resources" -type f -print 2>/dev/null |
		sed "s#^$root/##" | LC_ALL=C sort)

	for relative_path in "${files[@]}"; do
		[[ -f "$root/$relative_path" ]] || continue
		printf '%s\0' "$relative_path" >> "$manifest"
		shasum -a 256 "$root/$relative_path" | awk '{print $1}' >> "$manifest"
	done

	shasum -a 256 "$manifest" | awk '{print $1}'
	rm -f -- "$manifest"
	trap - EXIT
}

write_build_provenance() {
	local root="$1"
	local output="$2"
	local app_version="$3"
	local build_number="$4"
	local architecture="$5"
	local toolchain="$6"
	local revision="$7"
	local checkout_state="$8"
	local digest="$9"

	python3 - "$output" "$revision" "$checkout_state" "$digest" \
		"$app_version" "$build_number" "$architecture" "$toolchain" <<'PY'
import json
import sys

output, revision, state, digest, version, build, architecture, toolchain = sys.argv[1:]
payload = {
    "schemaVersion": 1,
    "sourceRevision": revision,
    "checkoutState": state,
    "buildInputsDigest": digest,
    "productVersion": version,
    "productBuild": build,
    "architecture": architecture,
    "toolchainVersion": toolchain,
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
	chmod 0644 "$output"
}

build_provenance_value() {
	local file="$1"
	local key="$2"
	python3 - "$file" "$key" <<'PY'
import json
import sys

path, key = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    value = json.load(handle)[key]
print(value)
PY
}

# Digest used by release/verification gates. It includes build inputs plus the
# tests, scripts and workflow definitions that determine what was executed.
verification_inputs_digest() {
	local root="$1"
	reject_symlink_inputs "$root" Package.swift Tests scripts .github/workflows Sources Resources || return 1
	local manifest
	manifest="$(mktemp "${TMPDIR:-/tmp}/memory-monitor-verification-inputs.XXXXXX")"
	trap 'rm -f -- "${manifest:-}"' EXIT

	local -a files
	files=(Package.swift)
	local relative_path
	while IFS= read -r relative_path; do
		case "$relative_path" in
			*.DS_Store|*/.DS_Store|*/BuildProvenance.json) continue ;;
		esac
		files+=("$relative_path")
	done < <(find "$root/Tests" "$root/scripts" "$root/.github/workflows" \
		"$root/Sources" "$root/Resources" -type f -print 2>/dev/null |
		sed "s#^$root/##" | LC_ALL=C sort)

	for relative_path in "${files[@]}"; do
		[[ -f "$root/$relative_path" ]] || continue
		printf '%s\0' "$relative_path" >> "$manifest"
		shasum -a 256 "$root/$relative_path" | awk '{print $1}' >> "$manifest"
	done

	shasum -a 256 "$manifest" | awk '{print $1}'
	rm -f -- "$manifest"
	trap - EXIT
}

# SwiftPM follows symlinked source files, while a digest built from `find -type
# f` would omit them. Refuse these inputs rather than publishing a digest that
# does not cover what the compiler actually reads.
reject_symlink_inputs() {
	local root="$1"
	shift
	local candidate symlink_path
	for candidate in "$@"; do
		[[ -e "$root/$candidate" || -L "$root/$candidate" ]] || continue
		if [[ -L "$root/$candidate" ]]; then
			print -u2 "Refusing symlinked build input: $candidate"
			return 1
		fi
		symlink_path="$(find "$root/$candidate" -type l -print -quit 2>/dev/null)"
		if [[ -n "$symlink_path" ]]; then
			print -u2 "Refusing symlinked build input: ${symlink_path#$root/}"
			return 1
		fi
	done
	return 0
}
