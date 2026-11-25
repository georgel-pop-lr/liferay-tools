# lfr-worktree.sh - create, rename and remove Liferay git worktrees (the lfrWorktree,
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
# LFR_WORKTREE_ROOT as one folder named liferay-portal-<branch>, which holds the
# checkout (portal/) and its bundle (bundles/). Whether the branch is new or existing,
# the invoking clone's per-user *.${USER}.properties (which are gitignored, so a fresh
# worktree has none) are copied into the checkout, pointed at that bundles/ folder, so
# this worktree deploys to / tests against its own bundle instead of clobbering the
# default one.
#
# That bundle dir is created too, with the invoking bundle's portal-ext.properties
# copied in and its JDBC URL pointed at a database of its own, which is created for
# you, so the two bundles never share one database. A bundle already sitting there,
# which is what an lfrWorktreeRemove --keep-bundle leaves behind, is reported and you
# are asked whether to reuse it rather than adopted in silence.
#
# When a clean source clone in LFR_WORKTREE_SOURCES has a stamped build in the base
# (lfrAntAll), the branch is cut from that commit and the built bundle and the build state
# of the clone are copied in, so the worktree needs no `ant all`. lfrWorktreeCopyBundle
# does the same for an existing worktree.
#
# When the invoking clone shares the Gradle build cache (lfrCache on), the worktree
# shares it too, so its first build reuses what the clones built.
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

	if PGPASSWORD="${password}" _lfrStep "Check the database ${db_name}" psql -h "${host}" -p "${port}" -U "${user}" -tAc \
			"select 1 from pg_database where datname = '${db_name}'" 2>/dev/null |
			grep -q 1; then
		echo "${caller}: database ${db_name} already exists" >&2

		return 0
	fi

	# template0 with an explicit encoding, so the new database does not inherit whatever
	# the cluster's template1 happens to carry.
	if PGPASSWORD="${password}" _lfrStep "Create the database ${db_name}" psql -h "${host}" -p "${port}" -U "${user}" -q -c \
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
		echo "lfrWorktree: the ${db_name} database still holds its data; reset it with lfrBundles -c, or drop it with dropdb ${db_name}" >&2
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

# The value of key $2 in the build stamp $1 that lfrAntAll writes (_lfrAntStampBuild).
_lfrWorktreeStampValue() {
	sed -n "s/^${2}=//p" "${1}" 2>/dev/null | head -1
}

# Echo the commit that the bundle of the source clone $1 holds, when a worktree can copy
# it: lfrAntAll stamped it from a clean tree, and nothing was deployed into the bundle or
# installed into the clone's .m2 after that. Otherwise say why on stderr and return 1.
_lfrWorktreeSourceCommit() {
	local src="${1}"
	local bundle commit newer stamp

	bundle="$(cd "${src}" 2>/dev/null && _lfrRepoBundleDir)" || {
		echo "lfrWorktree: ${src}: cannot resolve its bundle" >&2
		return 1
	}

	stamp="${bundle}/${_LFR_BUILD_STAMP}"

	if [ ! -f "${stamp}" ]; then
		echo "lfrWorktree: ${src}: its bundle has no build stamp; run lfrAntAll there" >&2
		return 1
	fi

	commit="$(_lfrWorktreeStampValue "${stamp}" commit)"

	if [ "$(_lfrWorktreeStampValue "${stamp}" clean)" != 1 ]; then
		echo "lfrWorktree: ${src}: the build of ${commit:0:13} ran on a tree with local changes" >&2
		return 1
	fi

	newer="$(find "${bundle}/osgi" "${bundle}"/tomcat-*/webapps "${src}/.m2" \
		-path "${bundle}/osgi/state" -prune -o \
		-type f \( -name '*.jar' -o -name '*.war' \) -newer "${stamp}" -print -quit 2>/dev/null)"

	if [ -n "${newer}" ]; then
		echo "lfrWorktree: ${src}: changed after the build of ${commit:0:13}: ${newer}" >&2
		return 1
	fi

	printf '%s\n' "${commit}"
}

# Echo "<clone><TAB><commit>" for the build that a branch at the ref $1 can use: a source
# clone with a valid stamp (_lfrWorktreeSourceCommit) whose commit is $1 or an ancestor of
# it, in the repo of the current directory. Any source counts, not only the clone of the
# same line, so while master, brian master, and EE master are on one commit, one build
# serves them all. The newest build wins. With $2, only that clone is tried. When no build
# fits, print why for each source and return 1.
_lfrWorktreeSourcePick() {
	local target="${1}" only="${2-}"
	local best="" best_commit="" best_count="" commit count out src
	local -a reasons=() sources=("${LFR_WORKTREE_SOURCES[@]}")

	if [ -n "${only}" ]; then
		sources=("${only}")
	fi

	for src in "${sources[@]}"; do
		[ -d "${src}" ] || continue

		if ! out="$(_lfrWorktreeSourceCommit "${src}" 2>&1)"; then
			reasons+=("${out}")
			continue
		fi

		commit="${out}"

		# The commit must be in this repo too, which another clone may not share.
		if ! git cat-file -e "${commit}^{commit}" 2>/dev/null; then
			_lfrStep "Fetch the build commit from ${src}" git fetch --quiet --no-tags "${src}" "$(git -C "${src}" branch --show-current)" 2>/dev/null ||
				true
		fi

		if ! git merge-base --is-ancestor "${commit}" "${target}" 2>/dev/null; then
			reasons+=("lfrWorktree: ${src}: its build ${commit:0:13} is not in ${target}")
			continue
		fi

		count="$(git rev-list --count "${commit}..${target}")"

		if [ -z "${best}" ] || [ "${count}" -lt "${best_count}" ]; then
			best="${src}" best_commit="${commit}" best_count="${count}"
		fi
	done

	if [ -z "${best}" ]; then
		[ "${#reasons[@]}" -gt 0 ] && printf '%s\n' "${reasons[@]}" >&2

		return 1
	fi

	if [ "${best_count}" -gt 0 ]; then
		echo "lfrWorktree: the build ${best_commit:0:13} of ${best} is ${best_count} commits behind ${target}; refresh that clone and run lfrAntAll there when you need the newer code" >&2
	fi

	printf '%s\t%s\n' "${best}" "${best_commit}"
}

