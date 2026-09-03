# lfr-worktree.sh — create and remove Liferay git worktrees (the lfrWorktree,
# lfrWorktreeRemove, lfrWorktreeIdeaClean and lfrWorktreeIdeaInit commands).
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
# you, so the two bundles never share one database. A bundle already sitting there,
# which is what an lfrWorktreeRemove --keep-bundle leaves behind, is reported and you
# are asked whether to reuse it rather than adopted in silence.
#
# Last, it offers to run lfrWorktreeIdeaInit, since a fresh worktree has no IntelliJ
# project of its own. Set LFR_WORKTREE_IDEA to answer that in advance (1 runs it, 0
# skips it).

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

# The database name in a bundle's portal-ext.properties, read out of jdbc.default.url.
_lfrWorktreeBundleDatabase() {
	sed -nE 's#^[[:space:]]*jdbc\.default\.url=jdbc:[a-z]+://[^/]+/([^?[:space:]]+).*#\1#p' \
		"${1}" | head -1
}

# A bundle directory outlives its worktree after an lfrWorktreeRemove --keep-bundle, and
# recreating the worktree used to adopt it in silence: its portal-ext.properties was left
# alone however stale it had become, and its database was reused with the previous
# incarnation's data in it, so the fresh checkout booted on old data. Say what was found
# and let the answer decide. Returns 0 when the bundle is kept, 1 once it has been moved
# aside for a fresh one to take its place.
_lfrWorktreeKeepSurvivingBundle() {
	local src_bundle="${1}" dst_bundle="${2}"
	local aside database db_name drift properties size tomcat written

	db_name="$(_lfrWorktreeBundleDatabase "${dst_bundle}/portal-ext.properties")"

	# Counted by property rather than by diff line, so a property whose value changed
	# counts once instead of twice.
	drift="$(diff <(_lfrWorktreeBundleComparable "${src_bundle}/portal-ext.properties") \
		<(_lfrWorktreeBundleComparable "${dst_bundle}/portal-ext.properties") |
		sed -nE 's/^[<>][[:space:]]*([^=]+)=.*/\1/p' | sort -u | wc -l)"

	size="$(du -sh "${dst_bundle}" 2>/dev/null | cut -f1)"
	tomcat="$(ls -d "${dst_bundle}"/tomcat-* 2>/dev/null | head -1)"
	tomcat="${tomcat##*/}"
	written="$(date -r "${dst_bundle}/portal-ext.properties" '+%Y-%m-%d %H:%M' 2>/dev/null)"

	properties="properties"

	if [ "${drift}" = 1 ]; then
		properties="property"
	fi

	database="none named in its config"

	if [ -n "${db_name}" ]; then
		database="${db_name}, still holding that bundle's data"
	fi

	echo "lfrWorktree: ${dst_bundle} already holds a bundle from an earlier worktree" >&2
	echo "  Size     : ${size:-unknown}${tomcat:+, built (${tomcat})}" >&2
	echo "  Config   : portal-ext.properties written ${written:-unknown}, differs from ${src_bundle} in ${drift} ${properties}" >&2
	echo "  Database : ${database}" >&2

	# No terminal to ask at (a script, a pipe), so keep it, which is what every run before
	# this prompt existed did. The lines above are the warning that used to be missing.
	if [ ! -t 0 ]; then
		echo "lfrWorktree: keeping it, since there is no terminal to ask at" >&2

		return 0
	fi

	if _lfrConfirm "lfrWorktree: reuse it as it is? (n moves it aside and wires a fresh one)"; then
		return 0
	fi

	aside="${dst_bundle}.old-$(date '+%Y%m%d-%H%M%S')"

	# Keep it rather than delete it: it is only here because --keep-bundle asked for it,
	# and a failed move means the directory is still in place, so reuse is the answer.
	if ! mv "${dst_bundle}" "${aside}"; then
		echo "lfrWorktree: cannot move ${dst_bundle} aside; keeping it" >&2

		return 0
	fi

	echo "lfrWorktree: moved the old bundle to ${aside}" >&2

	if [ -n "${db_name}" ]; then
		echo "lfrWorktree: the ${db_name} database still holds its data; reset it with lfrBundle -c, or drop it with dropdb ${db_name}" >&2
	fi

	return 1
}

