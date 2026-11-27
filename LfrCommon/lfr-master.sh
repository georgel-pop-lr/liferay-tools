# lfr-master.sh - the shared "is this ticket in master?" check of the tools.
#
# Loaded via the root lfrTools.sh. A fix lands on brian/master (brianchandotcom)
# first, and upstream/master gets it only when the mirror syncs, hours later. A
# check that reads upstream alone, or a local ref that nobody fetched, says
# "not merged" for a fix that Brian merged. On 2026-11-26 a local brian/master
# of the day before hid the merge of LPD-115706.
#
#     _lfrMasterFetch <dir>     fetch master from upstream and brian, if the
#                               clone has the remote; 1 if a fetch failed
#     _lfrMasterRefs <dir>      echo the master refs to read (upstream/master and
#                               brian/master, else origin/master)
#     _lfrMasterDir <dir>       echo the clone to read master from: <dir>, or the
#                               full clone if <dir> is shallow
#     _lfrBranchBase [branch]   echo the base ref of a backport or patch branch
#     lfrGitMerged KEY...       one line for each key: merged or NOT merged
#
# The branch model (where each kind of branch lands) is in
# ~/.claude/references/branch-model.md.
#
# The same check for the Claude skills is ~/.claude/references/merges.py.

# Fetch master from each master remote of the clone <dir>. Prints a warning on
# stderr for each fetch that fails, and returns 1, so the caller can say that
# its answer can be stale.
_lfrMasterFetch() {
	local dir="${1:?_lfrMasterFetch: no dir}" remote status=0

	for remote in upstream brian; do
		git -C "${dir}" remote get-url "${remote}" >/dev/null 2>&1 || continue

		if ! git -C "${dir}" fetch --no-tags -q "${remote}" master 2>/dev/null; then
			echo "could not fetch ${remote}/master in ${dir}: the answer can be stale." >&2
			status=1
		fi
	done

	return "${status}"
}

# Echo the master refs of the clone <dir> to read, one for each line.
_lfrMasterRefs() {
	local dir="${1:?_lfrMasterRefs: no dir}" ref found=0

	for ref in upstream/master brian/master; do
		if git -C "${dir}" rev-parse --verify -q "${ref}" >/dev/null 2>&1; then
			printf '%s\n' "${ref}"
			found=1
		fi
	done

	if [ "${found}" = 0 ] && git -C "${dir}" rev-parse --verify -q origin/master >/dev/null 2>&1; then
		printf '%s\n' origin/master
	fi
}