# Copy the built bundle of the source clone $1 into the bundle of the worktree $2, and
# the build state of the clone that a module deploy needs. The new bundle keeps its own
# portal-ext.properties and database (_lfrWorktreeBundleConfig) and gets no data, logs,
# OSGi state, or Tomcat work of the source, since those belong to the source database.
# With $3 = replace, a bundle that already holds a Tomcat gets the build of the source in
# place of its own, and keeps its data, logs, and database (lfrWorktreeCopyBundle).
_lfrWorktreeCopyBundle() {
	local src="${1}" dir="${2}" mode="${3-}"
	local commit dst_bundle sidecar src_bundle src_real t

	src_bundle="$(cd "${src}" && _lfrRepoBundleDir)" || return 1
	dst_bundle="$(cd "${dir}" && _lfrRepoBundleDir)" || return 1
	src_real="$(cd "${src}" && pwd -P)" || return 1

	local -a delete=()

	if ls -d "${dst_bundle}"/tomcat-* >/dev/null 2>&1; then
		if [ "${mode}" != replace ]; then
			echo "lfrWorktree: ${dst_bundle} already holds a Tomcat; not copied" >&2
			return 0
		fi

		# The old build goes: a Tomcat of another version, the OSGi state and the JSP
		# cache of the old modules, and each file of the old build that the source has
		# not (--delete). What rsync excludes stays, so the data and the logs stay.
		for t in "${dst_bundle}"/tomcat-*/; do
			t="$(basename "${t}")"

			if [ -d "${src_bundle}/${t}" ]; then
				rm -rf "${dst_bundle:?}/${t}/temp" "${dst_bundle:?}/${t}/work"
			else
				rm -rf "${dst_bundle:?}/${t}"
			fi
		done

		rm -rf "${dst_bundle:?}/osgi/state"
		delete=(--delete)
	fi

	echo "lfrWorktree: copying the bundle ${src_bundle} -> ${dst_bundle}..." >&2

	_lfrStep "Copy the bundle ${src_bundle}" rsync -a "${delete[@]}" \
		--include=/data/ --include='/data/license/***' --exclude='/data/*' \
		--exclude=/deploy/ --exclude=/elasticsearch-sidecar/ --exclude=/glowroot/data/ \
		--exclude=/logs/ --exclude=/osgi/state/ --exclude=/reports/ \
		--exclude='/tomcat-*/logs/' --exclude='/tomcat-*/temp/' --exclude='/tomcat-*/work/' \
		--exclude='/*.bak*' --exclude='/*.log' --exclude='/*.zip' \
		--exclude='/portal-ext.properties*' --exclude=/portal-setup-wizard.properties \
		"${src_bundle}/" "${dst_bundle}/" || return 1

	mkdir -p "${dst_bundle}/data" "${dst_bundle}/deploy" "${dst_bundle}/logs"

	# Only the Elasticsearch sidecar that this commit runs, not each old one (about 1 GB each).
	commit="$(_lfrWorktreeStampValue "${src_bundle}/${_LFR_BUILD_STAMP}" commit)"
	sidecar="$(git -C "${src}" show "${commit}:modules/apps/portal-search-elasticsearch8/portal-search-elasticsearch8-impl/src/main/resources/META-INF/sidecar/sidecar.version" 2>/dev/null | head -1)"

	if [ -n "${sidecar}" ] && [ -d "${src_bundle}/elasticsearch-sidecar/${sidecar}" ]; then
		mkdir -p "${dst_bundle}/elasticsearch-sidecar"
		_lfrStep "Copy the Elasticsearch sidecar ${sidecar}" rsync -a "${delete[@]}" --exclude=/logs/ "${src_bundle}/elasticsearch-sidecar/${sidecar}" \
			"${dst_bundle}/elasticsearch-sidecar/" || return 1
	fi

	# The build state of the clone: each file that git ignores outside modules/, such as
	# the portal snapshots (.m2), lib/development, lib/portal, tools/sdk, the Gradle
	# distribution, tmp/lib-pre, and the compiled core. Only ignored files, so a tracked
	# file of the branch is never replaced. No -t, so the copies get a new mtime, newer
	# than the files of the checkout, and a check that compares the two does not see
	# them as stale. The IDE, the per-user properties, and .gradle stay out: lfrWorktree
	# writes those itself.
	local -a tops=()

	mapfile -t tops < <(cd "${src}" && ls -A | command grep -vxE 'modules|\.git|\.gradle|\.idea|workspaces')

	(
		cd "${src}" &&
		git ls-files --others --ignored --exclude-standard --directory -- "${tops[@]}" |
		command grep -vE "^[^/]*\\.${USER}\\.properties/?$"
	) | _lfrStep "Copy the build state of ${src}" rsync -rlpD --files-from=- "${src}/" "${dir}/" || return 1

	# Gradle reads the bundle paths from .gradle/gradle.properties, which ant writes with
	# absolute paths. Point the paths of the source bundle at the new bundle, and the
	# other paths of the source clone at the worktree.
	if [ -f "${src}/.gradle/gradle.properties" ]; then
		local abs key line val

		mkdir -p "${dir}/.gradle"

		while IFS= read -r line || [ -n "${line}" ]; do
			key="${line%%=*}"
			val="${line#*=}"

			if [ "${key}" != "${line}" ] && [ "${val:0:1}" = / ]; then
				abs="$(realpath -m "${val}")"

				case "${abs}" in
				"${src_bundle}" | "${src_bundle}"/*) line="${key}=${dst_bundle}${abs#"${src_bundle}"}" ;;
				"${src_real}" | "${src_real}"/*) line="${key}=${dir}${abs#"${src_real}"}" ;;
				esac
			fi

			# A path inside a value (-javaagent\:<path>, destfile\=<path>).
			line="${line//"${src_real}/"/"${dir}/"}"

			printf '%s\n' "${line}"
		done <"${src}/.gradle/gradle.properties" >"${dir}/.gradle/gradle.properties"
	fi

	printf 'copied_from=%s\n' "${src_bundle}" >>"${dst_bundle}/${_LFR_BUILD_STAMP}"

	echo "lfrWorktree: copied the bundle ($(du -sh "${dst_bundle}" 2>/dev/null | cut -f1)) and the build state of ${src}" >&2
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

# Copy the invoking clone's per-user *.${USER}.properties into the nested worktree $2,
# where the checkout is <home>/portal. Two values change, since both are relative to the
# checkout: app.server.parent.dir becomes ${project.dir}/../bundles, the bundles/ folder
# next to it, and build.binaries.cache.dir becomes ../<cache> when the cache is one of
# LFR_BINARIES_CACHES, since _lfrWorktreeCacheLinks puts a link of that name in the home
# folder. Keep it relative: util.gradle builds the path as
# new File(rootDir.parentFile, <value>), so an absolute value lands under the checkout
# and the Yarn offline cache step finds nothing (NO-SOURCE, no error). A cache with
# another name gets the absolute path it has for the clone $1. Both are written even
# when the clone does not set them, so the tools that read the per-user file
# (_lfrRepoBundleDir, _lfrBundleRepoBranches) and the build both find them.
_lfrWorktreeNestedProperties() {
	local src_root="${1}" dir="${2}"
	local f name val cache="" value="" repo_name
	local -a copied=()

	# The cache path the clone uses: its own setting, else the default of build.properties
	# (../<build.binaries.cache.repository.name>), resolved against the clone.
	val="$(sed -n 's/^[[:space:]]*build\.binaries\.cache\.dir[[:space:]]*=[[:space:]]*//p' \
		"${src_root}/build.${USER}.properties" 2>/dev/null | tail -1)"

	if [ -z "${val}" ]; then
		repo_name="$(sed -n 's/^[[:space:]]*build\.binaries\.cache\.repository\.name[[:space:]]*=[[:space:]]*//p' \
			"${src_root}/build.properties" 2>/dev/null | tail -1)"
		[ -n "${repo_name}" ] && val="../${repo_name}"
	fi

	if [ -n "${val}" ]; then
		case "${val}" in
		/*) cache="$(realpath -m "${val}")" ;;
		*) cache="$(realpath -m "${src_root}/${val}")" ;;
		esac

		value="${cache}"

		for name in "${LFR_BINARIES_CACHES[@]}"; do
			[ "${cache##*/}" = "${name}" ] && value="../${name}"
		done
	fi

	for f in "${src_root}"/*."${USER}".properties; do
		[ -f "${f}" ] || continue
		name="$(basename "${f}")"
		sed -E -e 's#^([[:space:]]*app\.server\.parent\.dir[[:space:]]*=).*#\1${project.dir}/../bundles#' \
			-e "s#^([[:space:]]*build\.binaries\.cache\.dir[[:space:]]*=).*#\1${value}#" \
			"${f}" >"${dir}/${name}" || return 1
		copied+=("${name}")
	done

	f="${dir}/app.server.${USER}.properties"

	if ! command grep -q '^[[:space:]]*app\.server\.parent\.dir[[:space:]]*=' "${f}" 2>/dev/null; then
		printf 'app.server.parent.dir=${project.dir}/../bundles\n' >>"${f}" || return 1
		[ -n "$(printf '%s\n' "${copied[@]}" | command grep -xF "app.server.${USER}.properties")" ] ||
			copied+=("app.server.${USER}.properties")
	fi

	f="${dir}/build.${USER}.properties"

	if [ -n "${cache}" ] &&
		! command grep -q '^[[:space:]]*build\.binaries\.cache\.dir[[:space:]]*=' "${f}" 2>/dev/null; then
		printf 'build.binaries.cache.dir=%s\n' "${value}" >>"${f}" || return 1
		[ -n "$(printf '%s\n' "${copied[@]}" | command grep -xF "build.${USER}.properties")" ] ||
			copied+=("build.${USER}.properties")
	fi

	echo "lfrWorktree: copied per-user config (bundle -> \${project.dir}/../bundles, binaries cache -> ${value:-not set}): ${copied[*]}" >&2

	if [ -n "${cache}" ] && [ ! -d "${cache}" ]; then
		echo "lfrWorktree: the binaries cache ${cache} does not exist; the build will not find it" >&2
	fi
}

# Write the marker of the nested worktree home $1: the clone $2 it was made from, the
# branch $3, the database its bundle names, the source clone $4 whose build was copied
# (empty when none), and the date. The commands that act on the worktree read it, so they
# need not guess any of it from the folder name.
_lfrWorktreeWriteMarker() {
	local home="${1}" src_root="${2}" branch="${3}" source="${4-}" db=""

	if [ -f "${home}/bundles/portal-ext.properties" ]; then
		db="$(_lfrWorktreeBundleDatabase "${home}/bundles/portal-ext.properties")"
	fi

	{
		printf 'repo=%s\n' "${src_root}"
		printf 'branch=%s\n' "${branch}"
		printf 'database=%s\n' "${db}"
		printf 'source=%s\n' "${source}"
		printf 'created=%s\n' "$(date -Iseconds)"
	} >"${home}/${LFR_WORKTREE_MARKER}" || return 1

	echo "lfrWorktree: wrote ${home}/${LFR_WORKTREE_MARKER}" >&2

	_lfrWorktreeCacheLinks "${home}" "${src_root}"
}

# The binaries caches that tools expect next to a checkout (../<name>): the build
# default of build.properties and liferay-intellij (intellij_common checks
# ../liferay-binaries-cache-2017 and -2020, and asks for a clone or a symbolic link).
LFR_BINARIES_CACHES=("liferay-binaries-cache-2017" "liferay-binaries-cache-2020")

# Link each binaries cache that sits next to the clone $2 into the nested worktree
# home $1, so ../<cache> from the checkout resolves to the shared cache.
# A link that exists is left alone; a cache the clone does not have is skipped.
_lfrWorktreeCacheLinks() {
	local home="${1}" src_root="${2}" name target

	for name in "${LFR_BINARIES_CACHES[@]}"; do
		[ -e "${home}/${name}" ] || [ -L "${home}/${name}" ] && continue

		target="$(realpath -e "${src_root}/../${name}" 2>/dev/null)" || continue

		ln -s "${target}" "${home}/${name}" &&
			echo "lfrWorktree: linked ${home}/${name} -> ${target}" >&2
	done
}

lfrWorktree() {
	case "${1-}" in
	-h | --help)
		cat <<-'EOF'
			lfrWorktree - create a git worktree for a branch, wired to its own bundle.

			Usage:
			  lfrWorktree <branch>          if <branch> exists, check it out; else create
			                                it off upstream/master
			  lfrWorktree <branch> <base>   create <branch> off the given base ref
			                                (a local branch, <remote>/<ref>, or a sha)

			The worktree is one folder, liferay-portal-<branch> in LFR_WORKTREE_ROOT,
			and you are moved into it. It holds the checkout (portal/), its bundle
			(bundles/), and a marker (.lfr-worktree: repo, branch, database, source).
			Your per-user *.${USER}.properties are copied in, pointed at
			${project.dir}/../bundles. The bundle gets your portal-ext.properties, on a
			database of its own (portal-<branch>), which is created for you when
			PostgreSQL is reachable. The binaries cache path stays ../<cache>, through
			a link in the home folder. Run from inside any liferay-portal clone.

			Two questions, both answered y or n:

			A bundle dir already there (what lfrWorktreeRemove --keep-bundle leaves) is
			reported with its size, its config's age and drift, and its database, and you
			say whether to reuse it. Answer n and it is moved aside as <dir>.old-<stamp>
			and a fresh one is wired; its database is left for you to reset.

			Then whether to run lfrWorktreeIdeaInit, which gives the worktree the
			IntelliJ project and the debug profiles in about 17 seconds. Set
			LFR_WORKTREE_IDEA=1 to always run it, 0 to never ask.

			Copy of a built bundle, so the worktree needs no `ant all`:
			  The clones in LFR_WORKTREE_SOURCES stay clean on their line (master,
			  brian master, EE master), and lfrAntAll stamps their bundle with the
			  commit it built. The newest valid build whose commit is in the base is
			  taken, from any source, so one build serves all lines while they are on
			  one commit. The new branch is cut from that commit, and the bundle and
			  the build state of the clone are copied in, on the new database. With
			  no valid build (not built, a dirty tree, a deploy after the build, not
			  in the base), each reason is printed, and the worktree is made as
			  before, off the tip of the base.
			  --copy-bundle=<clone>  copy only from this clone
			  --no-copy-bundle       never copy
		EOF
		return 0
		;;
	esac

	local copy=auto a
	local -a args=()

	for a in "$@"; do
		case "${a}" in
		--copy-bundle=*) copy="${a#--copy-bundle=}" ;;
		--no-copy-bundle) copy=none ;;
		*) args+=("${a}") ;;
		esac
	done

	local branch="${args[0]-}"
	local base="${args[1]:-${LFR_WORKTREE_BASE:-upstream/master}}"

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
	local dir home
	dir="$(_lfrWorktreeDir "${branch}" "${wt_root}")" || return 1

	# The home folder is the worktree, so it must not exist yet.
	home="${dir%/*}"

	if [ -e "${home}" ]; then
		echo "lfrWorktree: ${home} already exists" >&2
		return 1
	fi

	mkdir -p "${wt_root}" || {
		echo "lfrWorktree: cannot create worktree root ${wt_root}" >&2
		return 1
	}

	# The base must be fresh before the build to copy is picked from it. Only treat a
	# "<a>/<b>" base as a remote ref (and fetch to refresh it) when <a> is a real remote;
	# otherwise it is a local ref (e.g. a branch literally named feature/x).
	local exists=0 remote="${base%%/*}" ref="${base#*/}"

	if git show-ref --verify --quiet "refs/heads/${branch}"; then
		exists=1
	elif [ "${remote}" != "${base}" ] && git remote get-url "${remote}" >/dev/null 2>&1; then
		echo "lfrWorktree: fetching ${remote} ${ref}..." >&2
		_lfrStep "Fetch ${remote} ${ref}" git fetch "${remote}" "${ref}" || return 1
	elif ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
		echo "lfrWorktree: base ref '${base}' not found (not a local ref or <remote>/<ref>)" >&2
		return 1
	fi

	# The clone whose built bundle this worktree copies, and the commit it holds.
	local source="" source_commit="" pick target="${base}" only=""

	[ "${exists}" = 1 ] && target="${branch}"

	case "${copy}" in
	none | auto) ;;
	*)
		only="$(cd "${copy}" 2>/dev/null && git rev-parse --show-toplevel)" || {
			echo "lfrWorktree: --copy-bundle: ${copy} is not a git repo" >&2
			return 1
		}
		;;
	esac

	if [ "${copy}" != none ] && { [ -n "${only}" ] || [ "${#LFR_WORKTREE_SOURCES[@]}" -gt 0 ]; }; then
		if pick="$(_lfrWorktreeSourcePick "${target}" "${only}")"; then
			source="${pick%%$'\t'*}"
			source_commit="${pick#*$'\t'}"
		else
			[ -z "${only}" ] || return 1
			echo "lfrWorktree: no build of a source clone is in ${target}; the bundle is not copied, and the worktree needs lfrAntAll" >&2
		fi
	fi

	if [ "${exists}" = 1 ]; then
		# The branch already exists: check it out in the new worktree (git refuses
		# if it is already checked out elsewhere; relay that error). base is ignored.
		echo "lfrWorktree: branch ${branch} exists; checking it out in ${dir}..." >&2
		_lfrStep "Check out ${branch} in ${dir}" git worktree add "${dir}" "${branch}" || return 1
	elif [ -n "${source}" ]; then
		# Cut the branch from the commit of the copied bundle, not from the tip of the
		# base, so the worktree and its bundle hold the same code.
		echo "lfrWorktree: cutting ${branch} from ${source_commit:0:13}, the build of ${source}" >&2
		_lfrStep "Check out ${branch} in ${dir}" git worktree add -b "${branch}" "${dir}" "${source_commit}" || return 1
	else
		# New branch off the base ref, fetched above.
		_lfrStep "Check out ${branch} in ${dir}" git worktree add -b "${branch}" "${dir}" "${base}" || return 1
	fi

	# Copy the invoking clone's per-user (gitignored) *.${USER}.properties into the
	# worktree, pointed at the bundles/ folder of its home. Slashes in the branch
	# become dashes in the database name.
	local bundle_suffix="${branch//\//-}"

	_lfrWorktreeNestedProperties "${src_root}" "${dir}" || return 1

	_lfrWorktreeBundleConfig "${src_root}" "${dir}" "${bundle_suffix}"

	_lfrWorktreeWriteMarker "${home}" "${src_root}" "${branch}" "${source}"

	if [ -n "${source}" ]; then
		_lfrWorktreeCopyBundle "${source}" "${dir}" ||
			echo "lfrWorktree: the copy of the bundle failed; the worktree needs lfrAntAll" >&2
	fi

	# Share the Gradle build cache when the invoking clone shares it, so the first
	# build of the worktree reuses the module outputs that the clones built.
	if [ -f "${src_root}/.gradle/init.d/lfr-build-cache.gradle" ] && declare -F lfrCache >/dev/null 2>&1; then
		lfrCache on "${dir}" >&2
	fi

	cd "${dir}" || return 1

	_lfrWorktreeIdeaInitPrompt
}

