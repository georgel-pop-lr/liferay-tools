# lfr-worktree.sh — create a Liferay git worktree (the lfrWorktree command).
#
# Worktree root and base ref come from the shared per-user config
# (LFR_WORKTREE_ROOT, LFR_WORKTREE_BASE), owned by LfrCommon/lfr-repo-list.sh.
#
# Usage:
#     lfrWorktree LPD-12345        # new worktree + branch LPD-12345 off upstream/master
#     lfrWorktree LPD-12345 hotfix # same, but branch off the given base ref instead
#
# Run it from inside any liferay-portal clone; the worktree is created under
# LFR_WORKTREE_ROOT as a sibling named liferay-portal-<branch>.

lfrWorktree() {
	case "${1-}" in
	-h | --help)
		cat <<-'EOF'
			lfrWorktree — create a git worktree with a new branch for a ticket.

			Usage:
			  lfrWorktree <branch>          new worktree + branch off upstream/master
			  lfrWorktree <branch> <base>   branch off the given base ref instead

			The worktree is created next to your repos as liferay-portal-<branch>
			and you are moved into it. Run it from inside any liferay-portal clone.
		EOF
		return 0
		;;
	esac

	local branch="$1"
	local base="${2:-${LFR_WORKTREE_BASE:-upstream/master}}"

	if [ -z "${branch}" ]; then
		echo "usage: lfrWorktree <branch> [base-ref]" >&2
		return 1
	fi

	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "lfrWorktree: not inside a git repo" >&2
		return 1
	fi

	local dir="${LFR_WORKTREE_ROOT:-${HOME}/liferay/repos}/liferay-portal-${branch}"

	if [ -e "${dir}" ]; then
		echo "lfrWorktree: ${dir} already exists" >&2
		return 1
	fi

	# Refresh the base ref's remote when it is qualified as <remote>/<ref>.
	local remote="${base%%/*}"
	local ref="${base#*/}"

	if [ "${remote}" != "${base}" ]; then
		echo "lfrWorktree: fetching ${remote} ${ref}..." >&2
		git fetch "${remote}" "${ref}" || return 1
	fi

	git worktree add -b "${branch}" "${dir}" "${base}" || return 1

	cd "${dir}" || return 1
}

# Short alias.
lfrw() { lfrWorktree "$@"; }
