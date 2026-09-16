# lfr-worktree.sh — create, rename and remove Liferay git worktrees (the lfrWorktree,
# lfrWorktreeRename, lfrWorktreeRemove, lfrWorktreeIdeaClean and lfrWorktreeIdeaInit
# commands).
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

# The PostgreSQL connection in $1's jdbc.default.url, as "host<TAB>port<TAB>user<TAB>
# password". The two database helpers below both need it before they can run a psql of
# their own, and neither can do anything with another engine, so a URL that is not
# PostgreSQL returns 1 and each of them says so in its own words.
_lfrWorktreeConnection() {
	local properties_file="${1}"
	local host password port url user

	url="$(sed -nE 's/^[[:space:]]*jdbc\.default\.url=(.*)$/\1/p' "${properties_file}" | head -1)"

	case "${url}" in
	jdbc:postgresql://*) ;;
	*) return 1 ;;
	esac

	host="$(printf '%s' "${url}" | sed -E 's#^jdbc:postgresql://([^:/]+).*#\1#')"
	port="$(printf '%s' "${url}" | sed -E 's#^jdbc:postgresql://[^:/]+:([0-9]+)/.*#\1#')"

	# The URL names no port, so the sed above matched nothing and echoed it back whole.
	if [ "${port}" = "${url}" ]; then
		port=5432
	fi

	user="$(sed -nE 's/^[[:space:]]*jdbc\.default\.username=(.*)$/\1/p' "${properties_file}" | head -1)"
	password="$(sed -nE 's/^[[:space:]]*jdbc\.default\.password=(.*)$/\1/p' "${properties_file}" | head -1)"

	printf '%s\t%s\t%s\t%s\n' "${host}" "${port}" "${user}" "${password}"
}