# Echo the modules of the worktree $1 that differ from commit $2 (committed, staged,
# unstaged, or untracked), as the paths to deploy: a module, or a portal core directory.
_lfrWorktreeChangedModules() {
	local root="${1}" commit="${2}"
	local file dir rel
	declare -A seen=()

	while IFS= read -r file; do
		case "${file}" in
		portal-impl/* | portal-kernel/* | portal-test/* | portal-web/* | util-*/*)
			rel="${file%%/*}"
			;;
		modules/*)
			dir="${root}/$(dirname "${file}")"

			while [ "${dir}" != "${root}/modules" ] && [ "${dir}" != / ]; do
				[ -f "${dir}/bnd.bnd" ] && [ -f "${dir}/build.gradle" ] && break
				dir="$(dirname "${dir}")"
			done

			[ -f "${dir}/.lfrbuild-portal" ] || continue
			rel="${dir#"${root}/"}"
			;;
		*)
			continue
			;;
		esac

		[ -n "${seen[${rel}]-}" ] && continue
		seen[${rel}]=1
		printf '%s\n' "${rel}"
	done < <(cd "${root}" && { git diff --name-only "${commit}"; git ls-files --others --exclude-standard; } | sort -u)
}

# Give an existing worktree the built bundle of a source clone, in place of its own, so
# it needs no `ant all`. Keeps the database, data, logs, and portal-ext.properties.
lfrWorktreeCopyBundle() {
	case "${1-}" in
	-h | --help)
		cat <<-'EOF'
			lfrWorktreeCopyBundle - give this worktree the built bundle of a source clone.

			Usage:
			  lfrWorktreeCopyBundle                 copy the newest build of a clone in
			                                        LFR_WORKTREE_SOURCES that this branch
			                                        contains
			  lfrWorktreeCopyBundle --from=<clone>  copy from this clone
			  lfrWorktreeCopyBundle -y              do not ask before the copy

			Run it inside the worktree, with its bundle stopped. It also runs in a
			source clone whose head is the same commit as the build of another one,
			with no local change: then that clone needs no lfrAntAll of its own. The Tomcat, the OSGi
			modules, the Elasticsearch sidecar, and the build state of the clone (.m2,
			lib, tmp/lib-pre, .gradle/gradle.properties) are replaced with the build of
			the source. The database, data, logs, and portal-ext.properties stay. The
			OSGi state and the JSP cache are cleared.

			The branch must contain the commit of the source build. If no build fits,
			it names each build, and you rebase onto one: lfrGitRebaseOnto <commit>. After the copy, it lists the
			modules that the branch changes: deploy them, or the bundle runs master.
		EOF
		return 0
		;;
	esac

	local from="" yes=0 a

	for a in "$@"; do
		case "${a}" in
		--from=*) from="${a#--from=}" ;;
		-y | --yes) yes=1 ;;
		*)
			echo "lfrWorktreeCopyBundle: unknown argument ${a}; see -h" >&2
			return 1
			;;
		esac
	done

	local root bundle source commit pick pid
	root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
		echo "lfrWorktreeCopyBundle: not inside a git repo" >&2
		return 1
	}

	bundle="$(cd "${root}" && _lfrRepoBundleDir)" || {
		echo "lfrWorktreeCopyBundle: cannot resolve the bundle of ${root}" >&2
		return 1
	}

	local s is_source=0
	local -a others=()

	for s in "${LFR_WORKTREE_SOURCES[@]}"; do
		if [ "$(cd "${s}" 2>/dev/null && pwd -P)" = "$(cd "${root}" && pwd -P)" ]; then
			is_source=1
		else
			others+=("${s}")
		fi
	done

	if declare -F _lfrBundlePidForDir >/dev/null 2>&1 && pid="$(_lfrBundlePidForDir "${bundle}")"; then
		echo "lfrWorktreeCopyBundle: the bundle runs (PID ${pid}); stop it first: ${bundle}" >&2
		return 1
	fi

	if [ -n "${from}" ]; then
		from="$(cd "${from}" 2>/dev/null && git rev-parse --show-toplevel)" || {
			echo "lfrWorktreeCopyBundle: --from is not a git repo" >&2
			return 1
		}
	fi

	# A source clone takes only another source, and only at its own head, so its stamp
	# stays true: the bundle holds exactly the commit of the clone.
	if [ "${is_source}" = 1 ]; then
		if [ -n "$(git -C "${root}" status --porcelain --untracked-files=no)" ]; then
			echo "lfrWorktreeCopyBundle: ${root} is a source clone with local changes" >&2
			return 1
		fi

		if [ -z "${from}" ]; then
			pick="$(cd "${root}" && LFR_WORKTREE_SOURCES=("${others[@]}") && _lfrWorktreeSourcePick HEAD)"
		else
			pick="$(cd "${root}" && _lfrWorktreeSourcePick HEAD "${from}")"
		fi

		if [ -z "${pick}" ] || [ "${pick#*$'\t'}" != "$(git -C "${root}" rev-parse HEAD)" ]; then
			echo "lfrWorktreeCopyBundle: ${root} is a source clone, and no other source has a build of its head; run lfrAntAll there" >&2
			return 1
		fi
	fi

	[ -n "${pick-}" ] || pick="$(cd "${root}" && _lfrWorktreeSourcePick HEAD "${from}")" || {
		echo "lfrWorktreeCopyBundle: this branch contains no build of a source clone." >&2
		echo "  Rebase it onto a build above, so the branch and the bundle hold the same code: lfrGitRebaseOnto <commit>" >&2
		return 1
	}

	source="${pick%%$'\t'*}"
	commit="${pick#*$'\t'}"

	echo "Source : ${source} (build of ${commit:0:13})"
	echo "Bundle : ${bundle} (its Tomcat and OSGi modules are replaced; database, data, and logs stay)"

	if [ "${yes}" != 1 ] && ! _lfrConfirm "lfrWorktreeCopyBundle: copy?"; then
		echo "lfrWorktreeCopyBundle: nothing copied" >&2
		return 1
	fi

	(cd "${root}" && _lfrWorktreeCopyBundle "${source}" "${root}" replace) || return 1

	# The copy gives the compiled core a new mtime, newer than each source of the
	# checkout. Ant compares mtimes, so an ant deploy of the core skips each change of
	# the branch after the build commit. Touch these sources, so that ant compiles them.
	local -a sources=()
	local f

	mapfile -t sources < <(
		cd "${root}" &&
		{
			git diff --name-only "${commit}" -- portal-impl portal-kernel portal-test portal-web 'util-*'
			git ls-files --others --exclude-standard -- portal-impl portal-kernel portal-test portal-web 'util-*'
		} | sort -u
	)

	for f in "${sources[@]}"; do
		[ -f "${root}/${f}" ] && touch "${root}/${f}"
	done

	local -a modules=()
	mapfile -t modules < <(_lfrWorktreeChangedModules "${root}" "${commit}")

	if [ "${#modules[@]}" = 0 ]; then
		echo "lfrWorktreeCopyBundle: the branch changes no deployed module; the bundle is ready" >&2
		return 0
	fi

	local -a core=() gradle=() m

	for m in "${modules[@]}"; do
		case "${m}" in
		modules/*) gradle+=("${m}") ;;
		*) core+=("${m}") ;;
		esac
	done

	echo "lfrWorktreeCopyBundle: deploy what the branch changes, or the bundle runs ${commit:0:13} without it." >&2

	if [ "${#gradle[@]}" -gt 0 ]; then
		echo "  Modules (gradlew deploy in each):" >&2
		printf '    %s\n' "${gradle[@]}" >&2
	fi

	if [ "${#core[@]}" -gt 0 ]; then
		echo "  Portal core (ant deploy install-portal-snapshot in each, then a restart; lfrAntAll when a changed API breaks other modules):" >&2
		printf '    %s\n' "${core[@]}" >&2
	fi
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

	# Trim the copy, never the live file, as in _lfrWorktreeIdeaRecentProject below.
	if [ "${trailing_newline}" -eq 0 ]; then
		truncate -s -1 "${tmp}"
	fi

	cat "${tmp}" >"${file}" || {
		rm -f "${tmp}"

		return 1
	}

	rm -f "${tmp}"

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

	# Trim the copy, never the live file, as in _lfrWorktreeIdeaRecentProject below.
	if [ "${trailing_newline}" -eq 0 ]; then
		truncate -s -1 "${tmp}"
	fi

	cat "${tmp}" >"${file}" || {
		rm -f "${tmp}"

		return 1
	}

	rm -f "${tmp}"
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
			if id="$(_lfrWorktreeRemoveIdeaEntry "${recent}" "${key}")"; then
				echo "${caller}: ${config_dir##*/} forgot the project ${dir}" >&2

				# The workspace file holds the project's open editors, run configurations
				# and window layout, and is named by the id the entry carried.
				if [ -n "${id}" ]; then
					rm -f "${config_dir}/workspace/${id}.xml"
				fi
			fi

			# A moved or renamed project has no Welcome screen entry at its old path any
			# more, but its trusted path and its Open File history can still be there.
			if _lfrWorktreeRemoveIdeaEntry "${config_dir}/options/trusted-paths.xml" "${key}" >/dev/null; then
				echo "${caller}: ${config_dir##*/} forgot the trusted path ${dir}" >&2
			fi

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

