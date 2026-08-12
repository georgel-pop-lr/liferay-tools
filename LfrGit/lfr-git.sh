# lfr-git.sh — Liferay git helpers: safe clean, fork sync, master update, rebase.
#
# Source this from your shell rc (normally via the root lfrTools.sh). It defines:
#     lfrGitCleanDry   preview what `git clean` would remove (safe, no deletion)
#     lfrGitClean      remove untracked + ignored files, keeping IDE and per-user props
#     lfrGitSync       sync a fork's liferay-portal from upstream ([org] optional)
#     lfrGitSyncEE     sync a fork's liferay-portal-ee master from upstream ([org] optional)
#     lfrGitRebase     interactive rebase over the last N commits (default 20)
#     lfrGitRebaseOnto replay only this branch's own commits onto a target (default upstream/master), dropping the mirror history it was rebased onto ([target])
#     lfrGitUpdateMaster  update each master* mirror from the <remote>/master it tracks + sync; -r rebase current branch onto a target (default upstream), -f force, -o cut at the fork point, -p force-push ([-r] [-f] [-o] [-p] [rebase-target])
#     lfrGitUpdateBranch  update one branch (e.g. release-2026.q1) from upstream and push it to your fork, creating it locally if you do not have it ([branch] [-n])
#     lfrGitCheckoutTag   check out a tag (e.g. 2026.q1.8) on a local branch, fetching the tag from upstream and reusing the branch if it exists (<tag> [branch] [-n])
#
# Per-user settings (your team fork org) live in lfr-git.local.conf next to this
# file. It is gitignored. Copy lfr-git.local.conf.example to lfr-git.local.conf.

_lfrGitDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "${_lfrGitDir}/lfr-git.local.conf" ] && . "${_lfrGitDir}/lfr-git.local.conf"

: "${LFR_GIT_UPSTREAM_ORG:=liferay}"
: "${LFR_GIT_UPSTREAM_REMOTE:=upstream}"

# Files kept during a clean: IDE project files and per-developer properties.
_lfrGitCleanExcludes=(
	-e '**/*.iml'
	-e '.idea'
	-e "app.server.${USER}.properties"
	-e "build.${USER}.properties"
	-e "test.${USER}.properties"
)

# Shared help for the lfrGit* commands.
_lfrGitHelp() {
	cat <<-'EOF'
		lfrGit* — Liferay git helpers.

		Commands:
		  lfrGitClean          delete untracked and ignored files, but keep IDE
		                       files and your per-user *.properties
		  lfrGitCleanDry       preview what lfrGitClean would delete (deletes
		                       nothing)
		  lfrGitSync [org]     sync your team fork's liferay-portal master from
		                       upstream (org defaults to LFR_GIT_FORK_ORG)
		  lfrGitSyncEE [org]   same, for liferay-portal-ee
		  lfrGitRebase [N]     interactive rebase over the last N commits (default 20)
		  lfrGitRebaseOnto [target]
		                       replay only this branch's own commits onto <target>
		                       (default upstream/master), dropping any mirror
		                       history it was rebased onto in between: use it when
		                       a branch ended up on masterBrian and belongs on
		                       master. Updates no mirror and syncs no fork.
		  lfrGitUpdateMaster [-r] [-f] [-o] [-p] [target]
		                       refresh your master mirror branches from their
		                       remotes and sync your fork, from any worktree: a
		                       mirror checked out elsewhere is fast-forwarded
		                       inside that worktree, so it lands wherever it
		                       lives; with -r also rebase the current branch onto
		                       <target> (default upstream/master), -f forces the
		                       rebase, -o cuts at the branch's own fork point,
		                       -p then force-pushes it
		  lfrGitUpdateBranch [branch] [-n]
		                       update one branch (e.g. release-2026.q1) from
		                       upstream and push it to your fork; the branch
		                       defaults to the one you are on, and is created
		                       locally when you do not have it yet. -n skips
		                       the push
		  lfrGitCheckoutTag <tag> [branch] [-n]
		                       check out a tag (e.g. 2026.q1.8) on a local
		                       branch: fetch the tag from upstream, branch off
		                       it, push the branch to your fork. The branch
		                       defaults to the tag's name and is reused when it
		                       already exists. -n skips the push

		Aliases: lfrgc lfrgcd lfrgs lfrgse lfrgr lfrgro lfrgum lfrgub lfrgct

		A rebase only ever moves the branch's own commits, and refuses to replay
		more than LFR_GIT_REBASE_MAX (default 50).
	EOF
}