# A bundle's portal-ext.properties without the two properties that are meant to differ
# between bundles, sorted so a reordered file is not reported as drift. jdbc.default.url
# names the bundle's own database, and portal.instance.inet.socket.address is rewritten by
# start-liferay.sh on every launch with whichever port it claimed.
_lfrWorktreeBundleComparable() {
	grep -vE '^[[:space:]]*(jdbc\.default\.url|portal\.instance\.inet\.socket\.address)=' \
		"${1}" | sort
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

	if [ -e "${dst_bundle}/portal-ext.properties" ] &&
			_lfrWorktreeKeepSurvivingBundle "${src_bundle}" "${dst_bundle}"; then
		# Still make sure its database is there. A bundle configured by an earlier run
		# that predates database creation would otherwise stay broken forever.
		db_name="$(_lfrWorktreeBundleDatabase "${dst_bundle}/portal-ext.properties")"

		if [ -n "${db_name}" ]; then
			_lfrWorktreeCreateDatabase "${dst_bundle}/portal-ext.properties" "${db_name}"
		fi

		return 0
	fi

	# Recreate the directory, since the path that moves a surviving bundle aside leaves
	# nothing behind. A no-op on every other path, where the mkdir above made it.
	mkdir -p "${dst_bundle}" || return 1

	# Lowercased so the database name needs no quoting outside the psql calls.
	db_name="portal-${bundle_suffix,,}"

	sed -E "s#^([[:space:]]*jdbc\.default\.url=jdbc:[a-z]+://[^/]+/)[^?[:space:]]+#\1${db_name}#" \
		"${src_bundle}/portal-ext.properties" >"${dst_bundle}/portal-ext.properties" || return 1

	echo "lfrWorktree: copied portal-ext.properties to ${dst_bundle} (database -> ${db_name})" >&2

	_lfrWorktreeCreateDatabase "${dst_bundle}/portal-ext.properties" "${db_name}"
}

# A fresh worktree has nothing for IntelliJ to open, so offer lfrWorktreeIdeaInit once
# the worktree is wired and you are standing in it. It stays a command of its own because
# the copy takes about 17 seconds, which a worktree you only build from should not pay,
# so this asks rather than deciding either way. Set LFR_WORKTREE_IDEA to answer it in
# advance for a scripted run: 1 runs it, 0 skips it.
#
# Never fails the caller. The worktree is already made by the time this runs, so an
# IntelliJ project that did not get copied is worth a line, not a failed lfrWorktree.
_lfrWorktreeIdeaInitPrompt() {
	case "${LFR_WORKTREE_IDEA-}" in
	1 | [yY] | [yY][eE][sS])
		lfrWorktreeIdeaInit

		return 0
		;;
	0 | [nN] | [nN][oO])
		return 0
		;;
	esac

	# No terminal to ask at (a script, a pipe), so name the command instead of blocking on
	# a prompt nobody can answer.
	if [ ! -t 0 ]; then
		echo "lfrWorktree: run lfrWorktreeIdeaInit here to create the IntelliJ project" >&2

		return 0
	fi

	if ! _lfrConfirm "lfrWorktree: create the IntelliJ project too, with the debug profiles (about 17s)?"; then
		echo "lfrWorktree: skipped; run lfrWorktreeIdeaInit here when you want it" >&2

		return 0
	fi

	lfrWorktreeIdeaInit

	return 0
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

			Two questions, both answered y or n:

			A bundle dir already there (what lfrWorktreeRemove --keep-bundle leaves) is
			reported with its size, its config's age and drift, and its database, and you
			say whether to reuse it. Answer n and it is moved aside as <dir>.old-<stamp>
			and a fresh one is wired; its database is left for you to reset.

			Then whether to run lfrWorktreeIdeaInit, which gives the worktree the
			IntelliJ project and the debug profiles in about 17 seconds. Set
			LFR_WORKTREE_IDEA=1 to always run it, 0 to never ask.
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

	_lfrWorktreeIdeaInitPrompt
}