# Hold the caller until IntelliJ is closed, by asking you to close it yourself and then
# checking. A y is not taken on its word: the IDE takes a few seconds to flush and exit
# after its window goes, and an edit made in that gap is undone the same way, so a y
# while the process is still there asks again. An n stops the caller with nothing done.
_lfrWorktreeIdeaWaitClosed() {
	local caller="${1}"

	_lfrWorktreeIdeaRunning || return 0

	if [ ! -t 0 ]; then
		echo "${caller}: IntelliJ is running; close it first, or it will write the projects back on exit" >&2

		return 1
	fi

	while true; do
		if ! _lfrConfirm "${caller}: IntelliJ is running. Please close it before we start. Is it closed?"; then
			echo "${caller}: nothing done; close IntelliJ and run it again" >&2

			return 1
		fi

		if ! _lfrWorktreeIdeaRunning; then
			echo "${caller}: IntelliJ is closed" >&2

			return 0
		fi

		echo "${caller}: IntelliJ is still running" >&2
	done
}

# List the worktree projects IntelliJ still offers whose directory is gone: the leftovers
# of a worktree removed by hand, by an older lfrWorktreeRemove, or while an IDE was open.
# Echoes one path per line.
#
# A missing directory alone is not enough to call a project a leftover, so three things
# have to hold. It is the portal/ checkout of a folder that lfrWorktree makes
# (liferay-portal-<branch>), directly in LFR_WORKTREE_ROOT or in one of LFR_REPO_ROOTS
# (the source clones). That whole folder is gone. And its root is there, since with the Data drive unmounted every
# project on it is missing, and forgetting all of them over an unmounted drive is the
# one failure this command must not have.
#
# The paths come from the Welcome screen list (recentProjects.xml) and from the trusted
# paths (trusted-paths.xml). A move or a rename rewrites the Welcome screen entry, but
# the trusted path of the old folder stays, and IntelliJ keeps it with no end.
_lfrWorktreeIdeaOrphans() {
	local config_root="${XDG_CONFIG_HOME:-${HOME}/.config}/JetBrains"
	local -a roots=()
	local root

	for root in "${LFR_WORKTREE_ROOT:-${HOME}/liferay/repos}" "${LFR_REPO_ROOTS[@]}"; do
		[ -d "${root}" ] && roots+=("${root%/}")
	done

	[ "${#roots[@]}" -gt 0 ] || return 0

	local config_dir key
	for config_dir in "${config_root}"/*/options; do
		[ -d "${config_dir}" ] || continue

		while IFS= read -r key; do
			key="${key/\$USER_HOME\$/${HOME}}"

			# A worktree counts as gone only when its whole home folder is gone.
			local match=""
			for root in "${roots[@]}"; do
				if [ "${key##*/}" = portal ] && [ "${key%/*/*}" = "${root}" ]; then
					case "${key%/*}" in
					*/liferay-portal-?*) [ -e "${key%/*}" ] || match=1 ;;
					esac
				fi

				[ -n "${match}" ] && break
			done

			[ -n "${match}" ] || continue
			[ -e "${key}" ] && continue

			printf '%s\n' "${key}"
		done < <(
			sed -nE 's/^[[:space:]]*<entry key="([^"]+)">$/\1/p' "${config_dir}/recentProjects.xml" 2>/dev/null
			sed -nE 's/^[[:space:]]*<entry key="([^"]+)" value="[^"]*" \/>$/\1/p' "${config_dir}/trusted-paths.xml" 2>/dev/null
		)
	done | sort -u
}

