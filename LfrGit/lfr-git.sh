# lfr-git.sh — Liferay git helpers: safe clean, fork sync, rebase.
#
# Source this from your shell rc (normally via the root lfrTools.sh). It defines:
#     lfrGitCleanDry   preview what `git clean` would remove (safe, no deletion)
#     lfrGitClean      remove untracked + ignored files, keeping IDE and per-user props
#     lfrGitSync       sync a fork's liferay-portal from upstream ([org] optional)
#     lfrGitSyncEE     sync a fork's liferay-portal-ee master from upstream ([org] optional)
#     lfrGitRebase     interactive rebase over the last N commits (default 20)
#     lfrGitUpdateMaster  update master, push it, sync, -r rebase your branch, -p force-push it ([-r] [-p] [remote] [local-branch])
#
# Per-user settings (your team fork org) live in lfr-git.local.conf next to this
# file. It is gitignored. Copy lfr-git.local.conf.example to lfr-git.local.conf.

_lfrGitDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "${_lfrGitDir}/lfr-git.local.conf" ] && . "${_lfrGitDir}/lfr-git.local.conf"

: "${LFR_GIT_UPSTREAM_ORG:=liferay}"

# Files kept during a clean: IDE project files and per-developer properties.
_lfrGitCleanExcludes=(
	-e '**/*.iml'
	-e '.idea'
	-e "app.server.${USER}.properties"
	-e "build.${USER}.properties"
	-e "test.${USER}.properties"
)

# Preview what would be removed. Run this before lfrGitClean.
lfrGitCleanDry() {
	git clean -xdn "${_lfrGitCleanExcludes[@]}" "$@"
}

# Actually remove untracked and ignored files (keeps the excludes above).
lfrGitClean() {
	git clean -xdf "${_lfrGitCleanExcludes[@]}" "$@"
}

# Resolve the fork org: use the passed argument, else LFR_GIT_FORK_ORG. Echoes
# the org on success; errors if neither is set.
_lfrGitForkOrg() {
	local org="${1:-${LFR_GIT_FORK_ORG:-}}"
	if [ -z "${org}" ]; then
		echo "lfrGitSync: pass a fork org or set LFR_GIT_FORK_ORG in ${_lfrGitDir}/lfr-git.local.conf" >&2
		return 1
	fi
	printf '%s\n' "${org}"
}

# Sync a team fork's liferay-portal from upstream. Pass a fork org to override
# the configured LFR_GIT_FORK_ORG: lfrGitSync [org]
lfrGitSync() {
	local org
	org="$(_lfrGitForkOrg "${1-}")" || return 1
	gh repo sync "${org}/liferay-portal" \
		--source "${LFR_GIT_UPSTREAM_ORG}/liferay-portal"
}

# Sync a team fork's liferay-portal-ee master from upstream. Pass a fork org to
# override the configured LFR_GIT_FORK_ORG: lfrGitSyncEE [org]
lfrGitSyncEE() {
	local org
	org="$(_lfrGitForkOrg "${1-}")" || return 1
	gh repo sync "${org}/liferay-portal-ee" --branch master \
		--source "${LFR_GIT_UPSTREAM_ORG}/liferay-portal-ee" --branch master
}

# Interactive rebase over the last N commits (default 20).
lfrGitRebase() {
	git rebase -i "HEAD~${1:-20}"
}

# The mirror push to the fork was refused (non-fast-forward). We push
# <src>/master (the canonical upstream tip), so this just means the fork's
# ${branch} holds history <src> rewrote away. Force it with --force-with-lease
# (safe: only overwrites if the fork is still where our tracking ref last saw it).
_lfrGitUpdateMasterPush() {
	local push_remote="${1}" branch="${2}" src="${3}"

	echo "  ${push_remote} ${branch} is non-fast-forward from ${src}/master" >&2
	echo "  (it holds history ${src} rewrote away). Force-updating with --force-with-lease..." >&2
	git push --force-with-lease "${push_remote}" "${src}/master:refs/heads/${branch}"
}