# IntelliJ keeps a project's state outside the project directory, so removing a worktree
# leaves it behind: the Welcome screen still offers the path that is gone, and around
# 26 MB of caches for a Liferay worktree stay on disk. The helpers below clear that
# state; the state that lives inside the worktree (.idea, *.iml) goes with it.
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
#
# Two shapes to catch. Up to 2024.1 the IDE is a JVM whose command line ends in
# com.intellij.idea.Main. From 2024.2 it is a native launcher that loads the JVM
# in-process, so that class name never reaches the process list at all and the launcher
# is only findable by its own name. Matching just the first left the guard dead on
# 2024.3, and a dead guard is worse than no guard: the clean reports success and the IDE
# writes every project back the moment it closes.
#
# pgrep -x goes on the process name rather than the command line, so a command that
# merely mentions the launcher's path cannot trip it. The grep can be tripped that way,
# and is left as it is regardless: a false positive only refuses the clean and says to
# close the IDE, while a false negative loses the work silently, so the two are not
# worth trading against each other.
#
# Matching escaped dots is what keeps the pattern from finding this very grep in the ps
# output.
_lfrWorktreeIdeaRunning() {
	pgrep -x idea >/dev/null 2>&1 && return 0

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

# Drop the path $2 from the "file.chooser.recent.files" list in the IntelliJ options
# file $1 (other.xml), which is the Open File dialog's own history and is not covered by
# the Welcome screen entry. Returns 1 when the list holds no such path.
#
# That list is JSON inside an XML text node, so dropping its last element would leave
# the new last one carrying a trailing comma, and IntelliJ would then fail to parse the
# whole file and lose every setting in it. The block is therefore buffered and its
# commas written afresh, rather than filtered a line at a time.
_lfrWorktreeRemoveIdeaRecentFile() {
	local file="${1}" key="${2}"
	local tmp

	[ -f "${file}" ] || return 1

	local trailing_newline=1
	if [ -n "$(tail -c 1 "${file}")" ]; then
		trailing_newline=0
	fi

	tmp="$(mktemp)" || return 1

	if ! awk -v key="${key}" -v out="${tmp}" '
		function trim(line) {
			sub(/^[[:space:]]+/, "", line)
			sub(/[[:space:]]+$/, "", line)

			return line
		}

		BEGIN {
			target = "&quot;" key "&quot;"
		}

		!inlist {
			print >out

			if (trim($0) == "&quot;file.chooser.recent.files&quot;: [") {
				inlist = 1
			}

			next
		}

		trim($0) ~ /^\]/ {
			for (i = 1; i <= n; i++) {
				print buffer[i] (i < n ? "," : "") >out
			}

			inlist = 0
			n = 0

			print >out

			next
		}

		{
			line = $0

			sub(/,[[:space:]]*$/, "", line)

			if (trim(line) == target) {
				removed = 1

				next
			}

			buffer[++n] = line
		}

		END {
			exit removed ? 0 : 1
		}
	' "${file}"; then
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

	# The task-management plugin keys its state by the project's directory name with
	# every non-alphanumeric turned into an underscore, the one piece of per-project
	# state addressable by neither the path nor the hash.
	local slug="${dir##*/}"
	slug="${slug//[^[:alnum:]]/_}"

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
			_lfrWorktreeRemoveIdeaRecentFile "${config_dir}/options/other.xml" "${key}"
		done

		rm -f "${config_dir}/tasks/${slug}.tasks.zip" "${config_dir}/tasks/${slug}.contexts.zip"
	done

	# Every per-project cache carries the hash in its own name, whatever directory it
	# sits in: projects, compiler, editor, fileHistory, conversion, frameworks/detection,
	# index/index-file-filters, index/dirty-file-queues, log/indexing-diagnostic,
	# Maven/Projects, semantic-search, testHistory, vcs-log, vcs-users, and whatever a
	# later IDE version adds. So match on the hash rather than listing the directories,
	# which is what used to leave index-file-filters behind, 3.5 MB a project and the
	# largest of them. -prune keeps the walk out of a cache already matched, so a file
	# inside one is never deleted on its own account.
	local hash
	hash="$(_lfrWorktreeIdeaHash "${dir}")"

	while IFS= read -r cache; do
		size="$(du -sh "${cache}" | cut -f1)"

		rm -rf "${cache}" && echo "${caller}: deleted the IntelliJ cache ${cache} (${size})" >&2
	done < <(find "${cache_root}" -maxdepth 6 -name "*${hash}*" -prune -print 2>/dev/null)
}