# Create the bundle's database when it is not there yet. Pointing jdbc.default.url at
# a name does not bring the database into being, so without this the first boot dies
# with `FATAL: database "portal-<suffix>" does not exist`. $1 is the properties file to
# read the connection from, $2 the database name, $3 the calling command, used only to
# prefix the messages, since lfrWorktreeRename creates one here too.
#
# Soft-fails on purpose: no psql, an unreachable server, or a non-PostgreSQL URL must
# report and move on rather than abort a worktree that is otherwise fine.
_lfrWorktreeCreateDatabase() {
	local properties_file="${1}" db_name="${2}"
	local caller="${3:-lfrWorktree}"
	local host password port user

	if ! IFS=$'\t' read -r host port user password < <(_lfrWorktreeConnection "${properties_file}"); then
		echo "${caller}: ${db_name} is not on PostgreSQL; create it yourself" >&2
		return 0
	fi

	if ! command -v psql >/dev/null 2>&1; then
		echo "${caller}: psql not found; create ${db_name} yourself" >&2
		return 0
	fi

	if PGPASSWORD="${password}" psql -h "${host}" -p "${port}" -U "${user}" -tAc \
			"select 1 from pg_database where datname = '${db_name}'" 2>/dev/null |
			grep -q 1; then
		echo "${caller}: database ${db_name} already exists" >&2

		return 0
	fi

	# template0 with an explicit encoding, so the new database does not inherit whatever
	# the cluster's template1 happens to carry.
	if PGPASSWORD="${password}" psql -h "${host}" -p "${port}" -U "${user}" -q -c \
			"create database \"${db_name}\" with encoding 'UTF8' lc_collate 'en_US.UTF-8' lc_ctype 'en_US.UTF-8' template template0" \
			2>/dev/null; then
		echo "${caller}: created database ${db_name}" >&2
	else
		echo "${caller}: could not create database ${db_name}; create it yourself" >&2
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

# Rename the bundle's database, so its name keeps saying which worktree it belongs to.
# $1 is the bundle's portal-ext.properties, which carries the connection and still names
# the old database, $2 the old name and $3 the new one. Returns 0 when the database was
# renamed, 2 when there was none to rename, and 1 when it could not be done, so the
# caller repoints jdbc.default.url on 0 and 2 and leaves it on the old name on 1.
#
# Soft-fails the way the creation above does, and for the same reason: a database this
# cannot reach is worth a line rather than a half-renamed worktree. PostgreSQL refuses to
# rename a database anything is connected to, which is the failure to expect here, so the
# message names that one.
_lfrWorktreeRenameDatabase() {
	local properties_file="${1}" old_db="${2}" new_db="${3}"
	local host password port user

	if ! IFS=$'\t' read -r host port user password < <(_lfrWorktreeConnection "${properties_file}"); then
		echo "lfrWorktreeRename: ${old_db} is not on PostgreSQL; rename it yourself" >&2

		return 1
	fi

	if ! command -v psql >/dev/null 2>&1; then
		echo "lfrWorktreeRename: psql not found; rename ${old_db} yourself" >&2

		return 1
	fi

	if ! PGPASSWORD="${password}" psql -h "${host}" -p "${port}" -U "${user}" -tAc \
			"select 1 from pg_database where datname = '${old_db}'" 2>/dev/null |
			grep -q 1; then
		echo "lfrWorktreeRename: there is no ${old_db} database to rename" >&2

		return 2
	fi

	if PGPASSWORD="${password}" psql -h "${host}" -p "${port}" -U "${user}" -q -c \
			"alter database \"${old_db}\" rename to \"${new_db}\"" 2>/dev/null; then
		echo "lfrWorktreeRename: renamed the database ${old_db} to ${new_db}, data and all" >&2

		return 0
	fi

	echo "lfrWorktreeRename: could not rename ${old_db}, which PostgreSQL refuses while anything is connected to it; left the bundle on ${old_db}" >&2

	return 1
}

# True while some IntelliJ still offers the project at $1, in either spelling a path is
# stored under. It is what decides whether a rename has any IntelliJ work to do: a
# worktree no IDE ever opened has no welcome-screen entry to move, and writing one for it
# would put a project there that was never wanted.
_lfrWorktreeIdeaLists() {
	local dir="${1}"
	local config_root="${XDG_CONFIG_HOME:-${HOME}/.config}/JetBrains"
	local -a keys=("${dir}")

	case "${dir}" in
	"${HOME}"/*) keys+=("\$USER_HOME\$/${dir#"${HOME}"/}") ;;
	esac

	local key recent
	for recent in "${config_root}"/*/options/recentProjects.xml; do
		[ -f "${recent}" ] || continue

		for key in "${keys[@]}"; do
			grep -qF "<entry key=\"${key}\">" "${recent}" && return 0
		done
	done

	return 1
}

_lfrWorktreeRenameHelp() {
	cat <<-'EOF'
		lfrWorktreeRename — rename a worktree, its branch, its bundle and its database.

		Usage:
		  lfrWorktreeRename <new>            rename the worktree you are standing in
		  lfrWorktreeRename <old> <new>      rename the worktree that has <old> checked out
		  lfrWorktreeRename <old> <new> --keep-database   leave the database named as it is

		Everything lfrWorktree wires under one name is moved to another, so a branch
		that turns out to be the wrong ticket costs a rename instead of a removal and
		a fresh build: the branch, the worktree directory (liferay-portal-<new>), the
		bundle directory (liferay-bundle-<new>), the bundle path in the worktree's
		per-user *.${USER}.properties, the database (portal-<new>, renamed with its
		data in it), and the project IntelliJ offers on its welcome screen. The build
		in the bundle is kept as it is, apart from osgi/state, which names the bundle's
		own absolute path everywhere and is deleted so the first boot rebuilds it.

		The old name is the worktree's own, read off its directory rather than off the
		branch, so a branch renamed by hand is brought back into line: give it the name
		the branch already has and the worktree, the bundle, its path in the per-user
		properties and the database move onto it, the branch itself staying put.

		It says what it is about to move and asks once before moving any of it, and
		refuses while a Tomcat runs out of that bundle, when another branch, the new
		directory or the new bundle directory already exists, and when every piece
		carries the name asked for already, which is the only nothing-to-do there is.

		The bundle and its database are left alone when the bundle is not this
		worktree's own: one shared by lfrShare, or one whose directory is named after
		neither the worktree nor the new name.

		IntelliJ only comes into it when it already lists the project, and then you get
		the same offer to close it lfrWorktreeRemove makes, since it writes its options
		back from memory on exit. Decline and the rename still happens, with the two
		commands that finish that half printed.

		Never touched: the remote branch, which keeps the old name until you push the
		new one yourself, and the database when --keep-database says so.
	EOF
}

# Rename what an lfrWorktree created, rather than removing it and building a fresh one:
# the branch, the worktree, the bundle, the database, and IntelliJ's project. All of it
# is a move, so nothing that took ten minutes to build is paid for twice.
#
# Usage:
#     lfrWorktreeRename LPD-54321                  # rename the worktree you are in
#     lfrWorktreeRename LPD-12345 LPD-54321        # rename that worktree
#     lfrWorktreeRename LPD-12345 LPD-54321 --keep-database
lfrWorktreeRename() {
	case "${1-}" in -h | --help) _lfrWorktreeRenameHelp; return 0 ;; esac

	local keep_database=""
	local -a names=()

	while [ "$#" -gt 0 ]; do
		case "${1}" in
		--keep-database)
			keep_database="--keep-database"
			;;
		-*)
			echo "lfrWorktreeRename: unknown option ${1}" >&2
			echo "usage: lfrWorktreeRename [<old-branch>] <new-branch> [--keep-database]" >&2

			return 1
			;;
		*)
			names+=("${1}")
			;;
		esac

		shift
	done

	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "lfrWorktreeRename: not inside a git repo" >&2

		return 1
	fi

	local new_branch="" old_branch=""

	case "${#names[@]}" in
	1)
		new_branch="${names[0]}"

		# The branch in hand, which is the whole point of the one-argument form: you find
		# out it is another ticket while standing in its worktree.
		old_branch="$(git rev-parse --abbrev-ref HEAD)" || return 1
		;;
	2)
		old_branch="${names[0]}"
		new_branch="${names[1]}"
		;;
	*)
		echo "usage: lfrWorktreeRename [<old-branch>] <new-branch> [--keep-database]" >&2

		return 1
		;;
	esac

	# A master-like branch is nobody's ticket, and a detached HEAD has no name to move.
	case "${old_branch}" in
	master* | */master)
		echo "lfrWorktreeRename: refusing to rename the master-like branch ${old_branch}" >&2

		return 1
		;;
	HEAD)
		echo "lfrWorktreeRename: HEAD is detached here; name the branch to rename" >&2

		return 1
		;;
	esac

	# Asked of git rather than guessed at, and asked here rather than found out by the
	# branch rename, which runs once the directories have already moved.
	if ! git check-ref-format "refs/heads/${new_branch}"; then
		echo "lfrWorktreeRename: ${new_branch} is not a name git will take for a branch" >&2

		return 1
	fi

	# Its own name is not a collision. A branch renamed by hand leaves the worktree, the
	# bundle and the database on the old ticket, and moving those onto it is the repair
	# this command is for, with the branch itself left where it already is.
	if [ "${old_branch}" != "${new_branch}" ] &&
		git show-ref --verify --quiet "refs/heads/${new_branch}"; then
		echo "lfrWorktreeRename: branch ${new_branch} already exists" >&2

		return 1
	fi

	# Found by the branch it has checked out rather than by its path, the way
	# lfrWorktreeRemove finds it. A worktree named by hand is found too, and comes out of
	# this named liferay-portal-<new>, which is the name lfrWorktree gives one and the
	# only name lfrWorktreeIdeaClean recognizes later.
	local dir
	dir="$(git worktree list --porcelain |
		awk -v branch="refs/heads/${old_branch}" '
			/^worktree /  { path = substr($0, 10) }
			$0 == "branch " branch { print path; exit }
		')"

	if [ -z "${dir}" ]; then
		echo "lfrWorktreeRename: no worktree has ${old_branch} checked out" >&2

		return 1
	fi

	# The first entry git lists is the main working tree, which is the clone itself: git
	# cannot move it, and its name is not a branch's to take.
	local main_root
	main_root="$(git worktree list --porcelain |
		awk '/^worktree / { print substr($0, 10); exit }')"

	if [ "${dir}" = "${main_root}" ]; then
		echo "lfrWorktreeRename: ${dir} is the clone itself, not a worktree of it" >&2

		return 1
	fi

	local new_suffix="${new_branch//\//-}"

	# The old name is read off the worktree directory rather than off the branch, because
	# the two disagree exactly when this is worth running: the directory, the bundle and
	# the database are named after whatever the worktree was created as, which a branch
	# renamed by hand leaves behind. A directory named by hand has no such name to read,
	# so there the branch is still it.
	local dir_name="${dir##*/}"
	local old_suffix="${old_branch//\//-}"

	case "${dir_name}" in
	liferay-portal-?*) old_suffix="${dir_name#liferay-portal-}" ;;
	esac

	local new_dir="${dir%/*}/liferay-portal-${new_suffix}"

	if [ "${new_dir}" != "${dir}" ] && [ -e "${new_dir}" ]; then
		echo "lfrWorktreeRename: ${new_dir} already exists" >&2

		return 1
	fi

	# Resolved while the worktree still stands where its properties say it does.
	local bundle_dir
	bundle_dir="$(cd "${dir}" && _lfrRepoBundleDir)" || bundle_dir=""

	# A bundle only moves when it is this worktree's own. One lfrShare pointed it at is
	# somebody else's, and one whose name does not follow the old branch was chosen by
	# hand, so renaming either would take a bundle this worktree does not own with it.
	local new_bundle_dir=""

	if [ -n "${bundle_dir}" ] && [ -d "${bundle_dir}" ]; then
		if [ -f "${dir}/app.server.${USER}.lfrshare-bak.properties" ]; then
			echo "lfrWorktreeRename: ${bundle_dir} is shared with this worktree by lfrShare; leaving the bundle alone" >&2
		elif [ "${bundle_dir##*/}" != "liferay-bundle-${old_suffix}" ] &&
			[ "${bundle_dir##*/}" != "liferay-bundle-${new_suffix}" ]; then
			echo "lfrWorktreeRename: ${bundle_dir} is not named after ${old_suffix}; leaving the bundle alone" >&2
		else
			new_bundle_dir="${bundle_dir%/*}/liferay-bundle-${new_suffix}"

			if [ "${new_bundle_dir}" != "${bundle_dir}" ] && [ -e "${new_bundle_dir}" ]; then
				echo "lfrWorktreeRename: ${new_bundle_dir} already exists" >&2

				return 1
			fi
		fi
	fi

	# Read even when --keep-database says it stays, so the plan below names the database
	# being kept rather than reporting none.
	local db="" new_db=""

	if [ -n "${new_bundle_dir}" ]; then
		db="$(_lfrWorktreeBundleDatabase "${bundle_dir}/portal-ext.properties")"

		if [ -z "${keep_database}" ]; then
			# Lowercased, the way the creation names one.
			new_db="portal-${new_suffix,,}"
		fi
	fi

	# Refused here rather than on the branch alone, since a branch that already carries
	# the name is not a worktree that does. Only once every piece carries it is there
	# nothing left to move.
	if [ "${old_branch}" = "${new_branch}" ] && [ "${new_dir}" = "${dir}" ] &&
		{ [ -z "${new_bundle_dir}" ] || [ "${new_bundle_dir}" = "${bundle_dir}" ]; } &&
		{ [ -z "${new_db}" ] || [ "${new_db}" = "${db}" ]; }; then
		echo "lfrWorktreeRename: ${new_branch} is already its name, and its worktree, bundle and database carry it too" >&2

		return 1
	fi

	# Extract each running catalina.base and compare, rather than grepping ps for the
	# bundle path: a pattern holding the path matches this very grep in the ps output.
	# The escaped dot is what keeps the extracting grep from matching itself too.
	local catalina_base
	while IFS= read -r catalina_base; do
		case "${catalina_base}" in
		"${bundle_dir}" | "${bundle_dir}"/*)
			echo "lfrWorktreeRename: a Tomcat is running out of ${bundle_dir}; stop it first" >&2

			return 1
			;;
		esac
	done < <([ -n "${bundle_dir}" ] && ps -eo args |
		grep --only-matching -- "-Dcatalina\.base=[^ ]*" | sed "s/-Dcatalina.base=//")

	local bundle_move="kept where it is" db_move="kept as it is" dir_move="kept where it is"

	if [ "${new_dir}" != "${dir}" ]; then
		dir_move="${new_dir}"
	fi

	if [ -n "${new_bundle_dir}" ] && [ "${new_bundle_dir}" != "${bundle_dir}" ]; then
		bundle_move="${new_bundle_dir}"
	fi

	if [ -n "${new_db}" ] && [ "${new_db}" != "${db}" ]; then
		db_move="${new_db}"
	fi

	if [ "${old_branch}" = "${new_branch}" ]; then
		echo "lfrWorktreeRename: ${new_branch} is the branch already; moving the rest onto it" >&2
	else
		echo "lfrWorktreeRename: ${old_branch} -> ${new_branch}" >&2
	fi

	echo "  Worktree : ${dir} -> ${dir_move}" >&2
	echo "  Bundle   : ${bundle_dir:-none} -> ${bundle_move}" >&2
	echo "  Database : ${db:-none} -> ${db_move}" >&2

	# Four moves in four places, so the plan above is put to you before any of them
	# happens. A run with no terminal goes ahead, since there is nobody to ask.
	if [ -t 0 ] && ! _lfrConfirm "lfrWorktreeRename: rename all of that?"; then
		echo "lfrWorktreeRename: nothing was renamed" >&2

		return 1
	fi

	# Asked before anything moves, the way lfrWorktreeRemove asks, because the answer can
	# be "let me close it myself first" and being asked that once the directory has moved
	# out from under the IDE is no use.
	local idea_clear="" idea_listed=""

	if [ "${new_dir}" != "${dir}" ] && _lfrWorktreeIdeaLists "${dir}"; then
		idea_listed=yes

		if _lfrWorktreeIdeaCloseOrRefuse lfrWorktreeRename; then
			idea_clear=yes
		fi
	fi

	if [ "${new_dir}" != "${dir}" ]; then
		if ! git worktree move "${dir}" "${new_dir}"; then
			echo "lfrWorktreeRename: could not move the worktree; nothing was renamed" >&2

			return 1
		fi

		echo "lfrWorktreeRename: moved the worktree to ${new_dir}" >&2

		# The shell is left standing in a directory that is not there any more when it
		# was inside the worktree, so follow the move. An empty * still matches, so the
		# worktree itself is covered as well as anything under it.
		case "${PWD}/" in
		"${dir}"/*) cd "${new_dir}" || return 1 ;;
		esac
	fi

	if [ "${old_branch}" != "${new_branch}" ]; then
		# Through the clone, since the shell may be standing in the directory that just
		# moved and git would have nothing to resolve from there.
		if ! git -C "${main_root}" branch -m "${old_branch}" "${new_branch}"; then
			echo "lfrWorktreeRename: the worktree moved but its branch is still ${old_branch}; rename it with git branch -m" >&2

			return 1
		fi

		echo "lfrWorktreeRename: renamed the branch to ${new_branch}" >&2
	fi

	if [ -n "${new_bundle_dir}" ] && [ "${new_bundle_dir}" != "${bundle_dir}" ]; then
		if ! mv "${bundle_dir}" "${new_bundle_dir}"; then
			echo "lfrWorktreeRename: could not move ${bundle_dir}; left the worktree pointing at it" >&2

			return 1
		fi

		echo "lfrWorktreeRename: moved the bundle to ${new_bundle_dir}" >&2

		# The same rewrite the creation does when it copies these in, so the worktree
		# keeps deploying into its own bundle under the bundle's new name.
		local f name
		local -a repointed=()

		for f in "${new_dir}"/*."${USER}".properties; do
			[ -f "${f}" ] || continue

			# Only the ones naming a bundle, so the message says what really moved: a
			# per-user file with no bundle path in it (build.${USER}.properties) is
			# untouched by this and has no business in that list.
			grep -q "bundles/liferay-bundle-" "${f}" || continue

			name="${f##*/}"

			sed -i -E "s#(bundles/liferay-bundle-)[^/[:space:]]+#\1${new_suffix}#g" "${f}" ||
				return 1

			repointed+=("${name}")
		done

		if [ "${#repointed[@]}" -gt 0 ]; then
			echo "lfrWorktreeRename: repointed the per-user config (bundle -> liferay-bundle-${new_suffix}): ${repointed[*]}" >&2
		fi

		# setenv.sh is the one file in a built bundle whose absolute paths can be
		# rewritten: the build writes the JaCoCo agent's jar and its destfile into it, one
		# under the bundle and one under the worktree, so both spellings move with the
		# rename. The rest of them are in osgi/state, which goes below.
		local setenv
		for setenv in "${new_bundle_dir}"/tomcat-*/bin/setenv.sh; do
			[ -f "${setenv}" ] || continue

			grep -qF "${bundle_dir}" "${setenv}" || grep -qF "${dir}" "${setenv}" || continue

			sed -i -e "s#${bundle_dir//./\\.}#${new_bundle_dir}#g" \
				-e "s#${dir//./\\.}#${new_dir}#g" "${setenv}" || return 1

			echo "lfrWorktreeRename: repointed the paths in ${setenv}" >&2
		done

		# The one part of a built bundle that cannot be repointed. osgi/state records the
		# absolute location of every module the framework resolved, and the Elasticsearch
		# sidecar's persisted process config with it, whose --module-path, -javaagent and
		# java.io.tmpdir all name the old directory; that one is a serialized Java object
		# rather than text, so there is nothing to sed. It is a cache the framework
		# rebuilds, so it goes instead, at the cost of a slower first boot. Measured on a
		# built bundle: 1.2G of it, holding 180 paths to the directory that just moved.
		local state_dir="${new_bundle_dir}/osgi/state"

		if [ -d "${state_dir}" ]; then
			local state_size
			state_size="$(du -sh "${state_dir}" | cut -f1)"

			rm -rf "${state_dir}" &&
				echo "lfrWorktreeRename: deleted the OSGi state ${state_dir} (${state_size}), which named the old bundle; the first boot rebuilds it" >&2
		fi
	fi

	if [ -n "${db}" ] && [ -n "${new_db}" ] && [ "${db}" != "${new_db}" ]; then
		local rc=0

		_lfrWorktreeRenameDatabase "${new_bundle_dir}/portal-ext.properties" "${db}" "${new_db}" ||
			rc="$?"

		if [ "${rc}" != 1 ]; then
			sed -i -E "s#^([[:space:]]*jdbc\.default\.url=jdbc:[a-z]+://[^/]+/)[^?[:space:]]+#\1${new_db}#" \
				"${new_bundle_dir}/portal-ext.properties" || return 1

			echo "lfrWorktreeRename: pointed the bundle at ${new_db}" >&2
		fi

		# Nothing to rename, so the bundle now names a database that has to be brought
		# into being, exactly as a fresh worktree's is.
		if [ "${rc}" = 2 ]; then
			_lfrWorktreeCreateDatabase "${new_bundle_dir}/portal-ext.properties" "${new_db}" \
				lfrWorktreeRename
		fi
	fi

	if [ -n "${idea_clear}" ]; then
		_lfrWorktreeRemoveIdeaProject "${dir}" lfrWorktreeRename
		_lfrWorktreeIdeaRecentProject "${new_dir}" lfrWorktreeRename
	elif [ -n "${idea_listed}" ]; then
		echo "lfrWorktreeRename: IntelliJ still lists ${dir}; once it is closed run lfrWorktreeIdeaClean, then lfrWorktreeIdeaInit ${new_branch} --recent" >&2
	fi

	# The remote is left alone: pushing the new name, and deleting the old one, are not
	# moves this command can take back for you.
	local upstream
	upstream="$(git -C "${new_dir}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"

	if [ -n "${upstream}" ] && [ "${old_branch}" != "${new_branch}" ]; then
		echo "lfrWorktreeRename: ${new_branch} still tracks ${upstream}; push it under its new name yourself" >&2
	fi
}

