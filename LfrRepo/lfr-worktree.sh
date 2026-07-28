# lfr-worktree.sh — create and remove Liferay git worktrees (the lfrWorktree and
# lfrWorktreeRemove commands).
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
#
# That bundle dir is created too, with the invoking bundle's portal-ext.properties
# copied in and its JDBC URL pointed at a database of its own, so the two bundles
# never share one database.

# Give the worktree's bundle its own portal-ext.properties on its own database.
# $1 is the invoking clone's root, $2 the new worktree, $3 the bundle suffix.
# Resolves both bundle dirs the way `ant all` does (_lfrRepoBundleDir), creates the
# new one, and copies portal-ext.properties across with jdbc.default.url pointed at
# portal-<suffix>. Leaves an existing portal-ext.properties alone.
_lfrWorktreeBundleConfig() {
	local src_root="${1}" dir="${2}" bundle_suffix="${3}"
	local src_bundle dst_bundle db_name

	src_bundle="$(cd "${src_root}" && _lfrRepoBundleDir)" || return 0
	dst_bundle="$(cd "${dir}" && _lfrRepoBundleDir)" || return 0

	if [ ! -f "${src_bundle}/portal-ext.properties" ]; then
		echo "lfrWorktree: no portal-ext.properties in ${src_bundle}; nothing to copy" >&2
		return 0
	fi

	mkdir -p "${dst_bundle}" || return 1

	# _lfrRepoBundleDir can only canonicalize a bundle dir that already exists, so
	# canonicalize here now that it does, keeping the messages below readable.
	dst_bundle="$(cd "${dst_bundle}" && pwd)" || return 1

	if [ -e "${dst_bundle}/portal-ext.properties" ]; then
		echo "lfrWorktree: ${dst_bundle}/portal-ext.properties exists; leaving it alone" >&2
		return 0
	fi

	# Lowercased so the database name needs no quoting outside the psql calls.
	db_name="portal-${bundle_suffix,,}"

	sed -E "s#^([[:space:]]*jdbc\.default\.url=jdbc:[a-z]+://[^/]+/)[^?[:space:]]+#\1${db_name}#" \
		"${src_bundle}/portal-ext.properties" >"${dst_bundle}/portal-ext.properties" || return 1

	echo "lfrWorktree: copied portal-ext.properties to ${dst_bundle} (database -> ${db_name})" >&2
}

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
			the bundle repointed to bundles/liferay-bundle-<branch>. That bundle dir is
			created with your portal-ext.properties copied in, on a database of its own
			(portal-<branch>). Run from inside any liferay-portal clone.
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

	_lfrWorktreeBundleConfig "${src_root}" "${dir}" "${bundle_suffix}"

	cd "${dir}" || return 1
}