# Deal with a running IntelliJ before touching its state: offer to close it, and say
# what happens if it stays. $1 is the calling command, used to prefix the messages.
# Returns 0 when IntelliJ is not running any more and its state is safe to edit, 1 when
# it is still up and has to be left alone.
#
# Closing it is the useful answer rather than a courtesy. IntelliJ writes its options
# from memory on exit, so the only order that works is close, wait for it to be gone,
# then edit; an edit made first is undone the moment it closes. Waiting for the process
# to disappear is the whole barrier, since the write happens before the exit.
#
# SIGTERM, never SIGKILL: the IDE traps it and shuts down the way the menu item does,
# saving open files and flushing its state. A kill would lose exactly the state this is
# trying not to corrupt.
_lfrWorktreeIdeaCloseOrRefuse() {
	local caller="${1}"
	local pid waited
	local -a pids=()

	_lfrWorktreeIdeaRunning || return 0

	# No terminal to ask at (a script, a pipe), so fall back to the old refusal rather
	# than blocking on a prompt nobody can answer.
	if [ ! -t 0 ]; then
		echo "${caller}: IntelliJ is running; close it first, or it will write the projects back on exit" >&2

		return 1
	fi

	if ! _lfrConfirm "${caller}: IntelliJ is running and would write the projects back on exit. Close it now?"; then
		echo "${caller}: leaving IntelliJ alone; run lfrWorktreeIdeaClean once you close it" >&2

		return 1
	fi

	# The bracketed letter keeps the pattern from finding this very pgrep, the same
	# trick the detector uses with its escaped dots.
	mapfile -t pids < <({
		pgrep -x idea
		pgrep -f 'com\.intellij\.idea\.[M]ain'
	} | sort -u)

	if [ "${#pids[@]}" -eq 0 ]; then
		return 0
	fi

	echo "${caller}: asking IntelliJ to close (pid ${pids[*]})..." >&2

	for pid in "${pids[@]}"; do
		kill -TERM "${pid}" 2>/dev/null
	done

	waited=0
	while _lfrWorktreeIdeaRunning; do
		if [ "${waited}" -ge 60 ]; then
			echo "${caller}: IntelliJ is still up after 60s, most likely asking about unsaved work; finish that and run lfrWorktreeIdeaClean" >&2

			return 1
		fi

		sleep 1
		waited=$((waited + 1))
	done

	echo "${caller}: IntelliJ closed after ${waited}s" >&2
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

		When IntelliJ is running it offers to close it and waits for it to go,
		since that is the only order that works. Decline and nothing is touched.
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

	_lfrWorktreeIdeaCloseOrRefuse lfrWorktreeIdeaClean || return 1

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
# since all of it is destructive: it refuses while that bundle's Tomcat runs, keeps the
# bundle when --keep-bundle asks for it, and never touches the database — it prints the
# name so you can drop it yourself.
#
# Usage:
#     lfrWorktreeRemove LPD-12345               # remove the worktree, branch, bundle
#     lfrWorktreeRemove LPD-12345 --force       # also when the worktree is dirty or
#                                               # the branch is unmerged
#     lfrWorktreeRemove LPD-12345 --keep-bundle # leave the bundle dir in place
lfrWorktreeRemove() {
	case "${1-}" in
	-h | --help)
		cat <<-'EOF'
			lfrWorktreeRemove — remove a worktree, its branch, and its bundle.

			Usage:
			  lfrWorktreeRemove <branch>                remove the worktree, delete
			                                            the branch, and delete the
			                                            bundle dir, built or not
			  lfrWorktreeRemove <branch> --force        also when the worktree has
			                                            changes or the branch is
			                                            unmerged
			  lfrWorktreeRemove <branch> --keep-bundle  leave the bundle dir in
			                                            place

			The bundle goes with the worktree because it belongs to that checkout
			alone: with the worktree and the branch gone nothing can deploy into it
			again, and adopting a built bundle from another branch is a defect, not a
			saving. Pass --keep-bundle when the logs or the data are still wanted.

			Also makes IntelliJ forget the project: the Welcome screen entry, the
			trusted path, the Open File history, the task state, and every cache
			keyed by the project's path hash. When IntelliJ is running it offers
			to close it first, before anything is removed, since it would write
			the projects back on exit; decline and lfrWorktreeIdeaClean finishes
			that half later. Refuses while the bundle's Tomcat is running.
			Never drops the database; it prints the dropdb command instead. Run from
			inside any liferay-portal clone.
		EOF
		return 0
		;;
	esac

	local branch="${1}"

	if [ -z "${branch}" ]; then
		echo "usage: lfrWorktreeRemove <branch> [--force] [--keep-bundle]" >&2
		return 1
	fi

	shift

	local force=""
	local keep_bundle=""

	while [ "$#" -gt 0 ]; do
		case "${1}" in
		--force)
			force="--force"
			;;
		--keep-bundle)
			keep_bundle="--keep-bundle"
			;;
		*)
			echo "lfrWorktreeRemove: unknown option ${1}" >&2
			echo "usage: lfrWorktreeRemove <branch> [--force] [--keep-bundle]" >&2
			return 1
			;;
		esac

		shift
	done

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

	# Asked here, before anything is removed, because the answer can be "no, let me close
	# it myself first", and being asked that once the worktree is already gone is no use.
	local idea_clear=""
	if _lfrWorktreeIdeaCloseOrRefuse lfrWorktreeRemove; then
		idea_clear=yes
	fi

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

	if [ -n "${idea_clear}" ]; then
		_lfrWorktreeRemoveIdeaProject "${dir}" lfrWorktreeRemove
	else
		echo "lfrWorktreeRemove: IntelliJ still lists ${dir}; run lfrWorktreeIdeaClean once it is closed" >&2
	fi

	# The bundle belongs to this worktree alone, so it goes with it. A built one is
	# derived output, not work product: with the checkout and the branch gone nothing
	# can deploy into it again, and adopting it from another branch is a defect rather
	# than a saving, so keeping it only leaks its gigabytes silently. --keep-bundle is
	# there for the logs or the data. The database is the real exception, since
	# dropping one cannot be undone.
	if [ -z "${bundle_dir}" ] || [ ! -d "${bundle_dir}" ]; then
		return 0
	fi

	local bundle_size
	bundle_size="$(du -sh "${bundle_dir}" 2>/dev/null | cut -f1)"

	if [ -n "${keep_bundle}" ]; then
		echo "lfrWorktreeRemove: kept ${bundle_dir} (${bundle_size:-unknown size}) as asked" >&2
	else
		rm -rf "${bundle_dir}" || return 1
		echo "lfrWorktreeRemove: deleted the bundle ${bundle_dir} (${bundle_size:-unknown size})" >&2
	fi

	if [ -n "${db}" ]; then
		echo "lfrWorktreeRemove: left the ${db} database alone; drop it with dropdb ${db}" >&2
	fi
}

