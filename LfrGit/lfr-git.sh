# lfr-git.sh — Liferay git helpers: safe clean, fork sync, master update, rebase.
#
# Source this from your shell rc (normally via the root lfrTools.sh). It defines:
#     lfrGitCleanDry   preview what `git clean` would remove (safe, no deletion)
#     lfrGitClean      remove untracked + ignored files, keeping IDE and per-user props
#     lfrGitSync       sync a fork's liferay-portal from upstream ([org] optional)
#     lfrGitSyncEE     sync a fork's liferay-portal-ee master from upstream ([org] optional)
#     lfrGitRebase     interactive rebase over the last N commits (default 20)
#     lfrGitUpdateMaster  update each master* mirror from the <remote>/master it tracks + sync; -r rebase current branch onto a target (default upstream), -f force, -p force-push ([-r] [-f] [-p] [rebase-target])
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

# Push the mirror commit <up> (a <remote>/master tracking ref) to the fork under
# refs/heads/<branch>. On a non-fast-forward the fork just holds history the
# source rewrote away, so force it with --force-with-lease (safe: only overwrites
# if the fork is still where our tracking ref last saw it).
_lfrGitPushMirror() {
	local branch="${1}" up="${2}" push_ref push_remote
	push_ref="$(git rev-parse --abbrev-ref "${branch}@{push}" 2>/dev/null)"
	case "${push_ref}" in
	*/*) push_remote="${push_ref%%/*}" ;;
	*) push_remote="origin" ;;
	esac
	echo "  pushing ${up} to ${push_remote} ${branch}..."
	git push "${push_remote}" "${up}:refs/heads/${branch}" 2>/dev/null && return 0
	echo "  ${push_remote} ${branch} was non-fast-forward; force-updating with --force-with-lease..." >&2
	git push --force-with-lease "${push_remote}" "${up}:refs/heads/${branch}"
}

# Point the local <branch> at <up> (its <remote>/master tracking ref): create it
# if missing, fast-forward it, or reset it when it diverged (which heals a mirror
# stranded by a rewritten source master). A mirror is a pure copy, so a
# divergence is the source's own rewritten history, not your work, and resetting
# is safe. If <branch> is checked out in a worktree, git will not move it (and
# moving it behind its working tree would desync that worktree), so say so and
# leave it, never checking it out.
_lfrGitUpdateLocalMaster() {
	local branch="${1}" up="${2}" tip wt target
	target="$(git rev-parse "${up}")"
	tip="$(git rev-parse --verify -q "refs/heads/${branch}" 2>/dev/null || true)"

	if [ "${tip}" = "${target}" ]; then
		echo "  ${branch} already up to date with ${up}."
		return 0
	fi

	wt="$(git worktree list --porcelain |
		awk -v b="branch refs/heads/${branch}" '/^worktree /{w=substr($0,10)} $0==b{print w; exit}')"
	if [ -n "${wt}" ]; then
		echo "  ${branch} is checked out at ${wt}; leaving it (reset it there: git -C \"${wt}\" reset --hard ${up})." >&2
		return 0
	fi

	if [ -z "${tip}" ]; then
		git branch "${branch}" "${target}" &&
			git branch --set-upstream-to="${up}" "${branch}" >/dev/null 2>&1 &&
			echo "  created local ${branch} tracking ${up}."
	elif git merge-base --is-ancestor "${branch}" "${target}" 2>/dev/null; then
		git update-ref "refs/heads/${branch}" "${target}" && echo "  fast-forwarded ${branch} to ${up}."
	else
		git update-ref "refs/heads/${branch}" "${target}" && echo "  reset ${branch} to ${up} (source rewrote master)."
	fi
}

# Keep your master mirrors current in one run. The mirrors to maintain are a list
# of "branch:remote" pairs in LFR_GIT_MASTER_MIRRORS (lfr-git.local.conf),
# defaulting to "master:upstream". For each pair: fetch <remote>/master, push it
# to your fork under <branch> (creating the branch on the fork if missing, and
# force-updating with --force-with-lease if the fork diverged), and create or
# reset the local <branch> to it (a mirror checked out in a worktree is left
# alone, with a note). So "master:upstream" "masterBrian:brian" keeps master and
# masterBrian current together. Then sync the team fork.
#
# With -r, rebase the current branch onto a target once the mirrors are fresh
# (skipped when you are on a master* mirror). The target defaults to
# upstream/master; pass a remote (e.g. `brian` -> brian/master) or a branch (e.g.
# `masterBrian`) to rebase onto Brian's line instead. The rebase is skipped when
# the branch already sits on the latest target; -f forces it, and -p (implies -r)
# then force-pushes the rebased branch with --force-with-lease.
# Args: [-r|--rebase] [-f|--force-rebase] [-p|--push] [rebase-target].
lfrGitUpdateMaster() {
	local cur a rebase=0 force_rebase=0 push_branch=0
	local -a pos=()
	for a in "$@"; do
		case "${a}" in
		-r | --rebase) rebase=1 ;;
		-f | --force-rebase) force_rebase=1; rebase=1 ;;
		-p | --push) push_branch=1; rebase=1 ;;
		-*) echo "lfrGitUpdateMaster: unknown flag '${a}'." >&2; return 1 ;;
		*) pos+=("${a}") ;;
		esac
	done
	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "lfrGitUpdateMaster: not inside a git repo" >&2
		return 1
	fi
	cur="$(git rev-parse --abbrev-ref HEAD)"

	# Which mirrors to maintain, as "branch:remote" pairs, each updated from
	# <remote>/master and created if missing. Set LFR_GIT_MASTER_MIRRORS in
	# lfr-git.local.conf (e.g. "master:upstream" "masterBrian:brian"); defaults to
	# just the upstream master mirror.
	local -a mirrors
	if [ "${LFR_GIT_MASTER_MIRRORS+x}" = x ] && [ "${#LFR_GIT_MASTER_MIRRORS[@]}" -gt 0 ]; then
		mirrors=("${LFR_GIT_MASTER_MIRRORS[@]}")
	else
		mirrors=("master:upstream")
	fi

	local pair branch remote up
	for pair in "${mirrors[@]}"; do
		branch="${pair%%:*}"
		remote="${pair##*:}"
		if [ -z "${branch}" ] || [ -z "${remote}" ] || [ "${branch}" = "${pair}" ]; then
			echo "lfrGitUpdateMaster: bad mirror spec '${pair}' (want branch:remote); skipping." >&2
			continue
		fi
		up="${remote}/master"
		echo "Updating ${branch} from ${up} (no tags)..."
		if ! git fetch --no-tags "${remote}" master; then
			echo "  fetch from ${remote} failed; skipping ${branch}." >&2
			continue
		fi
		_lfrGitPushMirror "${branch}" "${up}"
		_lfrGitUpdateLocalMaster "${branch}" "${up}"
	done

	# Sync the team fork; liferay-portal-ee checkouts use lfrGitSyncEE (detected by
	# the repo's remotes, not the folder name).
	if git remote -v 2>/dev/null | grep -q 'liferay-portal-ee'; then
		echo "Syncing EE fork..."
		lfrGitSyncEE
	else
		echo "Syncing fork..."
		lfrGitSync
	fi

	# Never rebase a mirror branch itself.
	case "${cur}" in
	master*)
		[ "${rebase}" = 1 ] && echo "On ${cur} (a master mirror); not rebasing it."
		return 0
		;;
	esac

	if [ "${rebase}" != 1 ]; then
		if [ "${#pos[@]}" -gt 0 ]; then
			echo "lfrGitUpdateMaster: rebase target '${pos[0]}' needs -r." >&2
			return 1
		fi
		return 0
	fi

	# Resolve the rebase target: default upstream/master; a remote name -> its
	# master; anything else -> a branch or ref (e.g. masterBrian, brian/master).
	local target="${pos[0]-}"
	if [ -z "${target}" ]; then
		target="upstream/master"
	elif git remote get-url "${target}" >/dev/null 2>&1; then
		target="${target}/master"
	fi
	if ! git rev-parse --verify -q "${target}" >/dev/null 2>&1; then
		echo "lfrGitUpdateMaster: rebase target '${target}' not found." >&2
		return 1
	fi

	# Skip a no-op rebase (the branch already sits on the latest target) unless -f.
	if [ "${force_rebase}" != 1 ] && git merge-base --is-ancestor "${target}" HEAD 2>/dev/null; then
		echo "${cur} already on latest ${target}; nothing to rebase."
		return 0
	fi

	echo "Rebasing ${cur} onto ${target}..."
	if ! git rebase "${target}"; then
		echo "lfrGitUpdateMaster: rebase stopped (resolve conflicts, then push yourself); skipping -p." >&2
		return 1
	fi

	# -p: the rebase rewrote history, so force-push the branch to its fork
	# (--force-with-lease, which refuses if the remote moved unexpectedly).
	if [ "${push_branch}" = 1 ]; then
		local push_ref push_remote
		push_ref="$(git rev-parse --abbrev-ref "${cur}@{push}" 2>/dev/null)"
		case "${push_ref}" in
		*/*) push_remote="${push_ref%%/*}" ;;
		*) push_remote="origin" ;;
		esac
		echo "Force-pushing ${cur} to ${push_remote} (--force-with-lease)..."
		git push --force-with-lease "${push_remote}" "${cur}"
	fi
}

# Short aliases.
lfrgc() { lfrGitClean "$@"; }
lfrgcd() { lfrGitCleanDry "$@"; }
lfrgs() { lfrGitSync "$@"; }
lfrgse() { lfrGitSyncEE "$@"; }
lfrgr() { lfrGitRebase "$@"; }
lfrgum() { lfrGitUpdateMaster "$@"; }