# Undo an lfrWorktree: remove the worktree, delete its branch, and delete the bundle
# dir that came with it. Deliberately conservative, since all three are destructive:
# it refuses while that bundle's Tomcat runs, keeps a bundle that holds more than the
# portal-ext.properties lfrWorktree put there (a built bundle is real work), and never
# touches the database — it prints the name so you can drop it yourself.
#
# Usage:
#     lfrWorktreeRemove LPD-12345         # remove the worktree, branch, stub bundle
#     lfrWorktreeRemove LPD-12345 --force # also when the worktree is dirty or the
#                                         # branch is unmerged
lfrWorktreeRemove() {
	case "${1-}" in
	-h | --help)
		cat <<-'EOF'
			lfrWorktreeRemove — remove a worktree, its branch, and its bundle.

			Usage:
			  lfrWorktreeRemove <branch>          remove the worktree, delete the
			                                      branch, and delete the bundle dir
			                                      when it holds nothing but the
			                                      portal-ext.properties lfrWorktree
			                                      created
			  lfrWorktreeRemove <branch> --force  also when the worktree has changes
			                                      or the branch is unmerged

			Refuses while the bundle's Tomcat is running. Never drops the database.
			Run from inside any liferay-portal clone.
		EOF
		return 0
		;;
	esac

	local branch="${1}"
	local force="${2:-}"

	if [ -z "${branch}" ]; then
		echo "usage: lfrWorktreeRemove <branch> [--force]" >&2
		return 1
	fi

	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "lfrWorktreeRemove: not inside a git repo" >&2
		return 1
	fi

	# A master-like branch is never a disposable worktree; refuse before anything else.
	case "${branch}" in
	master* | *master)
		echo "lfrWorktreeRemove: refusing to remove the master-like branch ${branch}" >&2
		return 1
		;;
	esac

	if [ "${branch}" = "$(git rev-parse --abbrev-ref HEAD)" ]; then
		echo "lfrWorktreeRemove: ${branch} is checked out here; run this from another worktree" >&2
		return 1
	fi

	# Find the worktree by the branch it has checked out rather than by guessing the
	# path, so a worktree named by hand is still found.
	local dir
	dir="$(git worktree list --porcelain |
		awk -v branch="refs/heads/${branch}" '
			/^worktree /  { path = substr($0, 10) }
			$0 == "branch " branch { print path; exit }
		')"

	if [ -z "${dir}" ]; then
		echo "lfrWorktreeRemove: no worktree has ${branch} checked out" >&2
		return 1
	fi

	# Resolve the bundle while the worktree's properties still exist.
	local bundle_dir
	bundle_dir="$(cd "${dir}" && _lfrRepoBundleDir)" || bundle_dir=""

	local db=""
	if [ -f "${bundle_dir}/portal-ext.properties" ]; then
		db="$(sed -nE 's/^[[:space:]]*jdbc\.default\.url=//p' "${bundle_dir}/portal-ext.properties" | tail -n 1)"
		db="${db%%\?*}"
		db="${db##*/}"
	fi

	# Extract each running catalina.base and compare, rather than grepping ps for the
	# bundle path: a pattern holding the path matches this very grep in the ps output.
	# The escaped dot is what keeps the extracting grep from matching itself too.
	local catalina_base
	while IFS= read -r catalina_base; do
		case "${catalina_base}" in
		"${bundle_dir}" | "${bundle_dir}"/*)
			echo "lfrWorktreeRemove: a Tomcat is running out of ${bundle_dir}; stop it first" >&2
			return 1
			;;
		esac
	done < <([ -n "${bundle_dir}" ] && ps -eo args |
		grep --only-matching -- "-Dcatalina\.base=[^ ]*" | sed "s/-Dcatalina.base=//")

	if [ "${force}" = "--force" ]; then
		git worktree remove --force "${dir}" || return 1
		git branch -D "${branch}" || return 1
	else
		git worktree remove "${dir}" || {
			echo "lfrWorktreeRemove: worktree has changes; rerun with --force to discard them" >&2
			return 1
		}
		git branch -d "${branch}" || {
			echo "lfrWorktreeRemove: ${branch} is unmerged; rerun with --force to delete it anyway" >&2
			return 1
		}
	fi

	echo "lfrWorktreeRemove: removed worktree ${dir} and branch ${branch}" >&2

	# Only the stub lfrWorktree created is disposable. Anything else (a built bundle,
	# its data, its logs) stays, whatever --force says: it is not this command's work.
	if [ -z "${bundle_dir}" ] || [ ! -d "${bundle_dir}" ]; then
		return 0
	fi

	local -a entries=()
	mapfile -t entries < <(ls -A "${bundle_dir}")

	if [ "${#entries[@]}" -eq 0 ] ||
		{ [ "${#entries[@]}" -eq 1 ] && [ "${entries[0]}" = portal-ext.properties ]; }; then
		rm -rf "${bundle_dir}" || return 1
		echo "lfrWorktreeRemove: deleted the unused bundle ${bundle_dir}" >&2
	else
		echo "lfrWorktreeRemove: kept ${bundle_dir}; it holds a built bundle, delete it yourself" >&2
	fi

	if [ -n "${db}" ]; then
		echo "lfrWorktreeRemove: left the ${db} database alone" >&2
	fi
}

# Short aliases.
lfrw() { lfrWorktree "$@"; }
lfrwr() { lfrWorktreeRemove "$@"; }
