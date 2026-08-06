# lfr-worktree.sh — create and remove Liferay git worktrees (the lfrWorktree,
# lfrWorktreeRemove and lfrWorktreeIdeaClean commands).
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
# copied in and its JDBC URL pointed at a database of its own, which is created for
# you, so the two bundles never share one database.

# Create the bundle's database when it is not there yet. Pointing jdbc.default.url at
# a name does not bring the database into being, so without this the first boot dies
# with `FATAL: database "portal-<suffix>" does not exist`. $1 is the properties file to
# read the connection from, $2 the database name.
#
# Soft-fails on purpose: no psql, an unreachable server, or a non-PostgreSQL URL must
# report and move on rather than abort a worktree that is otherwise fine.
_lfrWorktreeCreateDatabase() {
	local properties_file="${1}" db_name="${2}"
	local host password port url user

	url="$(sed -nE 's/^[[:space:]]*jdbc\.default\.url=(.*)$/\1/p' "${properties_file}" | head -1)"

	case "${url}" in
	jdbc:postgresql://*) ;;
	*)
		echo "lfrWorktree: ${db_name} is not on PostgreSQL; create it yourself" >&2
		return 0
		;;
	esac

	if ! command -v psql >/dev/null 2>&1; then
		echo "lfrWorktree: psql not found; create ${db_name} yourself" >&2
		return 0
	fi

	host="$(printf '%s' "${url}" | sed -E 's#^jdbc:postgresql://([^:/]+).*#\1#')"
	port="$(printf '%s' "${url}" | sed -E 's#^jdbc:postgresql://[^:/]+:([0-9]+)/.*#\1#')"

	if [ "${port}" = "${url}" ]; then
		port=5432
	fi

	user="$(sed -nE 's/^[[:space:]]*jdbc\.default\.username=(.*)$/\1/p' "${properties_file}" | head -1)"
	password="$(sed -nE 's/^[[:space:]]*jdbc\.default\.password=(.*)$/\1/p' "${properties_file}" | head -1)"

	if PGPASSWORD="${password}" psql -h "${host}" -p "${port}" -U "${user}" -tAc \
			"select 1 from pg_database where datname = '${db_name}'" 2>/dev/null |
			grep -q 1; then
		echo "lfrWorktree: database ${db_name} already exists" >&2

		return 0
	fi

	# template0 with an explicit encoding, so the new database does not inherit whatever
	# the cluster's template1 happens to carry.
	if PGPASSWORD="${password}" psql -h "${host}" -p "${port}" -U "${user}" -q -c \
			"create database \"${db_name}\" with encoding 'UTF8' lc_collate 'en_US.UTF-8' lc_ctype 'en_US.UTF-8' template template0" \
			2>/dev/null; then
		echo "lfrWorktree: created database ${db_name}" >&2
	else
		echo "lfrWorktree: could not create database ${db_name}; create it yourself" >&2
	fi
}

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

		# Still make sure its database is there. A bundle configured by an earlier run
		# that predates database creation would otherwise stay broken forever.
		db_name="$(sed -nE 's#^[[:space:]]*jdbc\.default\.url=jdbc:[a-z]+://[^/]+/([^?[:space:]]+).*#\1#p' \
			"${dst_bundle}/portal-ext.properties" | head -1)"

		if [ -n "${db_name}" ]; then
			_lfrWorktreeCreateDatabase "${dst_bundle}/portal-ext.properties" "${db_name}"
		fi

		return 0
	fi

	# Lowercased so the database name needs no quoting outside the psql calls.
	db_name="portal-${bundle_suffix,,}"

	sed -E "s#^([[:space:]]*jdbc\.default\.url=jdbc:[a-z]+://[^/]+/)[^?[:space:]]+#\1${db_name}#" \
		"${src_bundle}/portal-ext.properties" >"${dst_bundle}/portal-ext.properties" || return 1

	echo "lfrWorktree: copied portal-ext.properties to ${dst_bundle} (database -> ${db_name})" >&2

	_lfrWorktreeCreateDatabase "${dst_bundle}/portal-ext.properties" "${db_name}"
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
			(portal-<branch>), which is created for you when PostgreSQL is reachable.
			Run from inside any liferay-portal clone.
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

# IntelliJ keeps a project's state outside the project directory, so removing a worktree
# leaves it behind: the Welcome screen still offers the path that is gone, and the
# project's index cache (6 MB for a Liferay worktree) stays on disk. The helpers below
# clear that state; the state that lives inside the worktree (.idea, *.iml) goes with it.
#
# A cache directory is named <project>.<hash>, where the hash is Java's String.hashCode
# of the project's absolute path in hex, so it is computed here rather than guessed by
# name. That matters: two projects can share a name (a liferay-portal clone plus another
# one on a second drive), and only the hash tells their caches apart.
_lfrWorktreeIdeaHash() {
	awk -v dir="${1}" 'BEGIN {
		for (i = 1; i < 128; i++) {
			code[sprintf("%c", i)] = i
		}

		for (i = 1; i <= length(dir); i++) {
			hash = (31 * hash + code[substr(dir, i, 1)]) % 4294967296
		}

		printf "%x\n", hash
	}'
}