# Short aliases.
lfrw() { lfrWorktree "$@"; }
lfrwn() { lfrWorktreeRename "$@"; }
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

# Put $1 in IntelliJ's recent projects, so the worktree is one click away on the welcome
# screen. That is the only way in, in practice: File > Open reads the IDE's cached VFS,
# so a worktree created after IntelliJ last looked at the parent directory is missing
# from the chooser, its refresh button included, until the IDE restarts.
#
# Each IDE version keeps its own state, so this walks all of them, the way the clean
# above makes all of them forget a project. The entry is stamped with the current time
# because the list is ordered by activationTimestamp, and a worktree just created belongs
# at the top of it.
#
# A running IntelliJ gets the launcher line printed instead of an entry. recentProjects.xml
# is one of the files the IDE owns and writes back from memory when it closes, which is
# the same reason lfrWorktreeIdeaClean refuses to run while it is up, so an entry written
# underneath it would be gone before the restart that would show it. Opening the project
# once is the only registration a live IDE keeps, and whether to pay that project's first
# indexing pass now is yours to decide.
#
# $2 is the calling command, used only to prefix the messages, since lfrWorktreeRename
# registers a project here too.
_lfrWorktreeIdeaRecentProject() {
	local dir="${1}"
	local caller="${2:-lfrWorktreeIdeaInit}"
	local config_root="${XDG_CONFIG_HOME:-${HOME}/.config}/JetBrains"
	local config_dir idea key now pid recent tmp trailing_newline

	# A path under the home directory is stored through IntelliJ's $USER_HOME$ macro, so
	# write that form or the same project goes in twice, once under each spelling.
	key="${dir}"

	case "${dir}" in
	"${HOME}"/*) key="\$USER_HOME\$/${dir#"${HOME}"/}" ;;
	esac

	if _lfrWorktreeIdeaRunning; then
		pid="$(pgrep -x idea 2>/dev/null | head -1)"
		idea="$(tr '\0' '\n' <"/proc/${pid}/cmdline" 2>/dev/null | head -1)"

		[ -x "${idea}" ] || idea="idea"

		echo "${caller}: IntelliJ is running and would write its recent projects back over the entry, so open the project once instead, which needs no File > Open:" >&2
		echo "${caller}:   ${idea} ${dir}" >&2

		return 0
	fi

	now="$(($(date +%s) * 1000))"

	for recent in "${config_root}"/IntelliJIdea*/options/recentProjects.xml; do
		[ -f "${recent}" ] || continue

		config_dir="${recent%/options/recentProjects.xml}"

		if grep -qF "<entry key=\"${key}\">" "${recent}"; then
			echo "${caller}: ${config_dir##*/} already lists the project ${dir}" >&2

			continue
		fi

		# IntelliJ writes these files without a trailing newline, which awk's print would
		# add. tail strips newlines, so output here means the last byte is not one.
		trailing_newline=1

		if [ -n "$(tail -c 1 "${recent}")" ]; then
			trailing_newline=0
		fi

		tmp="$(mktemp)" || return 1

		awk -v key="${key}" -v now="${now}" -v title="${dir##*/}" '
			!inserted && /^[[:space:]]*<\/map>[[:space:]]*$/ {
				printf "        <entry key=\"%s\">\n", key
				print "          <value>"
				printf "            <RecentProjectMetaInfo frameTitle=\"%s\">\n", title
				printf "              <option name=\"activationTimestamp\" value=\"%s\" />\n", now
				print "              <option name=\"productionCode\" value=\"IU\" />"
				printf "              <option name=\"projectOpenTimestamp\" value=\"%s\" />\n", now
				print "            </RecentProjectMetaInfo>"
				print "          </value>"
				print "        </entry>"

				inserted = 1
			}

			{ print }

			END {
				exit !inserted
			}
		' "${recent}" >"${tmp}" || {
			rm -f "${tmp}"

			echo "${caller}: ${config_dir##*/} holds no recent projects map; left it alone" >&2

			continue
		}

		# The file is the live configuration of an IDE that is merely closed, so prove the
		# edit parses before it lands rather than after.
		if command -v python3 >/dev/null 2>&1 &&
			! python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])' "${tmp}" >/dev/null 2>&1; then
			rm -f "${tmp}"

			echo "${caller}: the edited ${recent} would not parse; left it alone" >&2

			return 1
		fi

		# Written back through the existing file to keep its mode and owner, the way the
		# entry removal above does.
		cat "${tmp}" >"${recent}" || {
			rm -f "${tmp}"

			return 1
		}

		rm -f "${tmp}"

		if [ "${trailing_newline}" -eq 0 ]; then
			truncate -s -1 "${recent}"
		fi

		echo "${caller}: ${config_dir##*/} now lists the project ${dir}" >&2
	done
}