# Short aliases.
lfrw() { lfrWorktree "$@"; }
lfrwr() { lfrWorktreeRemove "$@"; }

# Write the source project's run configurations into $2/.idea/runConfigurations, one
# file each. That is IntelliJ's shared form, the one meant to travel with a project, so
# the configurations show up in the picker without anything being written into the
# workspace.xml the IDE owns and rewrites from memory.
#
# Three kinds are left out because they would not travel. A template (default="true")
# and a throwaway the IDE minted from a green arrow (temporary="true") are not
# configurations anyone chose. And a type starting with # is an application-server
# factory, Tomcat among them, whose APPLICATION_SERVER_NAME points at a server
# registered against the source clone's own bundle, so it would start the wrong one.
_lfrWorktreeIdeaRunConfigurations() {
	local src="${1}" dir="${2}"
	local out="${dir}/.idea/runConfigurations"
	local workspace="${src}/.idea/workspace.xml"
	local written

	[ -f "${workspace}" ] || return 0

	mkdir -p "${out}" || return 1

	written="$(awk -v out="${out}" '
		function trim(line) {
			sub(/^[[:space:]]+/, "", line)
			sub(/[[:space:]]+$/, "", line)

			return line
		}

		function emit(   file, slug) {
			if (keep) {
				slug = name

				gsub(/[^[:alnum:]]/, "_", slug)

				file = out "/" slug ".xml"

				printf "%s", header block footer >file

				close(file)

				if (!(slug in written)) {
					written[slug] = 1
					count++
				}
			}

			block = ""
		}

		BEGIN {
			header = "<component name=\"ProjectRunConfigurationManager\">\n"
			footer = "</component>\n"
		}

		# A <configuration> element does not belong to the run configurations alone: the
		# debugger writes its watch groups as one too. Only the RunManager component
		# holds the ones this is after.
		!inrunmanager {
			if ($0 ~ /<component name="RunManager"/) {
				match($0, /^[[:space:]]*/)

				component_close = substr($0, 1, RLENGTH) "</component>"
				inrunmanager = 1
			}

			next
		}

		$0 == component_close {
			inrunmanager = 0

			next
		}

		!block {
			if (trim($0) !~ /^<configuration[ >]/) {
				next
			}

			match($0, /^[[:space:]]*/)

			indent = substr($0, 1, RLENGTH)
			close_tag = indent "</configuration>"
			block = $0 "\n"
			keep = 1
			name = ""

			if ($0 ~ /default="true"/ || $0 ~ /temporary="true"/ || $0 ~ /type="#/) {
				keep = 0
			}

			if (match($0, /name="[^"]*"/)) {
				name = substr($0, RSTART + 6, RLENGTH - 7)
			}

			if (name == "") {
				keep = 0
			}

			if (trim($0) ~ /\/>$/) {
				emit()
			}

			next
		}

		{
			block = block $0 "\n"

			if ($0 == close_tag) {
				emit()
			}
		}

		END {
			print count + 0
		}
	' "${workspace}")" || return 1

	if [ "${written}" -eq 0 ]; then
		rmdir "${out}" 2>/dev/null

		echo "lfrWorktreeIdeaInit: ${src} has no run configuration to copy; point LFR_IDEA_TEMPLATE at the clone that has them" >&2

		return 0
	fi

	echo "lfrWorktreeIdeaInit: wrote ${written} run configurations to ${out}" >&2
}