# True while an IntelliJ is running. It rewrites its options from memory on exit, so an
# edit made now would be undone (and a forgotten project put back) the moment it closes.
# Matching escaped dots is what keeps the pattern from finding this very grep in the ps
# output.
_lfrWorktreeIdeaRunning() {
	ps -eo args | grep --quiet -- 'com\.intellij\.idea\.Main'
}

# Drop the map entry keyed by $2 from the IntelliJ options file $1, in both the shapes
# IntelliJ writes: a one-line self-closing entry (trusted-paths.xml) and a block ending
# at a </entry> indented like its opening tag (recentProjects.xml). Echoes the entry's
# projectWorkspaceId when it carries one, so the caller can delete that workspace file
# too. Returns 1 when the file has no such entry, so callers can skip in that case.
#
# The key is compared as a string instead of a pattern, since a project path holds regex
# metacharacters (liferay-portal-7.4.x), and the result is written back through the
# existing file to keep its mode and owner.
_lfrWorktreeRemoveIdeaEntry() {
	local file="${1}" key="${2}"
	local id tmp

	[ -f "${file}" ] || return 1

	# IntelliJ writes these files without a trailing newline, which awk's print would add.
	# tail strips newlines, so output here means the last byte is not one.
	local trailing_newline=1
	if [ -n "$(tail -c 1 "${file}")" ]; then
		trailing_newline=0
	fi

	tmp="$(mktemp)" || return 1

	if ! id="$(awk -v key="${key}" -v out="${tmp}" '
		function trim(line) {
			sub(/^[[:space:]]+/, "", line)
			sub(/[[:space:]]+$/, "", line)

			return line
		}

		BEGIN {
			opening = "<entry key=\"" key "\">"
			self_closing = "<entry key=\"" key "\" "
		}

		skip {
			if (match($0, /projectWorkspaceId="[^"]*"/)) {
				id = substr($0, RSTART + 20, RLENGTH - 21)
			}

			if ($0 == indent "</entry>") {
				skip = 0
			}

			next
		}

		{
			line = trim($0)

			if (line == opening) {
				match($0, /^[[:space:]]*/)

				indent = substr($0, 1, RLENGTH)
				removed = 1
				skip = 1

				next
			}

			if (line ~ /\/>$/ && substr(line, 1, length(self_closing)) == self_closing) {
				removed = 1

				next
			}

			print >out
		}

		END {
			print id

			exit removed ? 0 : 1
		}
	' "${file}")"; then
		rm -f "${tmp}"

		return 1
	fi

	cat "${tmp}" >"${file}" || {
		rm -f "${tmp}"

		return 1
	}

	rm -f "${tmp}"

	if [ "${trailing_newline}" -eq 0 ]; then
		truncate -s -1 "${file}"
	fi

	printf '%s\n' "${id}"
}

# Make every IntelliJ forget the project at $1 and delete its caches. $2 is the calling
# command, used only to prefix the messages. Each IDE version keeps its own state, so
# this walks all of them.
_lfrWorktreeRemoveIdeaProject() {
	local dir="${1}" caller="${2}"
	local config_root="${XDG_CONFIG_HOME:-${HOME}/.config}/JetBrains"
	local cache_root="${XDG_CACHE_HOME:-${HOME}/.cache}/JetBrains"
	local -a keys=("${dir}")

	# A path under the home directory is stored through IntelliJ's $USER_HOME$ macro, so
	# look for that form too.
	case "${dir}" in
	"${HOME}"/*) keys+=("\$USER_HOME\$/${dir#"${HOME}"/}") ;;
	esac

	local cache config_dir id key recent size
	for recent in "${config_root}"/*/options/recentProjects.xml; do
		[ -f "${recent}" ] || continue

		config_dir="${recent%/options/recentProjects.xml}"

		for key in "${keys[@]}"; do
			id="$(_lfrWorktreeRemoveIdeaEntry "${recent}" "${key}")" || continue

			echo "${caller}: ${config_dir##*/} forgot the project ${dir}" >&2

			# The workspace file holds the project's open editors, run configurations and
			# window layout, and is named by the id the entry carried.
			if [ -n "${id}" ]; then
				rm -f "${config_dir}/workspace/${id}.xml"
			fi

			_lfrWorktreeRemoveIdeaEntry "${config_dir}/options/trusted-paths.xml" "${key}" >/dev/null
		done
	done

	local hash
	hash="$(_lfrWorktreeIdeaHash "${dir}")"

	for cache in "${cache_root}"/*/projects/*."${hash}" \
		"${cache_root}"/*/log/indexing-diagnostic/*."${hash}"; do
		[ -d "${cache}" ] || continue

		size="$(du -sh "${cache}" | cut -f1)"

		rm -rf "${cache}" && echo "${caller}: deleted the IntelliJ cache ${cache} (${size})" >&2
	done
}

# List the worktree projects IntelliJ still offers whose directory is gone: the leftovers
# of a worktree removed by hand, by an older lfrWorktreeRemove, or while an IDE was open.
# Echoes one path per line.
#
# A missing directory alone is not enough to call a project a leftover, so three things
# have to hold. It sits directly in LFR_WORKTREE_ROOT, which is where lfrWorktree puts
# every worktree, so a deleted clone kept elsewhere is none of this command's business.
# Its name is one lfrWorktree makes (liferay-portal-<branch>), never a clone itself. And
# its parent is there, since with the Data drive unmounted every project on it is
# missing, and forgetting all of them over an unmounted drive is the one failure this
# command must not have.
_lfrWorktreeIdeaOrphans() {
	local config_root="${XDG_CONFIG_HOME:-${HOME}/.config}/JetBrains"
	local wt_root="${LFR_WORKTREE_ROOT:-${HOME}/liferay/repos}"

	[ -d "${wt_root}" ] || return 0

	local key recent
	for recent in "${config_root}"/*/options/recentProjects.xml; do
		[ -f "${recent}" ] || continue

		while IFS= read -r key; do
			key="${key/\$USER_HOME\$/${HOME}}"

			[ "${key%/*}" = "${wt_root}" ] || continue

			case "${key##*/}" in
			liferay-portal-?*) ;;
			*) continue ;;
			esac

			[ -e "${key}" ] && continue

			printf '%s\n' "${key}"
		done < <(sed -nE 's/^[[:space:]]*<entry key="([^"]+)">$/\1/p' "${recent}")
	done | sort -u
}

