# Sourced by build-app.sh. The caller supplies verify_replacement_bundle.
# Keep every rename on the destination volume and retain the previous bundle.
replace_app_bundle() (
	set -u
	local source_app="$1" target_app="$2"
	local parent_dir="${target_app:h}"
	local lock_dir="$parent_dir/.${target_app:t}.replacement-lock"
	local transaction_dir="" completed=0 install_started=0
	if [[ "$target_app" != /* || "${parent_dir:A}" != "$parent_dir" ||
	      -L "$target_app" || ( -e "$target_app" && ! -d "$target_app" ) ]]; then
		print -u2 "Refusing an unsafe app replacement target: $target_app"
		return 2
	fi
	if ! mkdir -- "$lock_dir"; then
		print -u2 "Another replacement or interrupted build owns $lock_dir; inspect it before retrying"
		return 1
	fi
	finish_bundle_replacement() {
		local result="$1"
		trap - EXIT INT TERM HUP
		if [[ -n "$transaction_dir" ]]; then
			if (( ! completed )); then
				if (( install_started )) && [[ -e "$target_app" || -L "$target_app" ]]; then
					mv -- "$target_app" "$transaction_dir/failed.app" || result=1
				fi
				if [[ -d "$transaction_dir/previous.app" && ! -e "$target_app" && ! -L "$target_app" ]]; then
					mv -- "$transaction_dir/previous.app" "$target_app" || result=1
				fi
			fi
			# Only the task-owned candidate is disposable. Previous/failed
			# bundles are retained even when recovery itself encounters an error.
			rm -rf -- "$transaction_dir/candidate.app"
			if ! rmdir -- "$transaction_dir" 2>/dev/null; then
				print -u2 "Retained replacement files: $transaction_dir"
			fi
		fi
		rm -f -- "$lock_dir/transaction-path"
		rmdir -- "$lock_dir" || result=1
		exit "$result"
	}
	trap 'finish_bundle_replacement $?' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	transaction_dir="$(mktemp -d "$parent_dir/.${target_app:t}.replacement.XXXXXX")" || return 1
	print -r -- "$transaction_dir" > "$lock_dir/transaction-path" || return 1
	# Drop the marker before lock removal; a SIGKILL leaves both for recovery.
	# The EXIT handler removes only this marker, never a previous app.
	ditto --norsrc "$source_app" "$transaction_dir/candidate.app" || return 1
	verify_replacement_bundle "$transaction_dir/candidate.app" || return 1
	[[ ! -L "$target_app" ]] || return 2
	if [[ -e "$target_app" ]]; then
		mv -- "$target_app" "$transaction_dir/previous.app" || return 1
	fi
	install_started=1
	mv -- "$transaction_dir/candidate.app" "$target_app" || return 1
	verify_replacement_bundle "$target_app" || return 1
	completed=1
	if [[ -d "$transaction_dir/previous.app" ]]; then
		print "Previous bundle: $transaction_dir/previous.app"
	fi
)
