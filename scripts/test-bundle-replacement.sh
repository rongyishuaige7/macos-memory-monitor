#!/bin/zsh
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
source "$script_dir/bundle-replacement.zsh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/memory-monitor-bundle-test.XXXXXX")"
test_root="${test_root:A}"
trap 'rm -rf -- "$test_root"' EXIT

run_case() (
	local mode="$1" root="$test_root/$1"
	mkdir -p "$root/source" "$root/output/MemoryMonitor.app"
	print new > "$root/source/marker"
	print old > "$root/output/MemoryMonitor.app/marker"
	verify_replacement_bundle() {
		[[ -f "$1/marker" ]] || return 1
		[[ "$mode" != "verify-copy" ]] || return 1
		[[ "$mode" != "verify-installed" || "$1" != "$root/output/MemoryMonitor.app" ]] || return 1
	}
	ditto() {
		[[ "$mode" != "copy" ]] || return 1
		command ditto "$@"
	}
	mv() {
		if [[ "$mode" == "install" && "$2" == */candidate.app ]]; then return 1; fi
		command mv "$@" || return 1
		# Simulate interruption after moving the old app but before the caller
		# observes success. Recovery must use filesystem evidence.
		if [[ "$mode" == "after-backup" && "$3" == */previous.app ]]; then return 1; fi
	}
	if replace_app_bundle "$root/source" "$root/output/MemoryMonitor.app" > "$root/log" 2>&1; then
		[[ "$mode" == "success" ]] || { cat "$root/log"; return 1; }
		[[ "$(< "$root/output/MemoryMonitor.app/marker")" == new ]]
		local backups=("$root/output"/.*.replacement.*/previous.app/marker(N))
		(( ${#backups} == 1 ))
		[[ "$(< "$backups[1]")" == old ]]
	else
		[[ "$mode" != "success" ]] || { cat "$root/log"; return 1; }
		[[ "$(< "$root/output/MemoryMonitor.app/marker")" == old ]]
	fi
	[[ ! -e "$root/output/.MemoryMonitor.app.replacement-lock" ]]
	print "PASS bundle replacement: $mode"
)
for mode in success copy verify-copy install verify-installed after-backup; do
	run_case "$mode"
done

mkdir -p "$test_root/symlink/source" "$test_root/symlink/real"
ln -s "$test_root/symlink/real" "$test_root/symlink/MemoryMonitor.app"
if replace_app_bundle "$test_root/symlink/source" "$test_root/symlink/MemoryMonitor.app" > /dev/null 2>&1; then
	print -u2 "Symlink target must be rejected"
	exit 1
fi
[[ -L "$test_root/symlink/MemoryMonitor.app" ]]
print "PASS bundle replacement: symlink rejection"

mkdir -p "$test_root/locked/.MemoryMonitor.app.replacement-lock"
print retained > "$test_root/locked/.MemoryMonitor.app.replacement-lock/transaction-path"
if replace_app_bundle "$test_root/symlink/source" "$test_root/locked/MemoryMonitor.app" > /dev/null 2>&1; then
	exit 1
fi
[[ "$(< "$test_root/locked/.MemoryMonitor.app.replacement-lock/transaction-path")" == retained ]]
print "PASS bundle replacement: existing lock preserved"