# Echo the clone to read master from. The EE clone is shallow (its master starts
# on 2026-08-24), so a key merged before that shows as NOT merged there. The
# master hashes are the same in the two clones, so read the main clone instead.
# Both clones have a shallow file, so the test is the same upstream/master, not
# --is-shallow-repository of the main clone.
_lfrMasterDir() {
	local dir="${1:?_lfrMasterDir: no dir}" full head

	if [ "$(git -C "${dir}" rev-parse --is-shallow-repository 2>/dev/null)" != true ]; then
		printf '%s\n' "${dir}"
		return 0
	fi

	full="${LFR_REPO_ROOTS[0]:-${HOME}/liferay/repos}/${LFR_REPO_PRIORITY[0]:-liferay-portal}"
	head="$(git -C "${dir}" rev-parse -q --verify upstream/master 2>/dev/null)"

	if [ -n "${head}" ] &&
		[ "$(git -C "${full}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" != \
			"$(git -C "${dir}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ] &&
		[ "$(git -C "${full}" rev-parse -q --verify upstream/master 2>/dev/null)" = "${head}" ]; then
		echo "${dir} is a shallow clone: master is read from ${full}." >&2
		printf '%s\n' "${full}"
	else
		printf '%s\n' "${dir}"
	fi
}

# Echo the base ref of a backport or a patch branch, from its name (the current
# branch if none is given). A patch branch (LPD-1-2025.q1.22) starts from the
# tag 2025.q1.22, and a backport (LPD-1-release-2026.q1) lands on
# release-2026.q1. Returns 1 for any other branch: its base is master. Compared
# with master, LPD-115706-release-2026.q1 showed 0 commits and 1 file, not 6
# commits and 10 files.
_lfrBranchBase() {
	local branch="${1:-$(git branch --show-current 2>/dev/null)}" patch release ref

	patch="$(grep -oE '[0-9]{4}\.q[1-4]\.[0-9]+' <<<"${branch}" | head -n 1)"

	if [ -n "${patch}" ] && git rev-parse --verify -q "refs/tags/${patch}" >/dev/null 2>&1; then
		printf '%s\n' "${patch}"
		return 0
	fi

	release="$(grep -oE '[0-9]{4}\.q[1-4]' <<<"${branch}" | head -n 1)"

	[ -n "${release}" ] || return 1

	for ref in "upstream/release-${release}" "origin/release-${release}" "release-${release}"; do
		if git rev-parse --verify -q "${ref}" >/dev/null 2>&1; then
			printf '%s\n' "${ref}"
			return 0
		fi
	done

	return 1
}

# lfrGitMerged - say for each ticket key if a commit of it is in master.
lfrGitMerged() {
	local a dir="" fetch=1 key ref line holders
	local -a keys=() refs=()

	for a in "$@"; do
		case "${a}" in
		-h | --help)
			cat <<-'EOF'
				lfrGitMerged [-n] [-C dir] KEY...

				Fetch master from upstream and brian (brianchandotcom), then print one
				line for each key:
				    KEY merged <sha> <date> <refs that hold it>  <subject>
				    KEY NOT merged

				Brian merges first, so a key can be in brian/master only.
				  -n, --no-fetch  read the refs as they are
				  -C dir          the clone to read (default: the current repo, else
				                  the first LFR_REPO_PRIORITY clone)
			EOF
			return 0
			;;
		-n | --no-fetch) fetch=0 ;;
		-C) dir="__next__" ;;
		-*) echo "lfrGitMerged: unknown flag '${a}'." >&2; return 1 ;;
		*)
			if [ "${dir}" = "__next__" ]; then
				dir="${a}"
			else
				keys+=("${a^^}")
			fi
			;;
		esac
	done

	if [ "${#keys[@]}" = 0 ]; then
		echo "lfrGitMerged: no ticket key. Run lfrGitMerged -h." >&2
		return 1
	fi

	if [ -z "${dir}" ]; then
		dir="$(git rev-parse --show-toplevel 2>/dev/null)"
	fi

	if [ -z "${dir}" ]; then
		dir="${LFR_REPO_ROOTS[0]:-${HOME}/liferay/repos}/${LFR_REPO_PRIORITY[0]:-liferay-portal}"
	fi

	if ! git -C "${dir}" rev-parse --git-dir >/dev/null 2>&1; then
		echo "lfrGitMerged: ${dir} is not a git repo; pass -C <clone>." >&2
		return 1
	fi

	dir="$(_lfrMasterDir "${dir}")"

	[ "${fetch}" = 1 ] && _lfrMasterFetch "${dir}"

	mapfile -t refs < <(_lfrMasterRefs "${dir}")

	if [ "${#refs[@]}" = 0 ]; then
		echo "lfrGitMerged: ${dir} has no master ref (upstream, brian, origin)." >&2
		return 1
	fi

	for key in "${keys[@]}"; do
		line="$(git -C "${dir}" log -1 -E "${refs[@]}" --grep="\\b${key}\\b" \
			--format='%h %cs  %s' 2>/dev/null)"

		if [ -z "${line}" ]; then
			printf '%s NOT merged\n' "${key}"
			continue
		fi

		holders=""

		for ref in "${refs[@]}"; do
			git -C "${dir}" merge-base --is-ancestor "${line%% *}" "${ref}" 2>/dev/null &&
				holders="${holders:+${holders},}${ref}"
		done

		printf '%s merged %s %s  %s\n' "${key}" "${line%%  *}" "${holders}" "${line#*  }"
	done
}