# Preview what would be removed. Run this before lfrGitClean.
lfrGitCleanDry() {
	case "${1-}" in -h | --help) _lfrGitHelp; return 0 ;; esac
	git clean -xdn "${_lfrGitCleanExcludes[@]}" "$@"
}

# Actually remove untracked and ignored files (keeps the excludes above).
lfrGitClean() {
	case "${1-}" in -h | --help) _lfrGitHelp; return 0 ;; esac
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
	case "${1-}" in -h | --help) _lfrGitHelp; return 0 ;; esac
	local org
	org="$(_lfrGitForkOrg "${1-}")" || return 1
	gh repo sync "${org}/liferay-portal" \
		--source "${LFR_GIT_UPSTREAM_ORG}/liferay-portal"
}

# Sync a team fork's liferay-portal-ee master from upstream. Pass a fork org to
# override the configured LFR_GIT_FORK_ORG: lfrGitSyncEE [org]
lfrGitSyncEE() {
	case "${1-}" in -h | --help) _lfrGitHelp; return 0 ;; esac
	local org
	org="$(_lfrGitForkOrg "${1-}")" || return 1
	gh repo sync "${org}/liferay-portal-ee" --branch master \
		--source "${LFR_GIT_UPSTREAM_ORG}/liferay-portal-ee" --branch master
}

# Interactive rebase over the last N commits (default 20).
lfrGitRebase() {
	case "${1-}" in -h | --help) _lfrGitHelp; return 0 ;; esac
	git rebase -i "HEAD~${1:-20}"
}