_lfrWorktreeIdeaInitHelp() {
	cat <<-'EOF'
		lfrWorktreeIdeaInit — give a worktree the IntelliJ project a clone already has.

		Usage:
		  lfrWorktreeIdeaInit                       the worktree you are in
		  lfrWorktreeIdeaInit <branch|dir>          that worktree
		  lfrWorktreeIdeaInit <branch|dir> <src>    copy the project from that clone
		  lfrWorktreeIdeaInit <branch|dir> --redo   replace the project it already has
		  lfrWorktreeIdeaInit <branch|dir> --recent only the recent projects entry

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

		Last, the worktree goes into IntelliJ's recent projects, at the top of the
		welcome screen, because File > Open cannot reach it: that chooser reads the
		IDE's cached VFS, so a worktree created after IntelliJ last looked at the
		parent directory stays missing from the dialog, refresh button included, until
		the IDE restarts. Every IntelliJIdea* profile under ~/.config/JetBrains gets the
		entry, since each version keeps its own state, and the one already carrying the
		project is left alone.

		A running IntelliJ gets no entry, only the command to paste. It owns that file
		the same way it owns workspace.xml, writing it back from memory when it closes,
		so an entry written underneath it is gone before the restart that would show
		it. Opening the project once is the only registration a live IDE keeps, and
		that is the launcher line printed instead, so paying its first indexing pass
		then is your call rather than the tool's.

		--recent runs that last step alone, on a worktree whose project is already
		there. It is how a project you removed from the welcome screen comes back,
		since the alternative is a --redo, which wipes .idea and re-copies every .iml
		to write one line of XML. Close IntelliJ first, or it prints the launcher line
		and changes nothing, which is the same guard the full run obeys.
	EOF
}

