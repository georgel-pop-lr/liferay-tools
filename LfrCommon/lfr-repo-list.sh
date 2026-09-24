# lfr-repo-list.sh - shared repo discovery and picker for the Liferay tools.
#
# Loaded via the root lfrTools.sh. Owns the per-user repo config and the two
# helpers reused by lfrRepos, lfrWorktree, and lfrCache:
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
# With --branch the label is the checked-out branch (or the short sha when HEAD
# is detached) followed by the repo's full path, which already ends in its name:
# the branch is what tells two clones of the same repo apart and shows when a
# worktree is not on the branch its directory is named after. The branch column
# is padded to its widest entry by _lfrPickAlign, like the bundle picker, and the
# two are coloured apart. It costs a git call per repo, so callers that only need
# the names (the tab completion, the bundle-to-repo map) leave it off.
_lfrRepoEntries() {
	local root dir name rank i seq=0 branch label branches=0 path
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
					label="${branch:-?}"$'\t'"${dir%/}"
				fi
				printf '%d\t%d\t%s\t%s\n' "${rank}" "${seq}" "${dir%/}" "${label}"
				seq=$((seq + 1))
			done
		done
	} | sort -t$'\t' -k1,1n -k2,2n | cut -f3- | {
		if [ "${branches}" = 1 ]; then
			while IFS=$'\t' read -r path branch dir; do
				printf '%s\t%s\t\t%s\n' "${path}" "${branch}" "$(_lfrPickPath "${LFR_PICK_COLOR_PATH}" "${dir}")"
			done | _lfrPickAlign
		else
			cat
		fi
	}
}

# Light colours for the picker labels, one per kind of text, so the parts of a
# line read apart at a glance. fzf renders them (--ansi, which also keeps them out
# of the match); the numbered-menu fallback strips them.
LFR_PICK_COLOR_BRANCH=$'\033[38;5;117m' # light blue: branch, or what a line is
LFR_PICK_COLOR_PATH=$'\033[38;5;229m'   # light yellow: the last folder of every path, sha
LFR_PICK_COLOR_STATE=$'\033[38;5;250m'  # light grey: stopped, off, counts, dates
LFR_PICK_COLOR_ON=$'\033[38;5;157m'     # light green: running, on, shared
LFR_PICK_COLOR_ARROW=$'\033[38;5;244m'  # grey: the < between a bundle and its repos
LFR_PICK_COLOR_SUBJECT=$'\033[38;5;218m'   # light pink: a commit subject
LFR_PICK_COLOR_ROOT=$'\033[38;5;250m'   # light grey: the first folder of a path, /media or /home, the disk it is on
LFR_PICK_COLOR_DIR=$'\033[38;5;245m'    # grey: the parent folders of a path, so its name stands out
LFR_PICK_COLOR_OFF=$'\033[0m'

# Colour the text in $2 with $1, except the parent folders of every absolute path
# in it: the first in light grey, since /media or /home says which disk it is on, the
# rest receding in grey so the last folder (liferay-portal-ee,
# liferay-bundle-master) is what the eye lands on. Paths end at a space, a comma
# or a parenthesis, which is how the repo labels join them.
_lfrPickPath() {
	printf '%s' "${2}" | sed -E \
		"s#(/[^/ ,()]+)(/([^/ ,()]+/)*)([^/ ,()]+)#${LFR_PICK_COLOR_ROOT}\\1${LFR_PICK_COLOR_DIR}\\2${1}\\4#g; s#^#${1}#; s#\$#${LFR_PICK_COLOR_OFF}#"
}

# Turn "value<TAB>branch<TAB>tag<TAB>rest" lines into the picker's
# "value<TAB>label": the branch in its colour, then the tag (already coloured,
# e.g. a RUNNING marker) right after it, the pair padded to the widest one so the
# rest lines up. The width is capped so one bundle with several checkouts does
# not push every other line off a narrow screen; the few wider entries just
# overflow the column. Padding is counted on the plain text, so the colour codes
# never skew it.
_lfrPickAlign() {
	awk -F'\t' -v branchColor="${LFR_PICK_COLOR_BRANCH}" -v off="${LFR_PICK_COLOR_OFF}" '
		function plain(s) { gsub(/\033\[[0-9;]*m/, "", s); return s }
		{
			value[NR] = $1; branch[NR] = $2; tag[NR] = $3; rest[NR] = $4
			n[NR] = length($2 plain($3))
			if (n[NR] > width && n[NR] <= 30) width = n[NR]
		}
		END {
			for (i = 1; i <= NR; i++) {
				pad = width - n[i]
				printf "%s\t%s%s%s%s%*s  %s\n", value[i], branchColor, branch[i], off, tag[i], (pad > 0 ? pad : 0), "", rest[i]
			}
		}'
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
# Set LFR_PICK_TOOLTIP=1 on the call to show the highlighted line's whole label,
# wrapped, in a strip under the list, since a long label is cut off at the right
# edge of a narrow terminal, in the same colours as the line. It only applies when
# there is no preview of its own.
# Used by the repo picker below and by other tools (e.g. lfrShare's bundle picker).
_lfrPick() {
	local prompt="${1:-> }" query="${2:-}" preview="${3:-}" toolbar="${4:-}" start="${5:-}"
	local input selection line tooltip=""
	local -a fzfArgs=(
		# Right/Left alias Enter/Esc, so the whole picker can be driven with the
		# arrow keys: up and down to move, right to take the entry, left to leave.
		--ansi
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

	if [ -n "${preview}" ]; then
		fzfArgs+=(--preview="${preview}" --preview-window='right,60%,wrap')
	elif [ "${LFR_PICK_TOOLTIP-}" = 1 ] && command -v fzf >/dev/null 2>&1; then
		# Only a label wider than the list (the terminal less fzf's 2-column pointer)
		# is cut off, so the strip stays blank for one that fits rather than say it twice.
		# With --ansi fzf hands the preview {2..} with its colours stripped, which is
		# right for measuring the width, so the coloured label is read back from a copy
		# of the input by {n}, the line's index in it (unchanged by the query).
		tooltip="$(mktemp)"
		printf '%s\n' "${input}" > "${tooltip}"
		fzfArgs+=(
			--preview="label={2..}; [ \${#label} -gt \$((FZF_PREVIEW_COLUMNS - 2)) ] && sed -n \"\$(({n} + 1))p\" $(printf '%q' "${tooltip}") | cut -f2-"
			--preview-window='down,3,wrap,border-top'
		)
	fi
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
		[ -n "${tooltip}" ] && rm -f "${tooltip}"
		[ -z "${selection}" ] && return 1
		printf '%s\n' "${selection%%$'\t'*}"
		return 0
	fi

	local values=() labels=() v l i
	while IFS=$'\t' read -r v l; do
		values+=("${v}")
		labels+=("${l}")
	done < <(printf '%s\n' "${input}" | sed 's/\x1b\[[0-9;]*m//g')

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
# picker over every repo that happens to sit on that branch (`lfrRepos master`
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
			awk -F'\t' -v q="${query}" '{name = $1; sub(/.*\//, "", name); if (index(name, q)) print $1}')
		if [ "${#matches[@]}" -eq 1 ]; then
			printf '%s\n' "${matches[0]}"
			return 0
		fi
	fi
	printf '%s\n' "${entries}" | LFR_PICK_TOOLTIP=1 _lfrPick 'repo> ' "${query}"
}