_lfrWorktreeIdeaCleanHelp() {
	cat <<-'EOF'
		lfrWorktreeIdeaClean - make IntelliJ forget worktree projects that are gone.

		Usage:
		  lfrWorktreeIdeaClean      for every liferay-portal-<branch> project, or
		                            its portal/ checkout, in LFR_WORKTREE_ROOT or
		                            one of LFR_REPO_ROOTS whose directory no
		                            longer exists, remove it from the Welcome
		                            screen and the trusted paths, and delete its
		                            index cache
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

# Every portal-ext.properties or portal-setup-wizard.properties under LFR_BUNDLES_DIRS
# whose jdbc.default.url names the database $1. The wizard file counts because it loads
# after portal-ext.properties and overrides it, and liferay-dxp/ is searched because a
# release bundle keeps its config one level down.
_lfrWorktreeDatabasePointers() {
	local db_name="${1}"
	local file root

	for root in "${LFR_BUNDLES_DIRS[@]}"; do
		[ -d "${root}" ] || continue

		for file in "${root}"/*/portal-ext.properties "${root}"/*/portal-setup-wizard.properties \
				"${root}"/*/liferay-dxp/portal-ext.properties "${root}"/*/liferay-dxp/portal-setup-wizard.properties \
				"${root}"/*/bundles/portal-ext.properties "${root}"/*/bundles/portal-setup-wizard.properties; do
			[ -f "${file}" ] || continue

			if sed -nE 's#^[[:space:]]*jdbc\.default\.url=jdbc:[a-z]+://[^/]+/([^?[:space:]]+).*#\1#p' "${file}" |
					grep -qxF -- "${db_name}"; then
				printf '%s\n' "${file}"
			fi
		done
	done
}

# Drop a removed worktree's database, once nothing can still want it. $1-$4 are the host,
# port, user and password, read before the bundle and its portal-ext.properties went, and
# $5 the database. Leaves it and says why when its name is master-like, when any bundle
# config still points at it, or when anything is connected to it; the drop itself carries
# no FORCE, so a connection opened in between fails it rather than being cut.
_lfrWorktreeDropDatabase() {
	local host="${1}" port="${2}" user="${3}" password="${4}" db_name="${5}"
	local connections pointers size

	case "${db_name}" in
	portal-master* | lportal)
		echo "lfrWorktreeRemove: left the master-like ${db_name} database alone" >&2

		return 0
		;;
	esac

	if ! command -v psql >/dev/null 2>&1; then
		echo "lfrWorktreeRemove: psql not found; drop ${db_name} yourself with dropdb ${db_name}" >&2

		return 0
	fi

	if ! PGPASSWORD="${password}" _lfrStep "Check the database ${db_name}" psql -h "${host}" -p "${port}" -U "${user}" -tAc \
			"select 1 from pg_database where datname = '${db_name}'" 2>/dev/null |
			grep -q 1; then
		echo "lfrWorktreeRemove: there is no ${db_name} database to drop" >&2

		return 0
	fi

	pointers="$(_lfrWorktreeDatabasePointers "${db_name}")"

	if [ -n "${pointers}" ]; then
		echo "lfrWorktreeRemove: left the ${db_name} database alone, since other bundles still point at it:" >&2
		printf '%s\n' "${pointers}" | sed 's/^/  /' >&2

		return 0
	fi

	connections="$(PGPASSWORD="${password}" _lfrStep "Count the connections to ${db_name}" psql -h "${host}" -p "${port}" -U "${user}" -tAc \
		"select count(*) from pg_stat_activity where datname = '${db_name}'" 2>/dev/null)"

	if [ "${connections:-0}" != "0" ]; then
		echo "lfrWorktreeRemove: left the ${db_name} database alone, since ${connections} connections are open on it" >&2

		return 0
	fi

	size="$(PGPASSWORD="${password}" _lfrStep "Measure the database ${db_name}" psql -h "${host}" -p "${port}" -U "${user}" -tAc \
		"select pg_size_pretty(pg_database_size('${db_name}'))" 2>/dev/null)"

	if PGPASSWORD="${password}" _lfrStep "Drop the database ${db_name}" psql -h "${host}" -p "${port}" -U "${user}" -q -c \
			"drop database \"${db_name}\"" 2>/dev/null; then
		echo "lfrWorktreeRemove: dropped the ${db_name} database (${size:-unknown size})" >&2
	else
		echo "lfrWorktreeRemove: could not drop ${db_name}; drop it yourself with dropdb ${db_name}" >&2
	fi
}

# Undo an lfrWorktree: remove the worktree, delete its branch, delete the bundle dir that
# came with it and drop its database, and make IntelliJ forget the project. Deliberately
# conservative, since all of it is destructive: it refuses while that bundle's Tomcat
# runs, keeps the bundle when --keep-bundle asks for it and the database when
# --keep-database does, and drops the database only once nothing points at it.
#
# Usage:
#     lfrWorktreeRemove LPD-12345               # remove the worktree, branch, bundle
#     lfrWorktreeRemove LPD-12345 --force       # also when the worktree is dirty or
#                                               # the branch is unmerged
#     lfrWorktreeRemove LPD-12345 --keep-bundle # leave the bundle dir in place
#     lfrWorktreeRemove LPD-12345 --keep-database # leave the database in place
# The run logs of lfrWorktreeRemove, one folder for each worktree
# (LfrCommon/lfr-log.sh). The log keeps the head of the deleted branch.
_LFR_REPOS_LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs"

# The PIDs of the Gradle daemons of the checkout $1, one per line. gradlew sets
# gradle.user.home to <checkout>/.gradle, so the command line of each daemon of the
# checkout names that folder. The command lines are read from /proc, because a pgrep
# pattern that holds the path also matches the shell that runs it.
_lfrWorktreeGradleDaemonPids() {
	local dir="${1%/}" pid

	for pid in $(pgrep -f '[G]radleDaemon'); do
		tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null |
			command grep -qF -- "${dir}/.gradle/" && printf '%s\n' "${pid}"
	done
}

# Stop the Gradle daemons of the checkout $1 before it moves or goes; $2 names the
# caller in the messages. A daemon keeps its registry in <checkout>/.gradle/daemon and
# writes it again when it exits. If it exits after the folder moved or went, the old
# folder comes back with only .gradle/daemon in it. gradlew --stop returns about a second
# before the daemon exits, so this also waits, up to 15 seconds, for the processes to end.
# The daemons of other checkouts are not touched, since each one has its own
# gradle.user.home.
_lfrWorktreeStopGradleDaemons() {
	local dir="${1%/}" caller="${2}" i

	[ -x "${dir}/gradlew" ] && [ -d "${dir}/.gradle/daemon" ] || return 0

	if ! (cd "${dir}" && ./gradlew --stop --quiet) >/dev/null 2>&1; then
		echo "${caller}: could not stop the Gradle daemons of ${dir}; if ${dir} comes back with only .gradle/daemon, delete it" >&2

		return 0
	fi

	for i in $(seq 1 30); do
		if [ -z "$(_lfrWorktreeGradleDaemonPids "${dir}")" ]; then
			echo "${caller}: stopped the Gradle daemons of ${dir}" >&2

			return 0
		fi

		sleep 0.5
	done

	echo "${caller}: a Gradle daemon of ${dir} still runs; if ${dir} comes back with only .gradle/daemon, delete it" >&2
}

# Remove the home folder $1 of a nested worktree once its checkout and bundle are gone:
# the marker goes, then the folder, but only when nothing else is left in it. A kept
# bundle (--keep-bundle) or a file put there by hand keeps the folder and the marker,
# and says so. No-op for an empty $1, which is a checkout that is not a worktree.
_lfrWorktreeRemoveHome() {
	local home="${1-}"

	[ -n "${home}" ] && [ -d "${home}" ] || return 0

	local left name
	left="$(find "${home}" -mindepth 1 -maxdepth 1 ! -name "${LFR_WORKTREE_MARKER}" \
		! \( -type l -name 'liferay-binaries-cache-*' \) -printf '%f ' 2>/dev/null)"

	if [ -n "${left}" ]; then
		echo "lfrWorktreeRemove: kept ${home}, which still holds: ${left% }" >&2
		return 0
	fi

	# The cache links only point at the shared caches, so removing them removes no data.
	for name in "${LFR_BINARIES_CACHES[@]}"; do
		[ -L "${home}/${name}" ] && rm -f "${home:?}/${name}"
	done

	rm -f "${home:?}/${LFR_WORKTREE_MARKER}" && rmdir "${home}" &&
		echo "lfrWorktreeRemove: removed the worktree folder ${home}" >&2
}

