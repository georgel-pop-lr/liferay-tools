# lfr-ant.sh - guarded `ant all` (the lfrAntAll command).
#
# Loaded via the root lfrTools.sh. Defines lfrAntAll (short alias lfraa): run
# `ant all` in the current repo, with three guards:
#   1. Refuse if THIS repo's Liferay bundle is running. A full build while that
#      server is up risks partial deploys, locked osgi/state and work/temp, and a
#      corrupt runtime. A bundle from an unrelated checkout is left alone.
#   2. Refuse if the target bundle is SHARED via lfrShare. `ant all` rebuilds and
#      overwrites the bundle it deploys into, so building into a shared bundle
#      clobbers it for every repo pointing at it (and defeats the point of
#      sharing, which is to run a prebuilt bundle without rebuilding).
#   3. Refuse to run two `ant all` at once (machine-wide, per user). Concurrent
#      full builds thrash and can corrupt the shared Gradle build cache.
# After a good build it stamps the bundle with the commit (.lfr-build-head), which
# lfrWorktree reads to copy that bundle into a new worktree.
# Pass --force / -f to bypass guards 1 and 2. Guard 3 (one at a time) is always
# enforced; a stale lock from a dead build is reclaimed automatically. Any extra
# args are forwarded to `ant all`.
#
# Once the guards pass, the terminal is wiped (screen and scrollback) and the
# build announces what it is building, so the window holds this build and nothing
# before it: `ant all` prints thousands of lines and the run before it is only in
# the way. A guard that refuses never wipes, so its message stays where you can
# read it. Pass --no-clear / -nc, or set LFR_CLEAR_SCREEN=0, to keep the
# terminal as it is.
#
# Bundle detection (_lfrBundleProcs / _lfrBundleList / _lfrBundlePidForDir) comes
# from LfrBundles; the shared-bundle lookup (_lfrShareReposForBundle) from LfrShare.

# Echo the app-server bundle dir that `ant all` in the current repo deploys into:
# read app.server.parent.dir from app.server.${USER}.properties (falling back to
# app.server.properties), substitute ${project.dir} with the portal root, and
# canonicalize. Echoes nothing (rc 1) when it cannot be resolved, so callers fall
# back to the conservative "any running bundle" check.
_lfrRepoBundleDir() {
	local root="${PWD}" props val=""
	# Portal root is the nearest ancestor holding app.server.properties.
	while [ "${root}" != "/" ] && [ ! -f "${root}/app.server.properties" ]; do
		root="$(dirname "${root}")"
	done
	[ -f "${root}/app.server.properties" ] || return 1

	for props in "${root}/app.server.${USER}.properties" "${root}/app.server.properties"; do
		[ -f "${props}" ] || continue
		val="$(sed -n 's/^[[:space:]]*app\.server\.parent\.dir[[:space:]]*=[[:space:]]*//p' "${props}" | tail -1)"
		[ -n "${val}" ] && break
	done
	[ -n "${val}" ] || return 1

	val="${val//\$\{project.dir\}/${root}}"
	case "${val}" in *'${'*) return 1 ;; esac # unresolved var -> give up
	# A running bundle's dir exists, so cd/pwd canonicalizes it to match what
	# _lfrBundlePidForDir sees; when it does not exist there is nothing to match.
	(cd "${val}" 2>/dev/null && pwd) || printf '%s\n' "${val}"
}

# Echo the base commit for the changed-module check: the merge base of HEAD with
# the first master ref that exists. Echoes nothing (rc 1) when none resolves.
_lfrAntPrecheckBase() {
	local ref
	for ref in upstream/master origin/master master; do
		git rev-parse --verify --quiet "${ref}" >/dev/null || continue
		git merge-base HEAD "${ref}" 2>/dev/null && return 0
	done
	return 1
}

