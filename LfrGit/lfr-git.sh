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

# Bring your local master branch current, and optionally rebase your current
# branch onto it. Steps: fast-forward the local master branch from the source
# remote's master (no tags), push it to your fork, sync the team fork
# (lfrGitSync, or lfrGitSyncEE in a liferay-portal-ee checkout), and with -r
# rebase the current branch onto it. Args: [-r|--rebase] [-f|--force-rebase]
# [-p|--push] [remote] [local-branch]. The source remote defaults to upstream.
# The local branch defaults to the master* branch that tracks <remote>/master
# (else plain master), so a non-default remote lands in its own branch
# automatically, e.g. `lfrGitUpdateMaster brian` updates masterBrian. Rebase is
# off by default so a plain run just keeps the master branch current and never
# rebases master onto another branch. Pass -r to rebase your feature branch onto
# it, but only when master actually moved (a no-op rebase is skipped). Pass -f
# (implies -r) to force that plain rebase even when master did not move. Pass -p
# (implies -r) to then force-push the rebased branch to its fork with
# --force-with-lease.
# Explain the usual cause of a failed master update: the local mirror branch has
# diverged from <src>/master (commits <src> later rewrote out of master, not your
# own work), so the fast-forward is refused and git prints only a terse
# "non-fast-forward". Show the ahead/behind counts, the offending commits, and
# the one-line reset. No-op (leaving git's own error to stand) when the branch is
# not actually ahead, e.g. a network or auth failure.
_lfrGitUpdateMasterExplain() {
	local branch="${1}" src="${2}"
	local counts ahead behind head

	counts="$(git rev-list --left-right --count "${branch}...${src}/master" 2>/dev/null)" || return 0

	ahead="${counts%%[[:space:]]*}"
	behind="${counts##*[[:space:]]}"

	[ "${ahead:-0}" -gt 0 ] 2>/dev/null || return 0

	echo >&2
	echo "lfrGitUpdateMaster: cannot fast-forward ${branch} to ${src}/master." >&2
	echo "  ${branch} has ${ahead} commit(s) not on ${src}/master (and is ${behind} behind)," >&2
	echo "  so this is not a fast-forward. These are usually commits ${src} rewrote" >&2
	echo "  out of master, not your own work:" >&2
	git log --oneline --no-decorate "${branch}" "^${src}/master" 2>/dev/null | sed 's/^/    /' >&2
	echo >&2

	head="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
	echo "  If you keep no work on ${branch}, reset it to ${src}/master:" >&2
	if [ "${head}" = "${branch}" ]; then
		echo "    git reset --hard ${src}/master" >&2
	else
		echo "    git branch -f ${branch} ${src}/master" >&2
	fi
	echo "  then re-run lfrGitUpdateMaster." >&2
}

# The plain push of the master mirror was refused (non-fast-forward). When the
# local branch is exactly <src>/master (a clean mirror with no local work of its
# own), the fork just holds history <src> rewrote away, so force-update it with
# --force-with-lease (safe: overwrites only if the fork is still where the
# tracking ref last saw it). Otherwise the branch carries local commits, so
# refuse to force and explain.
_lfrGitUpdateMasterPush() {
	local push_remote="${1}" branch="${2}" src="${3}"
	local local_tip src_tip

	local_tip="$(git rev-parse "${branch}" 2>/dev/null)"
	src_tip="$(git rev-parse "${src}/master" 2>/dev/null)"

	if [ -n "${src_tip}" ] && [ "${local_tip}" = "${src_tip}" ]; then
		echo "  ${branch} matches ${src}/master exactly; ${push_remote} holds history" >&2
		echo "  ${src} rewrote away. Force-updating with --force-with-lease..." >&2
		git push --force-with-lease "${push_remote}" "${branch}"
		return
	fi

	echo >&2
	echo "lfrGitUpdateMaster: cannot push ${branch} to ${push_remote} (non-fast-forward)," >&2
	echo "  and ${branch} does not match ${src}/master, so it carries local commits." >&2
	echo "  Not force-pushing. Reconcile with ${push_remote} yourself" >&2
	echo "  (e.g. git pull --rebase ${push_remote} ${branch}), then re-run." >&2
	return 1
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

	echo "Updating ${branch} from ${src}/master (fast-forward, no tags)..."
	before="$(git rev-parse --verify -q "${branch}" 2>/dev/null)"
	if [ "${cur}" = "${branch}" ]; then
		git pull --no-tags --ff-only "${src}" master ||
			{ _lfrGitUpdateMasterExplain "${branch}" "${src}"; return 1; }
	else
		git fetch --no-tags "${src}" "master:${branch}" ||
			{ _lfrGitUpdateMasterExplain "${branch}" "${src}"; return 1; }
	fi
	after="$(git rev-parse --verify -q "${branch}" 2>/dev/null)"

	# Push it to its configured push remote (your fork), like a bare git push.
	# A branch with no push config makes rev-parse echo the literal ref (rc 128),
	# so accept the value only when it resolved to <remote>/<branch>, else origin.
	push_ref="$(git rev-parse --abbrev-ref "${branch}@{push}" 2>/dev/null)"
	case "${push_ref}" in
	*/*) push_remote="${push_ref%%/*}" ;;
	*) push_remote="origin" ;;
	esac
	echo "Pushing ${branch} to ${push_remote}..."
	git push "${push_remote}" "${branch}" ||
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

	# Rebase the current branch onto the updated branch when asked (-r) and you
	# are on a different branch. By default skip it when master did not move, so a
	# no-op rebase never churns commit dates or triggers a pointless -p force-push;
	# -f (force_rebase) runs the same plain rebase anyway.
	if [ "${rebase}" = 1 ] && [ "${cur}" != "${branch}" ] &&
		{ [ "${before}" != "${after}" ] || [ "${force_rebase}" = 1 ]; }; then
		echo "Rebasing ${cur} onto ${branch}..."
		if ! git rebase "${branch}"; then
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
		echo "${branch} already up to date; nothing to rebase ${cur} onto."
	fi
}

# Short aliases.
lfrgc() { lfrGitClean "$@"; }
lfrgcd() { lfrGitCleanDry "$@"; }
lfrgs() { lfrGitSync "$@"; }
lfrgse() { lfrGitSyncEE "$@"; }
lfrgr() { lfrGitRebase "$@"; }
lfrgum() { lfrGitUpdateMaster "$@"; }