# Bring your fork's master up to date with <src>/master, and with -r rebase the
# current branch onto it. Fetches only the <src>/master tracking ref (never the
# local master branch, so it works even when master is checked out in a
# worktree), pushes that commit to your fork's master (force-updating with
# --force-with-lease if the fork diverged because <src> rewrote master), syncs
# the team fork (lfrGitSync, or lfrGitSyncEE in a liferay-portal-ee checkout),
# and rebases the current branch onto <src>/master. Args: [-r|--rebase]
# [-f|--force-rebase] [-p|--push] [remote]; the source remote defaults to
# upstream. Rebase is off by default; -r rebases only when master moved (a no-op
# is skipped), -f forces it anyway, and -p (implies -r) then force-pushes the
# rebased branch with --force-with-lease. Also points your local master at
# <src>/master each run (creating or resetting it, which heals a mirror stranded
# by an upstream master rewrite), unless master is checked out in a worktree, in
# which case it says so and leaves it. Never checks master out.

# Point the local <branch> at <src>/master so it always mirrors the latest
# upstream: create it if missing, fast-forward it, or reset it when it diverged
# (which heals a mirror stranded by an upstream master rewrite). Since this
# branch is a pure mirror, a divergence is upstream's own rewritten history, not
# your work, so resetting is safe. The one case we cannot handle is <branch>
# being checked out in a worktree (git refuses to move a checked-out branch, and
# moving it behind its working tree would desync that worktree): then say so and
# leave it, without ever checking it out.
_lfrGitUpdateLocalMaster() {
	local branch="${1}" src="${2}"
	local tip wt src_tip

	src_tip="$(git rev-parse "${src}/master")"
	tip="$(git rev-parse --verify -q "refs/heads/${branch}" 2>/dev/null || true)"

	[ "${tip}" = "${src_tip}" ] && return 0

	wt="$(git worktree list --porcelain |
		awk -v b="branch refs/heads/${branch}" '/^worktree /{w=substr($0,10)} $0==b{print w; exit}')"
	if [ -n "${wt}" ]; then
		echo "Local ${branch} is checked out at ${wt}; cannot update it from here" >&2
		echo "  (run 'git -C \"${wt}\" reset --hard ${src}/master' there)." >&2
		return 0
	fi

	if [ -z "${tip}" ]; then
		git branch "${branch}" "${src_tip}" && echo "Created local ${branch} at ${src}/master."
	elif git merge-base --is-ancestor "${branch}" "${src_tip}" 2>/dev/null; then
		git update-ref "refs/heads/${branch}" "${src_tip}" && echo "Fast-forwarded local ${branch} to ${src}/master."
	else
		git update-ref "refs/heads/${branch}" "${src_tip}" && echo "Reset local ${branch} to ${src}/master (upstream rewrote master)."
	fi
}