lfrWorktreeIdeaInit() {
	case "${1-}" in -h | --help) _lfrWorktreeIdeaInitHelp; return 0 ;; esac

	local wt_root="${LFR_WORKTREE_ROOT:-${HOME}/liferay/repos}"
	local dir=""
	local recent=""
	local redo=""
	local src=""

	while [ "$#" -gt 0 ]; do
		case "${1}" in
		--recent)
			recent="--recent"
			;;
		--redo)
			redo="--redo"
			;;
		-*)
			echo "lfrWorktreeIdeaInit: unknown option ${1}" >&2
			echo "usage: lfrWorktreeIdeaInit [<branch|dir>] [<src>] [--redo|--recent]" >&2

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

	if [ -n "${recent}" ] && [ -n "${redo}" ]; then
		echo "lfrWorktreeIdeaInit: pass --redo or --recent, not both" >&2

		return 1
	fi

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

	# --recent is the whole run for a worktree already carrying its project, so it takes
	# neither a source nor anything the source is checked for.
	if [ -n "${recent}" ]; then
		dir="$(cd "${dir}" && pwd)" || return 1

		if [ ! -f "${dir}/.idea/modules.xml" ]; then
			echo "lfrWorktreeIdeaInit: ${dir} has no IntelliJ project yet; run it without --recent first" >&2

			return 1
		fi

		_lfrWorktreeIdeaRecentProject "${dir}"

		return
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

	_lfrWorktreeIdeaRunConfigurations "${src}" "${dir}" || return 1

	_lfrWorktreeIdeaRecentProject "${dir}"
}