_lfrWorktreeIdeaInitHelp() {
	cat <<-'EOF'
		lfrWorktreeIdeaInit — give a worktree the IntelliJ project a clone already has.

		Usage:
		  lfrWorktreeIdeaInit                     the worktree you are in
		  lfrWorktreeIdeaInit <branch|dir>        that worktree
		  lfrWorktreeIdeaInit <branch|dir> <src>  copy the project from that clone
		  lfrWorktreeIdeaInit <branch|dir> --redo replace the project it already has

		Copies the project model (modules.xml, libraries, code style, inspections,
		copyright) and every .iml, so the worktree opens as a configured project
		instead of a bare directory, and writes the source's run configurations into
		.idea/runConfigurations, which is what puts the Debugg profiles in the picker.
		All of it is path-independent: modules.xml is written in $PROJECT_DIR$ terms,
		the .iml files in $MODULE_DIR$ ones, and a Remote debug configuration holds
		nothing but a host and a port.

		Left out on purpose: the data sources and their cached schema, which point at
		the source bundle's database and are most of the size; the shelf, which holds
		the source clone's own shelved changes; and any run configuration bound to a
		registered application server (the Tomcat ones), since that registration names
		the source clone's bundle and would start the wrong one. Attach to your own
		bundle with Debugg portal 8000 instead, the port start-liferay.sh --debug
		takes first.

		The source defaults to LFR_IDEA_TEMPLATE, else liferay-portal in the worktree
		root. Set LFR_IDEA_TEMPLATE when the clone sitting in that root is not the one
		carrying the run configurations, which is the whole point of copying. The .iml
		files the target tracks in git keep the branch's own version, and every other
		one the source has is overwritten, so a --redo off a different clone really
		replaces the project. An .iml only the previous source had is left where it is,
		unreferenced by the new modules.xml and ignored. IntelliJ still indexes the
		project the first time it opens it.
	EOF
}