lfrWorktreeRemove() {
	case "${1-}" in
	-h | --help)
		cat <<-'EOF'
			lfrWorktreeRemove - remove a worktree, its branch, and its bundle.

			Usage:
			  lfrWorktreeRemove <branch>                remove the worktree, delete
			                                            the branch, and delete the
			                                            bundle dir, built or not
			  lfrWorktreeRemove <branch> --force        also when the worktree has
			                                            changes or the branch is
			                                            unmerged
			  lfrWorktreeRemove <branch> --keep-bundle  leave the bundle dir in
			                                            place, and so its database
			  lfrWorktreeRemove <branch> --keep-database
			                                            leave the database in place

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

			Drops the bundle's database too, rather than leave it orphaned, but only
			when nothing can still want it: never a master-like name, never while any
			portal-ext.properties or portal-setup-wizard.properties under
			LFR_BUNDLES_DIRS points at it (a kept bundle does), and never while
			anything is connected to it. Otherwise it says why and leaves it. Run
			from inside any liferay-portal clone.

			Each run writes a log to
			LfrRepos/logs/<worktree>/<worktree>_worktree-remove_<time>.log, with
			the output, the exit code, and the head of each deleted branch, so
			git branch <branch> <commit> can bring it back. The logs are deleted
			after 30 days.
		EOF
		return 0
		;;
	esac
	if [ -z "${_LFR_LOG_RUN-}" ]; then
		_LFR_LOG_RUN=1 _lfrLogRun "${_LFR_REPOS_LOG_DIR}" worktree-remove lfrWorktreeRemove "$@"
		return
	fi

	local branch="${1}"

	if [ -z "${branch}" ]; then
		echo "usage: lfrWorktreeRemove <branch> [--force] [--keep-bundle] [--keep-database]" >&2
		return 1
	fi

	shift

	local force=""
	local keep_bundle=""
	local keep_database=""

	while [ "$#" -gt 0 ]; do
		case "${1}" in
		--force)
			force="--force"
			;;
		--keep-bundle)
			keep_bundle="--keep-bundle"
			;;
		--keep-database)
			keep_database="--keep-database"
			;;
		*)
			echo "lfrWorktreeRemove: unknown option ${1}" >&2
			echo "usage: lfrWorktreeRemove <branch> [--force] [--keep-bundle] [--keep-database]" >&2
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
	master* | */master)
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

	# A nested worktree's home folder goes last, once the checkout and the bundle in it
	# are gone. Read off the marker now, since the checkout is about to go.
	local home=""
	home="$(_lfrWorktreeNestedHome "${dir}")" || home=""

	# And the database's connection with it, since deleting the bundle takes the file.
	local db="" db_host="" db_password="" db_port="" db_user=""
	if [ -f "${bundle_dir}/portal-ext.properties" ]; then
		db="$(sed -nE 's/^[[:space:]]*jdbc\.default\.url=//p' "${bundle_dir}/portal-ext.properties" | tail -n 1)"
		db="${db%%\?*}"
		db="${db##*/}"

		IFS=$'\t' read -r db_host db_port db_user db_password \
			< <(_lfrWorktreeConnection "${bundle_dir}/portal-ext.properties")
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

	_lfrWorktreeStopGradleDaemons "${dir}" lfrWorktreeRemove

	if [ "${force}" = "--force" ]; then
		_lfrStep "Remove the worktree ${dir}" git worktree remove --force "${dir}" || return 1
		git branch -D "${branch}" || return 1
	else
		_lfrStep "Remove the worktree ${dir}" git worktree remove "${dir}" || {
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
	# there for the logs or the data. The database goes too, once nothing points at it,
	# since an orphaned one is only the same leak in PostgreSQL.
	if [ -z "${bundle_dir}" ] || [ ! -d "${bundle_dir}" ]; then
		_lfrWorktreeRemoveHome "${home}"
		return 0
	fi

	local bundle_size
	bundle_size="$(_lfrStep "Measure the bundle ${bundle_dir}" du -sh "${bundle_dir}" 2>/dev/null | cut -f1)"

	if [ -n "${keep_bundle}" ]; then
		echo "lfrWorktreeRemove: kept ${bundle_dir} (${bundle_size:-unknown size}) as asked" >&2
	else
		_lfrStep "Delete the bundle ${bundle_dir}" rm -rf "${bundle_dir}" || return 1
		echo "lfrWorktreeRemove: deleted the bundle ${bundle_dir} (${bundle_size:-unknown size})" >&2
	fi

	_lfrWorktreeRemoveHome "${home}"

	if [ -z "${db}" ]; then
		return 0
	fi

	# A kept bundle still points at its database, wherever it lives, so the database
	# stays with it without relying on the pointer scan to find it.
	if [ -n "${keep_bundle}" ]; then
		echo "lfrWorktreeRemove: kept the ${db} database with its bundle" >&2
	elif [ -n "${keep_database}" ]; then
		echo "lfrWorktreeRemove: kept the ${db} database as asked" >&2
	elif [ -z "${db_host}" ]; then
		echo "lfrWorktreeRemove: ${db} is not on PostgreSQL; drop it yourself" >&2
	else
		_lfrWorktreeDropDatabase "${db_host}" "${db_port}" "${db_user}" "${db_password}" "${db}"
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

	if ! PGPASSWORD="${password}" _lfrStep "Check the database ${old_db}" psql -h "${host}" -p "${port}" -U "${user}" -tAc \
			"select 1 from pg_database where datname = '${old_db}'" 2>/dev/null |
			grep -q 1; then
		echo "lfrWorktreeRename: there is no ${old_db} database to rename" >&2

		return 2
	fi

	if PGPASSWORD="${password}" _lfrStep "Rename the database ${old_db}" psql -h "${host}" -p "${port}" -U "${user}" -q -c \
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
		lfrWorktreeRename - rename a worktree, its branch, its bundle and its database.

		Usage:
		  lfrWorktreeRename <new>            rename the worktree you are standing in
		  lfrWorktreeRename <old> <new>      rename the worktree that has <old> checked out
		  lfrWorktreeRename <old> <new> --keep-database   leave the database named as it is

		Everything lfrWorktree wires under one name is moved to another, so a branch
		that turns out to be the wrong ticket costs a rename instead of a removal and
		a fresh build: the branch, the worktree folder (liferay-portal-<new>,
		with the checkout and the bundle in it), the paths in the generated
		.gradle/gradle.properties every Gradle deploy reads, the database (portal-<new>, renamed with its
		data in it), and the project IntelliJ offers on its welcome screen. The build
		in the bundle is kept as it is, apart from osgi/state, which names the bundle's
		own absolute path everywhere and is deleted so the first boot rebuilds it.

		The old name is the worktree's own, read off its directory rather than off the
		branch, so a branch renamed by hand is brought back into line: give it the name
		the branch already has and the worktree, the bundle, the paths in the
		generated Gradle properties and the database move onto it, the branch
		itself staying put.

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
	#
	# A worktree (its marker next to the checkout) is named by its home folder, and
	# renamed as one: the home folder moves with the checkout and the bundle in it.
	local home new_home

	if ! home="$(_lfrWorktreeNestedHome "${dir}")"; then
		echo "lfrWorktreeRename: ${dir} is not a worktree that lfrWorktree made (no ${LFR_WORKTREE_MARKER} next to it)" >&2

		return 1
	fi

	local new_dir
	new_home="${home%/*}/liferay-portal-${new_suffix}"
	new_dir="${new_home}/portal"

	if [ "${new_home}" != "${home}" ] && [ -e "${new_home}" ]; then
		echo "lfrWorktreeRename: ${new_home} already exists" >&2

		return 1
	fi

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
		elif [ "$(cd "${bundle_dir}" && pwd -P)" = "$(cd "${home}" && pwd -P)/bundles" ]; then
			# The bundle of a worktree is the bundles/ folder of its home, and it moves
			# with the home folder; any other bundle is not this worktree's own.
			new_bundle_dir="${new_home}/bundles"
		else
			echo "lfrWorktreeRename: ${bundle_dir} is not the bundles folder of ${home}; leaving the bundle alone" >&2
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
		_lfrWorktreeStopGradleDaemons "${dir}" lfrWorktreeRename
	fi

	if [ "${new_dir}" != "${dir}" ]; then
		# The home folder moves as one, the checkout and the bundle with it, and git is
		# told where its worktree went. Both its links name the old path until then.
		if ! mv "${home}" "${new_home}"; then
			echo "lfrWorktreeRename: could not move ${home}; nothing was renamed" >&2

			return 1
		fi

		if ! git -C "${main_root}" worktree repair "${new_dir}"; then
			echo "lfrWorktreeRename: moved ${home} to ${new_home}, but git still names the old path; run git worktree repair ${new_dir}" >&2

			return 1
		fi

		echo "lfrWorktreeRename: moved the worktree folder to ${new_home}" >&2

		case "${PWD}/" in
		"${dir}"/*) cd "${new_dir}" || return 1 ;;
		"${home}"/*) cd "${new_home}" || return 1 ;;
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
		# The bundle moved with its home folder already, and its per-user path
		# (${project.dir}/../bundles) names no folder of its own, so it needs no repoint.

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
			state_size="$(_lfrStep "Measure the OSGi state" du -sh "${state_dir}" | cut -f1)"

			_lfrStep "Delete the OSGi state" rm -rf "${state_dir}" &&
				echo "lfrWorktreeRename: deleted the OSGi state ${state_dir} (${state_size}), which named the old bundle; the first boot rebuilds it" >&2
		fi
	fi

	# .gradle/gradle.properties is the generated config every Gradle deploy reads, written
	# by ant's update-gradle-properties target with every path expanded absolute:
	# liferay.home, the app.server.*.dir for all four containers, and the JaCoCo agent's
	# jar and destfile. Nothing regenerates it on its own, since Gradle only reads it, so
	# a rename that leaves it behind sends the next deploy into the old bundle path, where
	# it recreates the directory that just moved and drops the jars there instead of into
	# the bundle this worktree now owns, and the deploy still exits 0. Measured on a
	# renamed worktree: 60 spellings of the worktree directory and 54 of the bundle, every
	# one of them built on the worktree's own path, which is why both rewrites are needed.
	local gradle_properties="${new_dir}/.gradle/gradle.properties"

	if [ -f "${gradle_properties}" ] && [ "${new_dir}" != "${dir}" ]; then
		# Every path of a worktree is under its home folder: the checkout, the
		# bundle as the copy wrote it, and the bundle as ant wrote it (portal/../bundles).
		sed -i -E "s#${home//./\\.}/#${new_home}/#g" "${gradle_properties}" || return 1

		echo "lfrWorktreeRename: repointed the generated Gradle config ${gradle_properties}" >&2
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

	if [ -n "${new_home}" ]; then
		_lfrWorktreeMarkerSet "${new_home}" branch "${new_branch}"

		if [ -f "${new_home}/bundles/portal-ext.properties" ]; then
			_lfrWorktreeMarkerSet "${new_home}" database \
				"$(_lfrWorktreeBundleDatabase "${new_home}/bundles/portal-ext.properties")"
		fi
	fi

	_lfrWorktreeIdeaName "${new_dir}"

	if [ -n "${idea_clear}" ]; then
		_lfrWorktreeIdeaTrustProject "${dir}" "${new_dir}" lfrWorktreeRename
		_lfrWorktreeIdeaMoveTaskState "${dir}" "${new_dir}" lfrWorktreeRename
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

# Make a worktree that holds the head of a pull, so you can review it or work on
# it. It fetches the head straight from the fork of the pull, so no remote is
# needed, checks the SHA, and then runs lfrWorktree from the source clone of that
# repo. lfrPullsTriage and the worktree-create skill use it.
lfrWorktreePull() {
	case "${1-}" in
	"" | -h | --help)
		cat <<-'EOF'
			lfrWorktreePull - make a worktree with the branch of a pull.

			Usage:
			  lfrWorktreePull <pull> [lfrWorktree options]

			<pull> is one of these:
			  https://github.com/<owner>/<repo>/pull/<number>   a pull link
			  <owner>/<repo>#<number>
			  <number>   a pull of your team fork (LFR_PULLS_TEAM)

			Steps:
			  1. Read the head branch and the head SHA of the pull.
			  2. Fetch pull/<number>/head into a local branch with the name of the
			     head branch. If a local branch of that name holds other commits,
			     the branch is <head>-pull-<number>.
			  3. Stop if the fetched commit is not the head SHA.
			  4. Run lfrWorktree <branch> from the source clone of the repo (the
			     clone in LFR_WORKTREE_SOURCES with the same name as the repo, else
			     the first one). You are moved into the new worktree.

			If the worktree is there already, it only moves you into it.
			The options (--copy-bundle=<clone>, --no-copy-bundle) go to lfrWorktree.
		EOF
		[ -n "${1-}" ]
		return
		;;
	esac

	local pull="${1}" repo number
	shift

	case "${pull}" in
	https://github.com/*/pull/*)
		repo="${pull#https://github.com/}"
		number="${repo#*/pull/}"
		number="${number%%[/#?]*}"
		repo="${repo%%/pull/*}"
		;;
	*/*\#*)
		repo="${pull%%#*}"
		number="${pull#*#}"
		;;
	*)
		repo="${LFR_PULLS_TEAM:-${LFR_GIT_FORK_ORG:-}}/${LFR_PULLS_FORK_REPO:-liferay-portal}"
		number="${pull#\#}"
		;;
	esac

	if [[ ! "${number}" =~ ^[0-9]+$ ]] || [[ ! "${repo}" =~ ^[^/]+/[^/]+$ ]]; then
		echo "lfrWorktreePull: cannot read a pull from '${pull}'" >&2
		return 1
	fi

	local clone="" source

	for source in "${LFR_WORKTREE_SOURCES[@]}"; do
		if [ "$(basename "${source}")" = "${repo#*/}" ]; then
			clone="${source}"
			break
		fi
	done

	clone="${clone:-${LFR_WORKTREE_SOURCES[0]:-}}"

	if [ -z "${clone}" ]; then
		echo "lfrWorktreePull: LFR_WORKTREE_SOURCES is empty" >&2
		return 1
	fi

	local head sha branch dir
	IFS=$'\t' read -r head sha < <(_lfrStep "Read ${repo}#${number}" gh pr view "${number}" --repo "${repo}" \
		--json headRefName,headRefOid --jq '[.headRefName, .headRefOid] | @tsv' 2>/dev/null)

	if [ -z "${sha}" ]; then
		echo "lfrWorktreePull: cannot read the head of ${repo}#${number}" >&2
		return 1
	fi

	branch="${head}"

	if git -C "${clone}" show-ref --verify --quiet "refs/heads/${branch}" &&
		[ "$(git -C "${clone}" rev-parse "${branch}")" != "${sha}" ]; then
		branch="${head}-pull-${number}"
	fi

	dir="$(_lfrWorktreeDir "${branch}")" || return 1

	if [ -e "${dir}" ]; then
		echo "lfrWorktreePull: ${repo}#${number} already has a worktree: ${dir}" >&2
		cd "${dir}" || return 1
		return 0
	fi

	echo "lfrWorktreePull: fetching ${repo}#${number} into the branch ${branch}..." >&2
	git -C "${clone}" fetch --no-tags "git@github.com:${repo}.git" \
		"+pull/${number}/head:refs/heads/${branch}" || return 1

	if [ "$(git -C "${clone}" rev-parse "${branch}")" != "${sha}" ]; then
		echo "lfrWorktreePull: the fetched head of ${repo}#${number} is not ${sha}" >&2
		return 1
	fi

	local back="${PWD}"
	cd "${clone}" || return 1
	lfrWorktree "${branch}" "$@" || { cd "${back}"; return 1; }
}

