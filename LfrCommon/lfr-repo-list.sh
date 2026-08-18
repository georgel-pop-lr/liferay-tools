# lfr-repo-list.sh — shared repo discovery and picker for the Liferay tools.
#
# Loaded via the root lfrTools.sh. Owns the per-user repo config and the two
# helpers reused by lfrRepo, lfrWorktree, and lfrCache:
#     _lfrRepoEntries    list git repos under the configured roots (tab-separated),
#                        with --branch labelling each with its checked-out branch
#     _lfrRepoPick [q]    pick one via fzf or a numbered menu; echoes its path
#
# Per-user settings live in repos.local.conf next to this file (gitignored).
# Copy repos.local.conf.example to repos.local.conf and edit.

_lfrCommonDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "${_lfrCommonDir}/repos.local.conf" ] && . "${_lfrCommonDir}/repos.local.conf"

# Defaults if the local config did not set them.
[ -z "${LFR_REPO_ROOTS+x}" ] && LFR_REPO_ROOTS=("${HOME}/liferay/repos")
[ -z "${LFR_REPO_PRIORITY+x}" ] && LFR_REPO_PRIORITY=("liferay-portal")
LFR_WORKTREE_ROOT="${LFR_WORKTREE_ROOT:-${HOME}/liferay/repos}"
LFR_WORKTREE_BASE="${LFR_WORKTREE_BASE:-upstream/master}"

# Emit "<path>\t<name>  (<root>)" for every git repo under the configured roots,
# with LFR_REPO_PRIORITY prefixes sorted first (stable within each rank).
#
# With --branch the label also carries the checked-out branch (or the short sha
# when HEAD is detached), which is what tells two clones of the same repo apart
# and shows when a worktree is not on the branch its directory is named after.
# It costs a git call per repo, so callers that only need the names (the tab
# completion, the bundle-to-repo map) leave it off.
_lfrRepoEntries() {
	local root dir name rank i seq=0 branch label branches=0
	[ "${1-}" = --branch ] && branches=1
	{
		for root in "${LFR_REPO_ROOTS[@]}"; do
			[ -d "${root}" ] || continue
			for dir in "${root}"/*/; do
				[ -e "${dir}.git" ] || continue
				name="$(basename "${dir}")"
				rank=9999
				for i in "${!LFR_REPO_PRIORITY[@]}"; do
					if [ "${name#"${LFR_REPO_PRIORITY[$i]}"}" != "${name}" ]; then
						rank="${i}"
						break
					fi
				done
				label="${name}  (${root})"
				if [ "${branches}" = 1 ]; then
					branch="$(git -C "${dir%/}" symbolic-ref --short -q HEAD ||
						git -C "${dir%/}" rev-parse --short HEAD 2>/dev/null)"
					label="$(printf '%-36s @%-24s (%s)' "${name}" "${branch:-?}" "${root}")"
				fi
				printf '%d\t%d\t%s\t%s\n' "${rank}" "${seq}" "${dir%/}" "${label}"
				seq=$((seq + 1))
			done
		done
	} | sort -t$'\t' -k1,1n -k2,2n | cut -f3-
}

# Generic picker. Reads "value<TAB>label" lines from stdin, shows the labels in
# fzf (or a numbered menu), and echoes the chosen value. $1 is the prompt, $2 an
# optional query that prefilters and auto-selects on a single match, $3 an
# optional preview command (fzf only; it runs in a plain shell, so it can use
# {1} for the highlighted line's value but not our shell functions), $4 an
# optional toolbar of key hints drawn on the bottom border, $5 an optional value
# to start the cursor on instead of the first line, so a caller that reopens the
# picker in a loop keeps the entry you were on. The last three are fzf's; the
# numbered-menu fallback below ignores them, since it is answered with a number.
# Used by the repo picker below and by other tools (e.g. lfrShare's bundle picker).
_lfrPick() {
	local prompt="${1:-> }" query="${2:-}" preview="${3:-}" toolbar="${4:-}" start="${5:-}"
	local input selection line
	local -a fzfArgs=(
		# Right/Left alias Enter/Esc, so the whole picker can be driven with the
		# arrow keys: up and down to move, right to take the entry, left to leave.
		--bind='right:accept,left:abort'
		--delimiter=$'\t'
		--exit-0
		--height=40%
		--prompt="${prompt}"
		--query="${query}"
		--reverse
		--select-1
		--with-nth=2..
	)

	input="$(cat)"
	[ -z "${input}" ] && return 1

	[ -n "${preview}" ] && fzfArgs+=(--preview="${preview}" --preview-window='right,60%,wrap')
	[ -n "${toolbar}" ] &&
		fzfArgs+=(--border=sharp --border-label=" ${toolbar} " --border-label-pos=bottom)

	# pos() needs the whole list in, which is what --sync waits for; fzf reads its
	# input asynchronously otherwise and would move the cursor on a partial list.
	if [ -n "${start}" ]; then
		line="$(printf '%s\n' "${input}" | awk -F'\t' -v value="${start}" '$1 == value {print NR; exit}')"
		[ -n "${line}" ] && fzfArgs+=(--sync --bind="start:pos(${line})")
	fi

	if command -v fzf >/dev/null 2>&1; then
		selection="$(printf '%s\n' "${input}" | fzf "${fzfArgs[@]}")"
		[ -z "${selection}" ] && return 1
		printf '%s\n' "${selection%%$'\t'*}"
		return 0
	fi

	local values=() labels=() v l i
	while IFS=$'\t' read -r v l; do
		values+=("${v}")
		labels+=("${l}")
	done <<< "${input}"

	if [ -n "${query}" ]; then
		local matches=()
		for i in "${!labels[@]}"; do
			case "${labels[$i]}" in *"${query}"*) matches+=("${i}") ;; esac
		done
		if [ "${#matches[@]}" -eq 1 ]; then
			printf '%s\n' "${values[${matches[0]}]}"
			return 0
		fi
	fi

	echo "Select:" >&2
	local choice
	select choice in "${labels[@]}"; do
		[ -n "${choice}" ] || continue
		for i in "${!labels[@]}"; do
			[ "${labels[$i]}" = "${choice}" ] && { printf '%s\n' "${values[$i]}"; return 0; }
		done
	done
	return 1
}

# Pick a git repo (path) with the shared picker, labelling each with the branch
# it has checked out. Optional $1 prefilters.
#
# A query matching exactly one repo NAME takes that repo outright, so the branch
# now in the label cannot turn a name that used to resolve on its own into a
# picker over every repo that happens to sit on that branch (`lfrRepo master`
# means the masterBrian clone, not the twenty repos parked on master).
_lfrRepoPick() {
	local query="${1:-}" entries
	local -a matches=()
	entries="$(_lfrRepoEntries --branch)"
	if [ -z "${entries}" ]; then
		echo "lfr: no git repos found under: ${LFR_REPO_ROOTS[*]}" >&2
		return 1
	fi
	if [ -n "${query}" ]; then
		mapfile -t matches < <(printf '%s\n' "${entries}" |
			awk -F'\t' -v q="${query}" '{split($2, label, " "); if (index(label[1], q)) print $1}')
		if [ "${#matches[@]}" -eq 1 ]; then
			printf '%s\n' "${matches[0]}"
			return 0
		fi
	fi
	printf '%s\n' "${entries}" | _lfrPick 'repo> ' "${query}"
}
