# lfr-worktree.sh — create a Liferay git worktree (the lfrWorktree command).
#
# Worktree root and base ref come from the shared per-user config
# (LFR_WORKTREE_ROOT, LFR_WORKTREE_BASE), owned by LfrCommon/lfr-repo-list.sh.
#
# Usage:
#     lfrWorktree LPD-12345        # NEW worktree + branch LPD-12345 off upstream/master
#     lfrWorktree LPD-12345 hotfix # NEW branch off the given base ref (branch/remote/sha)
#     lfrWorktree hotfix           # branch hotfix EXISTS -> check it out in the worktree
#
# Run it from inside any liferay-portal clone; the worktree is created under
# LFR_WORKTREE_ROOT as a sibling named liferay-portal-<branch>. Whether the branch
# is new or existing, the invoking clone's per-user *.${USER}.properties (which are
# gitignored, so a fresh worktree has none) are copied into the worktree, with any
# bundle path repointed to bundles/liferay-bundle-<branch>, so this worktree deploys
# to / tests against its own bundle instead of clobbering the default one.

lfrWorktree() {
	case "${1-}" in
	-h | --help)
		cat <<-'EOF'
			lfrWorktree — create a git worktree for a branch, wired to its own bundle.

			Usage:
			  lfrWorktree <branch>          if <branch> exists, check it out; else create
			                                it off upstream/master
			  lfrWorktree <branch> <base>   create <branch> off the given base ref
			                                (a local branch, <remote>/<ref>, or a sha)

			The worktree is created next to your repos as liferay-portal-<branch> and
			you are moved into it. Your per-user *.${USER}.properties are copied in with
			the bundle repointed to bundles/liferay-bundle-<branch>. Run from inside any
			liferay-portal clone.
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

	local src_root
	src_root="$(git rev-parse --show-toplevel)" || return 1

	# The repos tree (where worktrees are created) is configurable via
	# LFR_WORKTREE_ROOT (set in LfrCommon/lfr-repo-list.sh, overridable per user);
	# create it if it does not exist so a freshly-configured tree works without a
	# manual mkdir.
	local wt_root="${LFR_WORKTREE_ROOT:-${HOME}/liferay/repos}"
	local dir="${wt_root}/liferay-portal-${branch}"

	if [ -e "${dir}" ]; then
		echo "lfrWorktree: ${dir} already exists" >&2
		return 1
	fi

	mkdir -p "${wt_root}" || {
		echo "lfrWorktree: cannot create worktree root ${wt_root}" >&2
		return 1
	}

	if git show-ref --verify --quiet "refs/heads/${branch}"; then
		# The branch already exists: check it out in the new worktree (git refuses
		# if it is already checked out elsewhere; relay that error). base is ignored.
		echo "lfrWorktree: branch ${branch} exists; checking it out in ${dir}..." >&2
		git worktree add "${dir}" "${branch}" || return 1
	else
		# New branch off the base ref. Only treat a "<a>/<b>" base as a remote ref
		# (and fetch to refresh it) when <a> is a real remote; otherwise it is a
		# local ref (e.g. a branch literally named feature/x), which must resolve.
		local remote="${base%%/*}"
		local ref="${base#*/}"
		if [ "${remote}" != "${base}" ] && git remote get-url "${remote}" >/dev/null 2>&1; then
			echo "lfrWorktree: fetching ${remote} ${ref}..." >&2
			git fetch "${remote}" "${ref}" || return 1
		elif ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
			echo "lfrWorktree: base ref '${base}' not found (not a local ref or <remote>/<ref>)" >&2
			return 1
		fi
		git worktree add -b "${branch}" "${dir}" "${base}" || return 1
	fi

	# Copy the invoking clone's per-user (gitignored) *.${USER}.properties into the
	# worktree, repointing any bundle path to liferay-bundle-<branch> so this
	# worktree targets its own bundle. Slashes in the branch become dashes in the
	# bundle dir name. Files with no bundle path are copied unchanged.
	local bundle_suffix="${branch//\//-}"
	local f name
	local -a copied=()
	for f in "${src_root}"/*."${USER}".properties; do
		[ -f "${f}" ] || continue
		name="$(basename "${f}")"
		sed -E "s#(bundles/liferay-bundle-)[^/[:space:]]+#\1${bundle_suffix}#g" \
			"${f}" >"${dir}/${name}" || return 1
		copied+=("${name}")
	done
	if [ "${#copied[@]}" -gt 0 ]; then
		echo "lfrWorktree: copied per-user config (bundle -> liferay-bundle-${bundle_suffix}): ${copied[*]}" >&2
	fi

	cd "${dir}" || return 1
}

# Short alias.
lfrw() { lfrWorktree "$@"; }