# Short aliases.
lfrw() { lfrWorktree "$@"; }
lfrwn() { lfrWorktreeRename "$@"; }
lfrwr() { lfrWorktreeRemove "$@"; }
lfrwcb() { lfrWorktreeCopyBundle "$@"; }
lfrwp() { lfrWorktreePull "$@"; }

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

# Carry the answer to IntelliJ's trust prompt from the project at $1 over to the one at
# $2, in every IDE version. $3 is the calling command, used only to prefix the messages.
#
# The prompt asks whether the authors of the files in that directory are trusted, and a
# rename changes neither the files nor their authors, so dropping the answer is the
# rename losing state it was asked to carry. It runs before _lfrWorktreeRemoveIdeaProject
# takes the old entry out, since that entry is where the answer is read from.
#
# lfrWorktreeIdeaInit carries the source clone's answer to the worktree for the same
# reason: a worktree checks out the same repository, so its authors are the clone's.
#
# The answer is copied rather than assumed: an entry can say value="false", and neither
# caller is a place to turn a no into a yes. Listing the repos directory in the neighbouring
# Trusted.Paths.Settings component would cost no code at all and is deliberately not
# done, since it would trust anything cloned there later, sight unseen.
#
# The entry is appended to the map rather than inserted in sorted position. IntelliJ
# reads it back as a map, so where it sits does not matter, and the file is rewritten in
# the IDE's own order the next time it closes.
_lfrWorktreeIdeaTrustProject() {
	local dir="${1}" new_dir="${2}" caller="${3}"
	local config_root="${XDG_CONFIG_HOME:-${HOME}/.config}/JetBrains"
	local -a keys=("${dir}")

	# A path under the home directory is stored through IntelliJ's $USER_HOME$ macro, so
	# look for that form too, and write the new path back in the form that matches it.
	case "${dir}" in
	"${HOME}"/*) keys+=("\$USER_HOME\$/${dir#"${HOME}"/}") ;;
	esac

	local new_key="${new_dir}"

	case "${new_dir}" in
	"${HOME}"/*) new_key="\$USER_HOME\$/${new_dir#"${HOME}"/}" ;;
	esac

	local config_dir key tmp trailing_newline trusted value
	for trusted in "${config_root}"/*/options/trusted-paths.xml; do
		[ -f "${trusted}" ] || continue

		config_dir="${trusted%/options/trusted-paths.xml}"
		value=""

		# The key is compared as a string instead of a pattern, the way the removal above
		# does it, since a project path holds regex metacharacters (liferay-portal-7.4.x)
		# and the $USER_HOME$ form is worse.
		for key in "${keys[@]}"; do
			value="$(awk -v key="${key}" '
				function trim(line) {
					sub(/^[[:space:]]+/, "", line)
					sub(/[[:space:]]+$/, "", line)

					return line
				}

				BEGIN {
					prefix = "<entry key=\"" key "\" value=\""
				}

				{
					line = trim($0)

					if (substr(line, 1, length(prefix)) == prefix) {
						value = substr(line, length(prefix) + 1)

						sub(/".*/, "", value)

						print value

						exit
					}
				}

				END {
					exit value == "" ? 1 : 0
				}
			' "${trusted}")" && break

			value=""
		done

		# This IDE was never asked about the old path, so there is no answer to carry.
		[ -n "${value}" ] || continue

		if grep -qF "<entry key=\"${new_key}\" " "${trusted}"; then
			echo "${caller}: ${config_dir##*/} already has an answer for ${new_dir}" >&2

			continue
		fi

		# IntelliJ writes these files without a trailing newline, which awk's print would
		# add. tail strips newlines, so output here means the last byte is not one.
		trailing_newline=1

		if [ -n "$(tail -c 1 "${trusted}")" ]; then
			trailing_newline=0
		fi

		tmp="$(mktemp)" || return 1

		awk -v key="${new_key}" -v value="${value}" '
			!inserted && /^[[:space:]]*<\/map>[[:space:]]*$/ {
				printf "        <entry key=\"%s\" value=\"%s\" />\n", key, value

				inserted = 1
			}

			{ print }

			END {
				exit !inserted
			}
		' "${trusted}" >"${tmp}" || {
			rm -f "${tmp}"

			echo "${caller}: ${config_dir##*/} holds no trusted paths map; left it alone" >&2

			continue
		}

		# Trim the copy, never the live file, as in _lfrWorktreeIdeaRecentProject below.
		if [ "${trailing_newline}" -eq 0 ]; then
			truncate -s -1 "${tmp}"
		fi

		# The file is the live configuration of an IDE that is merely closed, so prove the
		# edit parses before it lands rather than after.
		if command -v python3 >/dev/null 2>&1 &&
			! python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])' "${tmp}" >/dev/null 2>&1; then
			rm -f "${tmp}"

			echo "${caller}: the edited ${trusted} would not parse; left it alone" >&2

			return 1
		fi

		# Written back through the existing file to keep its mode and owner, the way the
		# entry removal above does.
		cat "${tmp}" >"${trusted}" || {
			rm -f "${tmp}"

			return 1
		}

		rm -f "${tmp}"

		echo "${caller}: ${config_dir##*/} carried the trust answer ${value} over to ${new_dir}" >&2
	done
}