lfrGitUpdateMaster() {
	local src branch cur push_remote push_ref rebase=0 force_rebase=0 push_branch=0 a before after
	local -a pos=()
	for a in "$@"; do
		case "${a}" in
		-r | --rebase) rebase=1 ;;
		-f | --force-rebase) force_rebase=1; rebase=1 ;;
		-p | --push) push_branch=1; rebase=1 ;;
		*) pos+=("${a}") ;;
		esac
	done
	src="${pos[0]:-upstream}"
	branch="${pos[1]-}"
	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "lfrGitUpdateMaster: not inside a git repo" >&2
		return 1
	fi
	cur="$(git rev-parse --abbrev-ref HEAD)"

	# When no local branch is given, use the master-like branch that tracks
	# <src>/master (so a non-default remote lands in its own branch, e.g. brian ->
	# masterBrian), else plain master. Only master* names qualify, so a feature
	# branch tracking the same remote is never mistaken for it.
	if [ -z "${branch}" ]; then
		branch="$(git for-each-ref --format='%(refname:short) %(upstream:short)' refs/heads |
			awk -v u="${src}/master" '$2 == u && $1 ~ /^master/ { print $1; exit }')"
		[ -z "${branch}" ] && branch="master"
	fi

	echo "Fetching ${src}/master (no tags)..."
	before="$(git rev-parse --verify -q "${src}/master" 2>/dev/null || true)"
	# Fetch only the remote-tracking ref, never into the local master branch:
	# git refuses "master:master" when master is checked out in any worktree, and
	# we do not need a local master branch anyway.
	git fetch --no-tags "${src}" master || return 1
	after="$(git rev-parse --verify -q "${src}/master" 2>/dev/null || true)"

	if [ -z "${after}" ]; then
		echo "lfrGitUpdateMaster: ${src}/master did not resolve after fetch." >&2
		return 1
	fi

	# Push it to its configured push remote (your fork), like a bare git push.
	# A branch with no push config makes rev-parse echo the literal ref (rc 128),
	# so accept the value only when it resolved to <remote>/<branch>, else origin.
	push_ref="$(git rev-parse --abbrev-ref "${branch}@{push}" 2>/dev/null)"
	case "${push_ref}" in
	*/*) push_remote="${push_ref%%/*}" ;;
	*) push_remote="origin" ;;
	esac
	echo "Pushing ${src}/master to ${push_remote} ${branch}..."
	git push "${push_remote}" "${src}/master:refs/heads/${branch}" ||
		_lfrGitUpdateMasterPush "${push_remote}" "${branch}" "${src}" || return 1

	# Sync the team fork; liferay-portal-ee checkouts use lfrGitSyncEE. Detect EE
	# by the repo's remotes, not the directory name: a worktree may be named
	# liferay-portal-7.4.x yet track liferay-portal-ee.
	if git remote -v 2>/dev/null | grep -q 'liferay-portal-ee'; then
		echo "Syncing EE fork..."
		lfrGitSyncEE
	else
		echo "Syncing fork..."
		lfrGitSync
	fi

	# Point the local master mirror at the fresh upstream tip so it is always
	# current (create/reset as needed), unless it is checked out in a worktree
	# (then say so and skip it, never checking it out or hitting git's
	# checked-out-branch refusal).
	_lfrGitUpdateLocalMaster "${branch}" "${src}"

	# Rebase the current branch onto the updated branch when asked (-r) and you
	# are on a different branch. By default skip it when master did not move, so a
	# no-op rebase never churns commit dates or triggers a pointless -p force-push;
	# -f (force_rebase) runs the same plain rebase anyway.
	if [ "${rebase}" = 1 ] && [ "${cur}" != "${branch}" ] &&
		{ [ "${before}" != "${after}" ] || [ "${force_rebase}" = 1 ]; }; then
		echo "Rebasing ${cur} onto ${src}/master..."
		if ! git rebase "${src}/master"; then
			echo "lfrGitUpdateMaster: rebase stopped (resolve conflicts, then push yourself); skipping -p." >&2
			return 1
		fi
		# -p: the rebase rewrote history, so force-push the branch to its fork
		# (--force-with-lease, which refuses if the remote moved unexpectedly).
		if [ "${push_branch}" = 1 ]; then
			push_ref="$(git rev-parse --abbrev-ref "${cur}@{push}" 2>/dev/null)"
			case "${push_ref}" in
			*/*) push_remote="${push_ref%%/*}" ;;
			*) push_remote="origin" ;;
			esac
			echo "Force-pushing ${cur} to ${push_remote} (--force-with-lease)..."
			git push --force-with-lease "${push_remote}" "${cur}"
		fi
	elif [ "${rebase}" = 1 ] && [ "${cur}" != "${branch}" ]; then
		echo "${src}/master already up to date; nothing to rebase ${cur} onto."
	fi
}

# Short aliases.
lfrgc() { lfrGitClean "$@"; }
lfrgcd() { lfrGitCleanDry "$@"; }
lfrgs() { lfrGitSync "$@"; }
lfrgse() { lfrGitSyncEE "$@"; }
lfrgr() { lfrGitRebase "$@"; }
lfrgum() { lfrGitUpdateMaster "$@"; }