_lfrWorktreeIdeaCleanHelp() {
	cat <<-'EOF'
		lfrWorktreeIdeaClean — make IntelliJ forget worktree projects that are gone.

		Usage:
		  lfrWorktreeIdeaClean      for every liferay-portal-<branch> project in
		                            LFR_WORKTREE_ROOT whose directory no longer
		                            exists, remove it from the Welcome screen and
		                            delete its index cache
		  lfrWorktreeIdeaCleanDry   list those projects (removes nothing)

		lfrWorktreeRemove already does this for the worktree it removes, so this is
		for leftovers: a worktree removed by hand, or one removed while IntelliJ was
		running (it rewrites its options on exit, so nothing is touched then).
		Close IntelliJ before running it.
	EOF
}

lfrWorktreeIdeaCleanDry() {
	case "${1-}" in -h | --help) _lfrWorktreeIdeaCleanHelp; return 0 ;; esac

	local -a orphans=()
	mapfile -t orphans < <(_lfrWorktreeIdeaOrphans)

	if [ "${#orphans[@]}" -eq 0 ]; then
		echo "lfrWorktreeIdeaCleanDry: IntelliJ lists no worktree project that is gone" >&2

		return 0
	fi

	local orphan
	for orphan in "${orphans[@]}"; do
		printf '%s\n' "${orphan}"
	done
}

lfrWorktreeIdeaClean() {
	case "${1-}" in -h | --help) _lfrWorktreeIdeaCleanHelp; return 0 ;; esac

	if _lfrWorktreeIdeaRunning; then
		echo "lfrWorktreeIdeaClean: IntelliJ is running; close it first, or it will write the projects back on exit" >&2

		return 1
	fi

	local -a orphans=()
	mapfile -t orphans < <(_lfrWorktreeIdeaOrphans)

	if [ "${#orphans[@]}" -eq 0 ]; then
		echo "lfrWorktreeIdeaClean: IntelliJ lists no worktree project that is gone" >&2

		return 0
	fi

	local orphan
	for orphan in "${orphans[@]}"; do
		_lfrWorktreeRemoveIdeaProject "${orphan}" lfrWorktreeIdeaClean
	done
}

# Undo an lfrWorktree: remove the worktree, delete its branch, and delete the bundle
# dir that came with it, and make IntelliJ forget the project. Deliberately conservative,
# since all of it is destructive: it refuses while that bundle's Tomcat runs, keeps a
# bundle that holds more than the portal-ext.properties lfrWorktree put there (a built
# bundle is real work), and never touches the database — it prints the name so you can
# drop it yourself.
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

			Also makes IntelliJ forget the project (Welcome screen entry, trusted
			path, index cache), unless it is running, which lfrWorktreeIdeaClean
			then cleans up later. Refuses while the bundle's Tomcat is running.
			Never drops the database. Run from inside any liferay-portal clone.
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

	if _lfrWorktreeIdeaRunning; then
		echo "lfrWorktreeRemove: IntelliJ is running, so it still lists ${dir}; run lfrWorktreeIdeaClean once it is closed" >&2
	else
		_lfrWorktreeRemoveIdeaProject "${dir}" lfrWorktreeRemove
	fi

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