lfrWorktreeIdeaInit() {
	case "${1-}" in -h | --help) _lfrWorktreeIdeaInitHelp; return 0 ;; esac

	local wt_root="${LFR_WORKTREE_ROOT:-${HOME}/liferay/repos}"
	local dir=""
	local redo=""
	local src=""

	while [ "$#" -gt 0 ]; do
		case "${1}" in
		--redo)
			redo="--redo"
			;;
		-*)
			echo "lfrWorktreeIdeaInit: unknown option ${1}" >&2
			echo "usage: lfrWorktreeIdeaInit [<branch|dir>] [<src>] [--redo]" >&2

			return 1
			;;
		*)
			if [ -z "${dir}" ]; then
				dir="${1}"
			elif [ -z "${src}" ]; then
				src="${1}"
			else
				echo "lfrWorktreeIdeaInit: too many arguments" >&2

				return 1
			fi
			;;
		esac

		shift
	done

	src="${src:-${LFR_IDEA_TEMPLATE:-${wt_root}/liferay-portal}}"

	if [ -z "${dir}" ]; then
		if ! dir="$(git rev-parse --show-toplevel 2>/dev/null)"; then
			echo "lfrWorktreeIdeaInit: not inside a git repo; name the worktree" >&2

			return 1
		fi
	elif [ ! -d "${dir}" ]; then
		dir="${wt_root}/liferay-portal-${dir}"
	fi

	if [ ! -d "${dir}" ]; then
		echo "lfrWorktreeIdeaInit: ${dir} does not exist" >&2

		return 1
	fi

	if [ ! -f "${src}/.idea/modules.xml" ]; then
		echo "lfrWorktreeIdeaInit: ${src} has no IntelliJ project to copy" >&2

		return 1
	fi

	dir="$(cd "${dir}" && pwd)" || return 1
	src="$(cd "${src}" && pwd)" || return 1

	if [ "${dir}" = "${src}" ]; then
		echo "lfrWorktreeIdeaInit: ${dir} is the source; name another worktree" >&2

		return 1
	fi

	if [ -f "${dir}/.idea/modules.xml" ]; then
		if [ -z "${redo}" ]; then
			echo "lfrWorktreeIdeaInit: ${dir} already has an IntelliJ project; pass --redo to replace it" >&2

			return 1
		fi

		rm -rf "${dir}/.idea" || return 1

		echo "lfrWorktreeIdeaInit: replacing the project already in ${dir}" >&2
	fi

	mkdir -p "${dir}/.idea" || return 1

	# --ignore-existing so the few .idea files the repo tracks keep the branch's own
	# version. The excludes are the state that belongs to the source clone alone, and
	# workspace.xml with them: the run configurations worth having are pulled out of it
	# below, and the rest of it is that clone's open editors and window layout.
	echo "lfrWorktreeIdeaInit: copying the project model from ${src}..." >&2

	rsync --archive --ignore-existing \
		--exclude=dataSources --exclude='dataSources*.xml' --exclude=easycode \
		--exclude=shelf --exclude=workspace.xml \
		"${src}/.idea/" "${dir}/.idea/" || return 1

	echo "lfrWorktreeIdeaInit: copied the project model into ${dir}/.idea" >&2

	# modules.xml is nothing without the .iml files it points at, and only a handful of
	# them are tracked, so a fresh worktree has almost none. The tracked ones are held
	# out of the copy so they keep the branch's own version; everything else is
	# overwritten, which is what makes a --redo off a different clone a real replacement
	# rather than a merge of the two.
	local list tracked
	list="$(mktemp)" || return 1
	tracked="$(mktemp)" || return 1

	git -C "${dir}" ls-files '*.iml' 2>/dev/null | sort >"${tracked}"

	# Walking a Liferay tree for these takes the best part of a minute, and a run that
	# says nothing for that long reads as a hang, so say what is happening first.
	echo "lfrWorktreeIdeaInit: scanning ${src} for .iml files (the slow part)..." >&2

	(cd "${src}" && find . -name '*.iml' -not -path '*/node_modules/*' -printf '%P\n') |
		sort | comm -23 - "${tracked}" >"${list}"

	if [ -s "${list}" ]; then
		echo "lfrWorktreeIdeaInit: copying $(wc -l <"${list}") .iml files..." >&2

		tar --create --directory="${src}" --files-from="${list}" --file=- |
			tar --extract --directory="${dir}" --file=- || {
			rm -f "${list}" "${tracked}"

			return 1
		}

		echo "lfrWorktreeIdeaInit: copied $(wc -l <"${list}") .iml files" >&2
	fi

	rm -f "${list}" "${tracked}"

	_lfrWorktreeIdeaRunConfigurations "${src}" "${dir}"
}