# Echo the portal core directories whose source is newer than their snapshot jar
# in the repo's .m2, or whose snapshot jar is missing. Modules compile against
# those jars, so a stale one gives errors that `ant all` would not give.
_lfrAntPrecheckStaleCore() {
	local root="$1" dir artifact jar
	for dir in portal-impl portal-kernel portal-test util-bridges util-java util-slf4j util-taglib; do
		[ -d "${root}/${dir}/src" ] || continue
		case "${dir}" in
		portal-*) artifact="com.liferay.portal.${dir#portal-}" ;;
		util-*) artifact="com.liferay.util.${dir#util-}" ;;
		esac
		jar="$(ls -t "${root}/.m2/com/liferay/portal/${artifact}"/*-SNAPSHOT/"${artifact}"-*-SNAPSHOT.jar 2>/dev/null | command grep -v -- '-sources\.jar$' | head -1)"
		if [ -z "${jar}" ] || [ -n "$(find "${root}/${dir}/src" -type f -newer "${jar}" -print -quit 2>/dev/null)" ]; then
			echo "${dir}"
		fi
	done
}

# Build the jar of each module the branch changes, so a compile, bnd, or frontend
# error shows in a minute or two, not after ten minutes of `ant all`. A module
# counts when it carries .lfrbuild-portal (what `ant all` deploys) and has a
# file changed since the merge base with master: committed, staged, unstaged, or
# untracked. Returns 0 when the build passes or the check is skipped, 4 when it
# fails. With -n, it only prints the Gradle tasks.
_lfrAntPrecheck() {
	local dryrun=0
	[ "${1-}" = "-n" ] && dryrun=1

	local root
	root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
		echo "lfrAntAll precheck: not in a git repo, skipped." >&2
		return 0
	}
	[ -f "${root}/modules/settings.gradle" ] || {
		echo "lfrAntAll precheck: no modules/settings.gradle, skipped." >&2
		return 0
	}

	local base
	base="$(cd "${root}" && _lfrAntPrecheckBase)" || {
		echo "lfrAntAll precheck: no master ref to compare with, skipped." >&2
		return 0
	}

	local stale
	stale="$(_lfrStep "Check the portal core jars" _lfrAntPrecheckStaleCore "${root}" | tr '\n' ' ')"
	if [ -n "${stale}" ]; then
		echo "lfrAntAll precheck: skipped, the portal core snapshot is older than its source (${stale% }). Only 'ant all' rebuilds it." >&2
		return 0
	fi

	local -a tasks=()
	local file dir rel
	declare -A seen=()
	while IFS= read -r file; do
		case "${file}" in modules/*) ;; *) continue ;; esac
		dir="${root}/$(dirname "${file}")"
		while [ "${dir}" != "${root}/modules" ] && [ "${dir}" != "/" ]; do
			if [ -f "${dir}/bnd.bnd" ] && [ -f "${dir}/build.gradle" ]; then
				break
			fi
			dir="$(dirname "${dir}")"
		done
		[ -f "${dir}/.lfrbuild-portal" ] || continue
		rel="${dir#"${root}/modules/"}"
		[ -n "${seen[${rel}]-}" ] && continue
		seen[${rel}]=1
		tasks+=(":${rel//\//:}:jar")
	done < <(cd "${root}" && { git diff --name-only "${base}"; git ls-files --others --exclude-standard; } | sort -u)

	if [ "${#tasks[@]}" = 0 ]; then
		echo "lfrAntAll precheck: no changed module that 'ant all' deploys, skipped." >&2
		return 0
	fi

	echo "lfrAntAll precheck: building ${#tasks[@]} changed module(s) before 'ant all':"
	printf '  %s\n' "${tasks[@]}"
	[ "${dryrun}" = 1 ] && return 0

	local log
	log="$(_lfrAntLogFile precheck)"
	echo "  Log: ${log}"

	local start=${SECONDS} rc took
	printf 'Start  : %s\nRepo   : %s\nHEAD   : %s\nTasks  : %s\n\n' "$(date '+%F %T')" "${root}" \
		"$(git -C "${root}" log -1 --format='%h %s' 2>/dev/null)" "${tasks[*]}" >"${log}"
	_lfrSpinStart "Build the ${#tasks[@]} changed module(s)"
	(cd "${root}/modules" && "${root}/gradlew" --console=plain "${tasks[@]}" </dev/null >>"${log}" 2>&1)
	rc=$?
	_lfrSpinStop
	took=$((SECONDS - start))
	printf '\nEnd    : %s (exit %s)\nTook   : %dm %02ds\n' "$(date '+%F %T')" "${rc}" \
		$((took / 60)) $((took % 60)) >>"${log}"

	if [ "${rc}" = 0 ]; then
		echo "lfrAntAll precheck: passed."
		return 0
	fi

	echo "lfrAntAll precheck: FAILED, so 'ant all' did not start. Fix the errors, or pass --no-precheck:" >&2
	{
		command grep -E '^> Task .* FAILED$|: error: ' "${log}" | head -30
		sed -n '/^\* What went wrong:/,/^\* Try:/p' "${log}" | command grep -vE '^\* Try:|^$' | head -10
	} | sed -e "s|${root}/||" -e 's/^/  /' >&2
	echo "  Full log: ${log}" >&2
	return 4
}

# Run the precheck alone, for example after an edit, without `ant all`.
lfrAntAllPrecheck() {
	case "${1-}" in
	-h | --help)
		cat <<-'EOF'
			lfrAntAllPrecheck - build the jar of each module this branch changes.

			It runs the same check that lfrAntAll runs before `ant all`, alone. A
			module counts when it has .lfrbuild-portal and a file changed since the
			merge base with master (committed, staged, unstaged, or untracked).

			Usage:
			  lfrAntAllPrecheck     build the changed modules
			  lfrAntAllPrecheck -n  only print the Gradle tasks
		EOF
		return 0
		;;
	esac

	local holder
	holder="$(cat "${TMPDIR:-/tmp}/lfr-ant-all.${USER}.lock.d/pid" 2>/dev/null)"
	if [ -n "${holder}" ] && kill -0 "${holder}" 2>/dev/null && [ "${1-}" != "-n" ]; then
		echo "lfrAntAllPrecheck: an 'ant all' is running (PID ${holder}); wait for it to end." >&2
		return 3
	fi

	_lfrAntPrecheck "$@"
}

lfrAntAll() {
	case "${1-}" in
	-h | --help)
		cat <<-'EOF'
			lfrAntAll - run `ant all` in this repo, with safety guards.

			Refuses when:
			  - this repo's Liferay server is running (a full build can corrupt it),
			  - the target bundle is shared via lfrShare (ant all would overwrite the
			    shared bundle), or
			  - another `ant all` is already running (only one at a time).

			Usage:
			  lfrAntAll [ant-args]  run `ant all`; extra args are forwarded to ant
			  lfrAntAll -f          bypass the running-server and shared-bundle guards
			                        (--force); the one-at-a-time lock still applies
			  lfrAntAll -nc         keep the terminal as it is (--no-clear); by
			                        default it is wiped once the guards pass, so only
			                        this build's output is there
			  lfrAntAll -np         skip the precheck (--no-precheck); by default the
			                        modules the branch changes are built first, so a
			                        compile error stops the run in a minute or two

			After a good build, it writes .lfr-build-head in the bundle with the commit
			(clean=1 when the tree had no local change). lfrWorktree reads it to copy
			the bundle into a new worktree.
		EOF
		return 0
		;;
	esac

	local force=0 clear=1 precheck="${LFR_ANT_PRECHECK:-1}" a
	local -a antargs=()
	for a in "$@"; do
		case "${a}" in
		-f | --force) force=1 ;;
		-nc | --no-clear) clear=0 ;;
		-np | --no-precheck) precheck=0 ;;
		*) antargs+=("${a}") ;;
		esac
	done

	local mine
	mine="$(_lfrRepoBundleDir)" || mine=""

	# Guard 1: refuse if this repo's bundle (or, if unresolved, any bundle) runs.
	if [ "${force}" != 1 ] && declare -F _lfrBundleProcs >/dev/null 2>&1; then
		local pid
		if [ -n "${mine}" ] && declare -F _lfrBundlePidForDir >/dev/null 2>&1; then
			if pid="$(_lfrBundlePidForDir "${mine}")"; then
				echo "lfrAntAll: this repo's bundle is running (PID ${pid}). Stop it first (lfrBundles), or pass --force:" >&2
				printf '  %s\n' "${mine}" >&2
				return 1
			fi
		elif [ -n "$(_lfrBundleProcs)" ]; then
			echo "lfrAntAll: a Liferay bundle is running. Stop it first (lfrBundles), or pass --force:" >&2
			_lfrBundleList >&2
			return 1
		fi
	fi

	# Guard 2: refuse if the target bundle is shared via lfrShare, since a full
	# build overwrites it for every repo that points at it.
	if [ "${force}" != 1 ] && [ -n "${mine}" ] && declare -F _lfrShareReposForBundle >/dev/null 2>&1; then
		local sharers
		sharers="$(_lfrShareReposForBundle "${mine}")"
		if [ -n "${sharers}" ]; then
			echo "lfrAntAll: target bundle is shared via lfrShare by: ${sharers}" >&2
			echo "  A full 'ant all' would rebuild and overwrite it. Reset the share first (lfrShare reset), or pass --force:" >&2
			printf '  %s\n' "${mine}" >&2
			return 1
		fi
	fi

	# Guard 3: one `ant all` at a time, machine-wide per user. A mkdir lock (not a
	# held-open flock fd, which a lingering Gradle daemon could inherit and never
	# release); a stale lock whose holder has died is reclaimed.
	local lockdir="${TMPDIR:-/tmp}/lfr-ant-all.${USER}.lock.d" notice=""
	if ! mkdir "${lockdir}" 2>/dev/null; then
		local holder
		holder="$(cat "${lockdir}/pid" 2>/dev/null)"
		if [ -n "${holder}" ] && kill -0 "${holder}" 2>/dev/null; then
			echo "lfrAntAll: another 'ant all' is already running; only one at a time." >&2
			[ -f "${lockdir}/info" ] && sed 's/^/  /' "${lockdir}/info" >&2
			return 3
		fi
		notice="lfrAntAll: cleared a stale ant-all lock (holder ${holder:-?} was gone)."
		rm -rf "${lockdir}"
		mkdir "${lockdir}" 2>/dev/null || { echo "lfrAntAll: could not acquire lock ${lockdir}" >&2; return 1; }
	fi

	# Guard 4: build the modules the branch changes first, under the lock, so a
	# compile error stops the run in a minute or two. Its refusal is printed before
	# the wipe, so it stays readable.
	if [ "${precheck}" = 1 ] && ! _lfrAntPrecheck; then
		rm -rf "${lockdir}"
		return 4
	fi

	# Past every guard and holding the lock, so this build is going to happen: wipe
	# the terminal and say what is being built, the way the bundle launcher does.
	# Wiping here and not earlier is what keeps a guard's refusal readable, and the
	# stale-lock notice is held back to here for the same reason.
	[ "${clear}" = 1 ] && declare -F _lfrClearScreen >/dev/null 2>&1 && _lfrClearScreen
	[ -n "${notice}" ] && echo "${notice}" >&2
	echo "Repo   : ${PWD}"
	echo "Bundle : ${mine:-unresolved}"
	echo "Command: ant all${antargs[*]:+ ${antargs[*]}}"

	local log
	log="$(_lfrAntLogFile)"
	echo "Log    : ${log}"
	echo

	# Run under the lock in a subshell so its cleanup trap is local and fires on
	# normal exit or interrupt, releasing the lock either way. The output also goes
	# to the log, because ant prints only the Gradle summary of a failed task, and
	# the real error is thousands of lines above it.
	(
		trap 'rm -rf "${lockdir}"' EXIT INT TERM
		echo "${BASHPID}" >"${lockdir}/pid"
		printf 'pid %s, repo %s, since %s\n' "${BASHPID}" "${mine:-${PWD}}" "$(date '+%F %T')" >"${lockdir}/info"
		{
			printf 'Start  : %s\nRepo   : %s\nHEAD   : %s\nBundle : %s\nCommand: ant all%s\n\n' \
				"$(date '+%F %T')" "${PWD}" "$(git log -1 --format='%h %s' 2>/dev/null)" \
				"${mine:-unresolved}" "${antargs[*]:+ ${antargs[*]}}"
			start=${SECONDS}
			_lfrAntStampBuild "${mine}" ant all "${antargs[@]}" 2>&1
			rc=$?
			took=$((SECONDS - start))
			printf '\nEnd    : %s (exit %s)\nTook   : %dm %02ds\n' "$(date '+%F %T')" "${rc}" \
				$((took / 60)) $((took % 60))
			exit "${rc}"
		} | tee "${log}"
		rc=${PIPESTATUS[0]}
		[ "${rc}" != 0 ] && _lfrAntFailureSummary "${log}"
		exit "${rc}"
	)
}

# The folder of the lfrAntAll logs, next to this script, with one subfolder for
# each worktree. The .gitignore of lfrTools ignores it.
_LFR_ANT_LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs"

# Echo the path of a new log file in the folder of the worktree where lfrAntAll
# runs, named after the start time, and delete the logs older than 30 days. With
# a kind in $1 (for example precheck), the kind goes between the worktree and the
# time in the name.
_lfrAntLogFile() {
	_lfrLogFile "${_LFR_ANT_LOG_DIR}" "${1-}"
}

# Print the error lines of a failed ant all log: the yarn and javac errors, the
# Gradle "What went wrong" block, and the ant BUILD FAILED reason.
_lfrAntFailureSummary() {
	local log="$1"
	{
		echo
		echo "lfrAntAll: FAILED. The error lines of the log:"
		sed -E 's/^[[:space:]]*\[[a-z-]+\][[:space:]]?//' "${log}" |
			command grep -E -A3 '^(error|ERR!) |: error: |^> Task .* FAILED$|^\* What went wrong:|^BUILD FAILED' |
			command grep -vE '^\* Try:|^--$|^[[:space:]]*$' | head -40
		echo "  Full log: ${log}"
	} >&2
}

# The stamp that lfrWorktree reads before it copies a bundle. It says which commit the
# bundle holds, so a worktree cut from that commit runs on the same code as its bundle.
_LFR_BUILD_STAMP=".lfr-build-head"

# Run the build command in $2.. and stamp the bundle $1 when it passes. The old stamp is
# removed first, since the build changes the bundle whether it passes or not. The stamp
# says clean=1 only when the tree had no tracked change before and after the build, and
# HEAD did not move: then the bundle holds exactly that commit.
_lfrAntStampBuild() {
	local bundle="${1}"
	shift

	if [ -z "${bundle}" ] || [ ! -d "${bundle}" ]; then
		"$@"

		return
	fi

	local stamp="${bundle}/${_LFR_BUILD_STAMP}"
	local head branch clean=1 rc

	rm -f "${stamp}"

	head="$(git rev-parse HEAD 2>/dev/null)"
	branch="$(git branch --show-current 2>/dev/null)"

	if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
		clean=0
	fi

	"$@"
	rc=$?

	if [ "${rc}" != 0 ] || [ -z "${head}" ]; then
		return "${rc}"
	fi

	if [ "$(git rev-parse HEAD 2>/dev/null)" != "${head}" ] ||
			[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
		clean=0
	fi

	printf 'commit=%s\nbranch=%s\nrepo=%s\nclean=%s\nbuilt=%s\n' \
		"${head}" "${branch:-detached}" "$(git rev-parse --show-toplevel)" "${clean}" \
		"$(date '+%F %T')" >"${stamp}"

	echo "lfrAntAll: stamped ${stamp} (commit ${head:0:13}, clean=${clean})" >&2

	return "${rc}"
}

# Short alias.
lfraa() { lfrAntAll "$@"; }