# Carry IntelliJ's task-management state from the project at $1 over to the one at $2, in
# every IDE version. $3 is the calling command, used only to prefix the messages.
#
# The plugin keys that state by the project's directory name, so a rename leaves it under
# the old name and _lfrWorktreeRemoveIdeaProject then deletes it, which is right for a
# removal and is the rename throwing away state it was asked to carry. This runs before
# that removal, which is what keeps the removal's one job intact: with the files moved,
# its rm finds nothing under the old name and deletes nothing.
#
# Nothing is ever overwritten, and the reason is the key. It is the directory's name
# alone, never its path, so a worktree of the same name under another repo root shares
# the file, and a zip already sitting under the new name can belong to a project that is
# still there. It can also simply have outlived a worktree that went away by some route
# other than lfrWorktreeRemove. Either way the answer is the same: leave it, and leave
# the old one for the removal to delete, since overwriting is the one outcome that loses
# work.
_lfrWorktreeIdeaMoveTaskState() {
	local dir="${1}" new_dir="${2}" caller="${3}"
	local config_root="${XDG_CONFIG_HOME:-${HOME}/.config}/JetBrains"

	local slug="${dir##*/}"
	slug="${slug//[^[:alnum:]]/_}"

	local new_slug="${new_dir##*/}"
	new_slug="${new_slug//[^[:alnum:]]/_}"

	# Both names share one key, so there is nothing to move and the state is already
	# where it belongs.
	[ "${slug}" != "${new_slug}" ] || return 0

	local config_dir kind tasks
	for tasks in "${config_root}"/*/tasks; do
		[ -d "${tasks}" ] || continue

		config_dir="${tasks%/tasks}"

		# The two halves are moved one at a time rather than as a pair: the plugin writes
		# each when it has something to write, so one can be there without the other.
		for kind in tasks contexts; do
			[ -f "${tasks}/${slug}.${kind}.zip" ] || continue

			if [ -e "${tasks}/${new_slug}.${kind}.zip" ]; then
				echo "${caller}: ${config_dir##*/} already holds ${new_slug}.${kind}.zip, which is not this project's to overwrite; left both alone" >&2

				continue
			fi

			mv "${tasks}/${slug}.${kind}.zip" "${tasks}/${new_slug}.${kind}.zip" &&
				echo "${caller}: ${config_dir##*/} carried ${slug}.${kind}.zip over to ${new_slug}.${kind}.zip" >&2
		done
	done
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
# A nested checkout is always the folder portal/, and IntelliJ names a project after its
# folder when .idea/.name is not there. So each nested project was "portal", and the
# Welcome screen showed the full path to tell the 23 of them apart. The name of the home
# folder (liferay-portal-<branch>) gives each project its own name.
_lfrWorktreeIdeaName() {
	local dir="${1%/}"
	local home="${dir%/*}"

	[ "${dir##*/}" = portal ] && [ -d "${dir}/.idea" ] || return 0

	printf '%s' "${home##*/}" >"${dir}/.idea/.name"
}

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

	local title="${dir##*/}"
	[ -s "${dir}/.idea/.name" ] && title="$(cat "${dir}/.idea/.name")"

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

		awk -v key="${key}" -v now="${now}" -v title="${title}" '
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

		# Trim the copy, never the live file. Two runs trimming the file after each wrote it
		# cut its last byte twice, and the lost ">" emptied IntelliJ's recent projects list.
		if [ "${trailing_newline}" -eq 0 ]; then
			truncate -s -1 "${tmp}"
		fi

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

		echo "${caller}: ${config_dir##*/} now lists the project ${dir}" >&2
	done
}

_lfrWorktreeIdeaInitHelp() {
	cat <<-'EOF'
		lfrWorktreeIdeaInit - give a worktree the IntelliJ project a clone already has.

		Usage:
		  lfrWorktreeIdeaInit                       the worktree you are in
		  lfrWorktreeIdeaInit <branch|dir>          that worktree
		  lfrWorktreeIdeaInit <branch|dir> <src>    copy the project from that clone
		  lfrWorktreeIdeaInit <branch|dir> --redo   replace the project it already has
		  lfrWorktreeIdeaInit <branch|dir> --recent only the recent projects entry

		Copies the project model (modules.xml, libraries, code style, inspections,
		copyright) and every .iml, so the worktree opens as a configured project
		instead of a bare directory, and writes the source's run configurations into
		.idea/runConfigurations, which is what puts the Debug profiles in the picker.
		All of it is path-independent: modules.xml is written in $PROJECT_DIR$ terms,
		the .iml files in $MODULE_DIR$ ones, and a Remote debug configuration holds
		nothing but a host and a port.

		Left out on purpose: the data sources and their cached schema, which point at
		the source bundle's database and are most of the size; the shelf, which holds
		the source clone's own shelved changes; and any run configuration bound to a
		registered application server (the Tomcat ones), since that registration names
		the source clone's bundle and would start the wrong one. Attach to your own
		bundle with Debug portal and integration tests (8000) instead, the port
		start-liferay.sh --debug takes first.

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

		IntelliJ has to be closed before anything starts. It owns that file the same
		way it owns workspace.xml, writing it back from memory when it closes, so an
		entry written underneath it is gone before the restart that would show it.
		When it is running, you are asked to close it and confirm, y or n. A y is
		checked, and asked again while the IDE is still up; an n stops with nothing
		done. Without a terminal to ask at, it refuses instead.

		The source clone's answer to IntelliJ's trust prompt is carried over too, in
		every profile that has one, so the worktree opens without asking. A profile
		never asked about the source gets nothing, and a no stays a no.

		--recent runs the trust and recent projects steps alone, on a worktree whose
		project is already there. It is how a project you removed from the welcome
		screen comes back, since the alternative is a --redo, which wipes .idea and
		re-copies every .iml to write one line of XML. It waits for IntelliJ to be closed the same way.
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
		# A branch name: the worktree lfrWorktree makes for it, else the worktree git has
		# that branch checked out in.
		local name="${dir}" other

		dir="$(_lfrWorktreeDir "${name}" "${wt_root}")" || return 1

		if [ ! -d "${dir}" ]; then
			if other="$(git -C "${src}" worktree list --porcelain 2>/dev/null |
					awk -v branch="refs/heads/${name}" '
						/^worktree /  { path = substr($0, 10) }
						$0 == "branch " branch { print path; exit }
					')" && [ -n "${other}" ]; then
				dir="${other}"
			fi
		fi
	fi

	if [ ! -d "${dir}" ]; then
		echo "lfrWorktreeIdeaInit: ${dir} does not exist" >&2

		return 1
	fi

	# --recent is the whole run for a worktree already carrying its project, so the source
	# is read only for its trust answer and checked for nothing else.
	if [ -n "${recent}" ]; then
		dir="$(cd "${dir}" && pwd)" || return 1

		if [ ! -f "${dir}/.idea/modules.xml" ]; then
			echo "lfrWorktreeIdeaInit: ${dir} has no IntelliJ project yet; run it without --recent first" >&2

			return 1
		fi

		_lfrWorktreeIdeaWaitClosed lfrWorktreeIdeaInit || return 1

		if src="$(cd "${src}" 2>/dev/null && pwd)" && [ "${dir}" != "${src}" ]; then
			_lfrWorktreeIdeaTrustProject "${src}" "${dir}" lfrWorktreeIdeaInit
		fi

		_lfrWorktreeIdeaName "${dir}"
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

	if [ -f "${dir}/.idea/modules.xml" ] && [ -z "${redo}" ]; then
		echo "lfrWorktreeIdeaInit: ${dir} already has an IntelliJ project; pass --redo to replace it" >&2

		return 1
	fi

	_lfrWorktreeIdeaWaitClosed lfrWorktreeIdeaInit || return 1

	if [ -f "${dir}/.idea/modules.xml" ]; then
		rm -rf "${dir}/.idea" || return 1

		echo "lfrWorktreeIdeaInit: replacing the project already in ${dir}" >&2
	fi

	mkdir -p "${dir}/.idea" || return 1

	# --ignore-existing so the few .idea files the repo tracks keep the branch's own
	# version. The excludes are the state that belongs to the source clone alone, and
	# workspace.xml with them: the run configurations worth having are pulled out of it
	# below, and the rest of it is that clone's open editors and window layout.
	echo "lfrWorktreeIdeaInit: copying the project model from ${src}..." >&2

	_lfrStep "Copy the project model from ${src}" rsync --archive --ignore-existing \
		--exclude=dataSources --exclude='dataSources*.xml' --exclude=easycode \
		--exclude=shelf --exclude=workspace.xml \
		"${src}/.idea/" "${dir}/.idea/" || return 1

	echo "lfrWorktreeIdeaInit: copied the project model into ${dir}/.idea" >&2

	# The copy brings the .name of the source clone, so write the name of this one over it.
	_lfrWorktreeIdeaName "${dir}"

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

	_lfrSpinStart "Scan ${src} for .iml files"
	(cd "${src}" && find . -name '*.iml' -not -path '*/node_modules/*' -printf '%P\n') |
		sort | comm -23 - "${tracked}" >"${list}"
	_lfrSpinStop

	if [ -s "${list}" ]; then
		echo "lfrWorktreeIdeaInit: copying $(wc -l <"${list}") .iml files..." >&2

		_lfrSpinStart "Copy the .iml files"
		tar --create --directory="${src}" --files-from="${list}" --file=- |
			tar --extract --directory="${dir}" --file=- || {
			_lfrSpinStop
			rm -f "${list}" "${tracked}"

			return 1
		}
		_lfrSpinStop

		echo "lfrWorktreeIdeaInit: copied $(wc -l <"${list}") .iml files" >&2
	fi

	rm -f "${list}" "${tracked}"

	_lfrWorktreeIdeaRunConfigurations "${src}" "${dir}" || return 1

	_lfrWorktreeIdeaTrustProject "${src}" "${dir}" lfrWorktreeIdeaInit

	_lfrWorktreeIdeaRecentProject "${dir}"
}