# The remote a branch is pushed to: the remote of its @{push} ref, falling back to
# origin. Pass the source remote it mirrors (upstream, brian) to rule that one out:
# a mirror tracks its source, so without remote.pushDefault set, @{push} resolves
# right back to the source, and a mirror is never pushed to the repo it copies.
_lfrGitPushRemote() {
	local branch="${1}" source_remote="${2-}" push_ref push_remote
	push_ref="$(git rev-parse --abbrev-ref "${branch}@{push}" 2>/dev/null)"
	case "${push_ref}" in
	*/*) push_remote="${push_ref%%/*}" ;;
	*) push_remote="origin" ;;
	esac
	if [ -n "${source_remote}" ] && [ "${push_remote}" = "${source_remote}" ]; then
		push_remote="origin"
	fi
	printf '%s\n' "${push_remote}"
}

# Push the mirror commit <up> (a <remote>/<branch> tracking ref) to the fork under
# refs/heads/<branch>. On a non-fast-forward the fork just holds history the
# source rewrote away, so force it with --force-with-lease (safe: only overwrites
# if the fork is still where our tracking ref last saw it).
# Args: <branch> <up> [source-remote]
_lfrGitPushMirror() {
	local branch="${1}" up="${2}" push_remote
	push_remote="$(_lfrGitPushRemote "${branch}" "${3-}")"
	echo "  pushing ${up} to ${push_remote} ${branch}..."
	git push "${push_remote}" "${up}:refs/heads/${branch}" 2>/dev/null && return 0
	echo "  ${push_remote} ${branch} was non-fast-forward; force-updating with --force-with-lease..." >&2
	git push --force-with-lease "${push_remote}" "${up}:refs/heads/${branch}"
}

# Bring the local <branch> to <up> (its <remote>/<branch> tracking ref): create it
# if missing, fast-forward it, or reset it when the source rewrote the branch (a
# mirror is a pure copy, so a divergence is the source's own rewritten history,
# not your work). Checked out HERE, it is fast-forwarded in place (you are standing
# on it, so its working tree moves with it); checked out in ANOTHER worktree, the
# fast-forward is run inside that worktree, which is the only way to move it
# without leaving that tree's files behind its HEAD. A master mirror and a release
# branch are the same job, so both go through here.
_lfrGitUpdateLocalMirror() {
	local branch="${1}" up="${2}" tip wt target head reason
	target="$(git rev-parse "${up}")"
	tip="$(git rev-parse --verify -q "refs/heads/${branch}" 2>/dev/null || true)"

	if [ "${tip}" = "${target}" ]; then
		echo "  ${branch} already up to date with ${up}."
		return 0
	fi

	# Checked out in THIS worktree: update in place rather than refusing.
	head="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
	if [ "${head}" = "${branch}" ]; then
		if ! git merge-base --is-ancestor "${branch}" "${target}" 2>/dev/null; then
			echo "  ${branch} is checked out here and has diverged from ${up}; reset it yourself: git reset --hard ${up}." >&2
		elif git merge --ff-only "${target}" >/dev/null 2>&1; then
			echo "  fast-forwarded ${branch} (checked out here) to ${up}."
		else
			echo "  ${branch} is checked out here with local changes; commit or stash, then re-run (or: git merge --ff-only ${up})." >&2
		fi
		return 0
	fi

	# Checked out in another worktree: moving the branch from here would leave that
	# worktree's HEAD ahead of its own files, so run the fast-forward inside it,
	# where ref, index, and files move together. A mirror has to be current wherever
	# it lives, so this is the normal path, not a special case; only a rewritten
	# source (needs a reset, which drops commits) or a merge git itself refuses
	# (local changes in the way) is left for you.
	wt="$(git worktree list --porcelain |
		awk -v b="branch refs/heads/${branch}" '/^worktree /{w=substr($0,10)} $0==b{print w; exit}')"
	if [ -n "${wt}" ]; then
		if ! git merge-base --is-ancestor "${branch}" "${target}" 2>/dev/null; then
			echo "  ${branch} is checked out at ${wt} and has diverged from ${up}; reset it there: git -C \"${wt}\" reset --hard ${up}." >&2
		elif reason="$(git -C "${wt}" merge --ff-only "${target}" 2>&1 >/dev/null)"; then
			echo "  fast-forwarded ${branch} to ${up} in ${wt}."
		else
			echo "  ${branch} is checked out at ${wt} and would not fast-forward there: ${reason%%$'\n'*}" >&2
			echo "  (see git -C \"${wt}\" status, clear that, then re-run)" >&2
		fi
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

# The mirrors to maintain, as "branch:remote" pairs one per line: whatever
# LFR_GIT_MASTER_MIRRORS holds, else just the upstream master mirror.
_lfrGitMirrors() {
	if [ "${LFR_GIT_MASTER_MIRRORS+x}" = x ] && [ "${#LFR_GIT_MASTER_MIRRORS[@]}" -gt 0 ]; then
		printf '%s\n' "${LFR_GIT_MASTER_MIRRORS[@]}"
	else
		printf '%s\n' "master:upstream"
	fi
}

# Every ref a branch could have been rebased onto: each mirror's <remote>/master
# and the local mirror branch that tracks it.
_lfrGitMirrorRefs() {
	local pair
	while read -r pair; do
		[ -n "${pair}" ] || continue
		printf '%s\n%s\n' "${pair##*:}/master" "${pair%%:*}"
	done < <(_lfrGitMirrors)
}

# Resolve a rebase target: empty -> upstream/master; a remote name -> its master;
# anything else -> a branch or ref (e.g. masterBrian, brian/master).
_lfrGitRebaseTarget() {
	local target="${1-}"
	if [ -z "${target}" ]; then
		target="upstream/master"
	elif git remote get-url "${target}" >/dev/null 2>&1; then
		target="${target}/master"
	fi
	if ! git rev-parse --verify -q "${target}" >/dev/null 2>&1; then
		echo "rebase target '${target}' not found." >&2
		return 1
	fi
	printf '%s\n' "${target}"
}

# Where HEAD really forked from the master line. `git rebase <target>` always cuts
# at merge-base(target, HEAD), so a branch you rebased onto another mirror carries
# that mirror's commits between the target and your work, and the rebase replays
# every one of them as yours (masterBrian runs hundreds of commits ahead of
# upstream/master, so that is hundreds rewritten under your name). Compare every
# mirror and echo the fork point that leaves the fewest commits to replay: that is
# the one the branch was really built on.
_lfrGitForkPoint() {
	local target="${1}" base count mb n ref
	base="$(git merge-base "${target}" HEAD)" || return 1
	count="$(git rev-list --count "${base}..HEAD")"
	while read -r ref; do
		git rev-parse --verify -q "${ref}" >/dev/null 2>&1 || continue
		mb="$(git merge-base "${ref}" HEAD 2>/dev/null)" || continue
		n="$(git rev-list --count "${mb}..HEAD")"
		if [ "${n}" -lt "${count}" ]; then
			base="${mb}"
			count="${n}"
		fi
	done < <(_lfrGitMirrorRefs)
	printf '%s\n' "${base}"
}

# Rebase HEAD onto <target>, replaying only the branch's own commits: cut at the
# real fork point with --onto whenever that differs from merge-base(target, HEAD),
# which is exactly the case a plain rebase gets wrong. Refuses a run that would
# replay more than LFR_GIT_REBASE_MAX commits (default 50), since no branch owns
# that many; it means the fork point is wrong and the rebase is about to rewrite
# other people's commits as yours. Returns 2 when there is nothing to do.
# Args: <branch> <target> <force_rebase 0|1> <rebase_onto 0|1>
_lfrGitRebaseOnto() {
	local cur="${1}" target="${2}" force_rebase="${3}" rebase_onto="${4}"
	local base target_base replay max
	local -a rebase_args

	target_base="$(git merge-base "${target}" HEAD)" || return 1
	base="$(_lfrGitForkPoint "${target}")" || return 1

	if [ "${base}" != "${target_base}" ] || [ "${rebase_onto}" = 1 ]; then
		rebase_args=(--onto "${target}" "${base}")
	elif [ "${force_rebase}" != 1 ] && git merge-base --is-ancestor "${target}" HEAD 2>/dev/null; then
		echo "${cur} already on latest ${target}; nothing to rebase."
		return 2
	elif [ "${force_rebase}" = 1 ]; then
		rebase_args=(--force-rebase "${target}")
	else
		rebase_args=("${target}")
	fi

	replay="$(git rev-list --count "${base}..HEAD")"
	max="${LFR_GIT_REBASE_MAX:-50}"
	if [ "${replay}" -gt "${max}" ]; then
		echo "lfrGitRebaseOnto: rebasing ${cur} onto ${target} would replay ${replay} commits (limit ${max})." >&2
		echo "  No branch owns that many, so the fork point is wrong and those commits are someone else's." >&2
		echo "  See them with: git log --oneline $(git rev-parse --short "${base}")..HEAD" >&2
		echo "  Override for this run with LFR_GIT_REBASE_MAX=${replay}." >&2
		return 3
	fi

	if [ "${base}" != "${target_base}" ]; then
		echo "${cur} sits on $(git rev-parse --short "${base}"), not on ${target}; replaying only its ${replay} own commit(s) onto ${target}..."
	else
		echo "Rebasing ${cur} onto ${target}..."
	fi
	git rebase "${rebase_args[@]}"
}

# Replay only the current branch's own commits onto <target> (default
# upstream/master), dropping whatever mirror history it picked up in between: the
# fix for a branch that ended up on masterBrian and belongs on master. Unlike
# `lfrGitUpdateMaster -r`, this touches no mirror and syncs no fork.
# Args: lfrGitRebaseOnto [target]
lfrGitRebaseOnto() {
	case "${1-}" in -h | --help) _lfrGitHelp; return 0 ;; esac
	local cur target
	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "lfrGitRebaseOnto: not inside a git repo" >&2
		return 1
	fi
	cur="$(git rev-parse --abbrev-ref HEAD)"
	case "${cur}" in
	master*)
		echo "lfrGitRebaseOnto: ${cur} is a master mirror; not rebasing it." >&2
		return 1
		;;
	esac
	target="$(_lfrGitRebaseTarget "${1-}")" || return 1
	_lfrGitRebaseOnto "${cur}" "${target}" 0 1
}

# Keep your master mirrors current in one run. The mirrors to maintain are a list
# of "branch:remote" pairs in LFR_GIT_MASTER_MIRRORS (lfr-git.local.conf),
# defaulting to "master:upstream". For each pair: fetch <remote>/master, push it
# to your fork under <branch> (creating the branch on the fork if missing, and
# force-updating with --force-with-lease if the fork diverged), and create or
# update the local <branch> to it (a mirror checked out in a worktree is
# fast-forwarded inside that worktree; see _lfrGitUpdateLocalMirror). So
# "master:upstream" "masterBrian:brian" keeps master and masterBrian current
# together. Then sync the team fork.
#
# With -r, rebase the current branch onto a target once the mirrors are fresh
# (skipped when you are on a master* mirror). The target defaults to
# upstream/master; pass a remote (e.g. `brian` -> brian/master) or a branch (e.g.
# `masterBrian`) to rebase onto Brian's line instead. The rebase is skipped when
# the branch already sits on the latest target; -f forces it, and -p (implies -r)
# then force-pushes the rebased branch with --force-with-lease. Only the branch's
# own commits ever move: a branch built on another mirror is cut at its real fork
# point (see _lfrGitRebaseOnto), and -o forces that cut even when it is not needed.
# Args: [-r|--rebase] [-f|--force-rebase] [-o|--rebase-onto] [-p|--push] [rebase-target].
lfrGitUpdateMaster() {
	local cur a rebase=0 force_rebase=0 rebase_onto=0 push_branch=0
	local -a pos=()
	for a in "$@"; do
		case "${a}" in
		-h | --help) _lfrGitHelp; return 0 ;;
		-r | --rebase) rebase=1 ;;
		-f | --force-rebase) force_rebase=1; rebase=1 ;;
		-o | --rebase-onto) rebase_onto=1; rebase=1 ;;
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
	local -a mirrors=()
	local mirror
	while read -r mirror; do
		[ -n "${mirror}" ] && mirrors+=("${mirror}")
	done < <(_lfrGitMirrors)

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
		_lfrGitPushMirror "${branch}" "${up}" "${remote}"
		_lfrGitUpdateLocalMirror "${branch}" "${up}"
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

	local target
	target="$(_lfrGitRebaseTarget "${pos[0]-}")" || return 1

	# -f (--force-rebase) recreates the commits even when the branch already sits on
	# the target, where a plain `git rebase` no-ops ("up to date"); -o forces the
	# fork-point cut. _lfrGitRebaseOnto applies that cut on its own whenever the branch
	# turns out to be built on another mirror, so -f can no longer drag that
	# mirror's history in as your commits.
	_lfrGitRebaseOnto "${cur}" "${target}" "${force_rebase}" "${rebase_onto}"
	case "$?" in
	0) ;;
	2) return 0 ;;
	3) return 1 ;;
	*)
		echo "lfrGitUpdateMaster: rebase stopped (resolve conflicts, then push yourself); skipping -p." >&2
		return 1
		;;
	esac

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

# The remote the release branches and patch tags come from (LFR_GIT_UPSTREAM_REMOTE,
# default upstream). Echoes it; errors when the repo has no such remote.
_lfrGitUpstreamRemote() {
	local caller="${1}" remote="${LFR_GIT_UPSTREAM_REMOTE}"
	if ! git remote get-url "${remote}" >/dev/null 2>&1; then
		echo "${caller}: this repo has no '${remote}' remote (set LFR_GIT_UPSTREAM_REMOTE in ${_lfrGitDir}/lfr-git.local.conf)." >&2
		return 1
	fi
	printf '%s\n' "${remote}"
}

# Update one branch from upstream and push it to your fork: the release branches
# (release-2026.q1) a backport is built on, which you want current before you
# branch off them. The branch defaults to the one you are on, and you do not need
# it locally first, since a branch you do not have is created from upstream here
# (that is the usual case: you fetch a release branch the first time you need it).
#
# It is the same job as a master mirror, so it takes the same route: fetch
# <upstream>/<branch>, push that commit to your fork, and move the local branch to
# it, wherever it is checked out (see _lfrGitUpdateLocalMirror). Which means it is
# a mirror both ways: the local branch is reset to upstream when the two diverged,
# so keep your own work on a branch of its own, never on release-*.
# Args: lfrGitUpdateBranch [branch] [-n|--no-push]
lfrGitUpdateBranch() {
	local a branch="" push=1
	for a in "$@"; do
		case "${a}" in
		-h | --help) _lfrGitHelp; return 0 ;;
		-n | --no-push) push=0 ;;
		-*) echo "lfrGitUpdateBranch: unknown flag '${a}'." >&2; return 1 ;;
		*)
			if [ -n "${branch}" ]; then
				echo "lfrGitUpdateBranch: one branch at a time (got '${branch}' and '${a}')." >&2
				return 1
			fi
			branch="${a}"
			;;
		esac
	done
	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "lfrGitUpdateBranch: not inside a git repo" >&2
		return 1
	fi

	# No branch named: the one you are standing on. A master mirror is
	# lfrGitUpdateMaster's job, which also syncs the fork and can rebase.
	if [ -z "${branch}" ]; then
		branch="$(git rev-parse --abbrev-ref HEAD)"
		if [ "${branch}" = HEAD ]; then
			echo "lfrGitUpdateBranch: HEAD is detached; name the branch to update." >&2
			return 1
		fi
	fi
	case "${branch}" in
	master*)
		echo "lfrGitUpdateBranch: ${branch} is a master mirror; use lfrGitUpdateMaster." >&2
		return 1
		;;
	esac

	local remote up
	remote="$(_lfrGitUpstreamRemote lfrGitUpdateBranch)" || return 1
	up="${remote}/${branch}"

	echo "Updating ${branch} from ${up} (no tags)..."
	if ! git fetch --no-tags "${remote}" "${branch}"; then
		echo "  ${remote} has no branch ${branch}; nothing to update." >&2
		return 1
	fi
	if ! git rev-parse --verify -q "${up}" >/dev/null 2>&1; then
		echo "  fetched ${branch} but ${up} does not exist; check remote.${remote}.fetch." >&2
		return 1
	fi

	_lfrGitUpdateLocalMirror "${branch}" "${up}"
	[ "${push}" = 1 ] && _lfrGitPushMirror "${branch}" "${up}" "${remote}"
	return 0
}

# Check out a tag on a local branch: the patch versions (2026.q1.8) and fix packs
# (fix-pack-de-85-7010) a backport branches off. The tag is fetched from upstream
# into FETCH_HEAD, so you do not need it locally first, and a tag you do have is
# refreshed from upstream rather than trusted.
#
# The branch defaults to the tag's name, and an existing branch of that name is
# checked out as it is rather than moved, since it is yours by then and may carry
# the commits you already cherry-picked. Then it is pushed to your fork with -u, so
# a later plain `git push` goes to the right place.
# Args: lfrGitCheckoutTag <tag> [branch] [-n|--no-push]
lfrGitCheckoutTag() {
	local a tag="" branch="" push=1
	for a in "$@"; do
		case "${a}" in
		-h | --help) _lfrGitHelp; return 0 ;;
		-n | --no-push) push=0 ;;
		-*) echo "lfrGitCheckoutTag: unknown flag '${a}'." >&2; return 1 ;;
		*)
			if [ -z "${tag}" ]; then
				tag="${a}"
			elif [ -z "${branch}" ]; then
				branch="${a}"
			else
				echo "lfrGitCheckoutTag: too many arguments (want <tag> [branch])." >&2
				return 1
			fi
			;;
		esac
	done
	if [ -z "${tag}" ]; then
		echo "lfrGitCheckoutTag: name the tag to check out, e.g. lfrGitCheckoutTag 2026.q1.8" >&2
		return 1
	fi
	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "lfrGitCheckoutTag: not inside a git repo" >&2
		return 1
	fi

	local remote
	remote="$(_lfrGitUpstreamRemote lfrGitCheckoutTag)" || return 1
	branch="${branch:-${tag}}"

	# Fetch the one tag ref into FETCH_HEAD: no destination refspec, so no local tag
	# is written, and --no-tags keeps git from dragging in every other tag that
	# points into the history it just downloaded.
	echo "Fetching ${tag} from ${remote}..."
	if ! git fetch --no-tags "${remote}" "refs/tags/${tag}"; then
		echo "  ${remote} has no tag ${tag}." >&2
		return 1
	fi

	local tag_commit branch_commit
	tag_commit="$(git rev-parse FETCH_HEAD)" || return 1

	# Every ref here is spelled out as refs/heads/<branch>, and the switch is
	# `git switch` rather than `git checkout`, because the branch is normally named
	# after the tag and the repo already holds that tag (79k of them in
	# liferay-portal-ee): a bare name resolves to the TAG first (rev-parse tries
	# refs/tags before refs/heads), and `git checkout <name>` warns that the refname
	# is ambiguous. `git switch` only ever resolves a branch.
	if git show-ref --verify -q "refs/heads/${branch}"; then
		branch_commit="$(git rev-parse "refs/heads/${branch}")"
		if [ "${branch_commit}" != "${tag_commit}" ]; then
			echo "  ${branch} already exists at $(git rev-parse --short "${branch_commit}"), not at ${tag} ($(git rev-parse --short "${tag_commit}")); checking it out as it is." >&2
			echo "  (to put it back on the tag: git reset --hard ${tag_commit})" >&2
		fi
		if [ "$(git symbolic-ref -q HEAD)" = "refs/heads/${branch}" ]; then
			echo "  already on ${branch}."
		else
			git switch "${branch}" || return 1
		fi
	else
		echo "  branching ${branch} off ${tag}..."
		git switch -c "${branch}" "${tag_commit}" || return 1
	fi

	if [ "${push}" = 1 ]; then
		local push_remote
		push_remote="$(_lfrGitPushRemote "${branch}" "${remote}")"
		echo "  pushing ${branch} to ${push_remote}..."
		git push -u "${push_remote}" "refs/heads/${branch}:refs/heads/${branch}"
	fi
}

# Short aliases.
lfrgc() { lfrGitClean "$@"; }
lfrgcd() { lfrGitCleanDry "$@"; }
lfrgs() { lfrGitSync "$@"; }
lfrgse() { lfrGitSyncEE "$@"; }
lfrgr() { lfrGitRebase "$@"; }
lfrgro() { lfrGitRebaseOnto "$@"; }
lfrgum() { lfrGitUpdateMaster "$@"; }
lfrgub() { lfrGitUpdateBranch "$@"; }
lfrgct() { lfrGitCheckoutTag "$@"; }
