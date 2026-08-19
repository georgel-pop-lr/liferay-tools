# lfr-ant.sh — guarded `ant all` (the lfrAntAll command).
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
# from LfrBundle; the shared-bundle lookup (_lfrShareReposForBundle) from LfrShare.

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

lfrAntAll() {
	case "${1-}" in
	-h | --help)
		cat <<-'EOF'
			lfrAntAll — run `ant all` in this repo, with safety guards.

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
		EOF
		return 0
		;;
	esac

	local force=0 clear=1 a
	local -a antargs=()
	for a in "$@"; do
		case "${a}" in
		-f | --force) force=1 ;;
		-nc | --no-clear) clear=0 ;;
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
				echo "lfrAntAll: this repo's bundle is running (PID ${pid}). Stop it first (lfrBundle), or pass --force:" >&2
				printf '  %s\n' "${mine}" >&2
				return 1
			fi
		elif [ -n "$(_lfrBundleProcs)" ]; then
			echo "lfrAntAll: a Liferay bundle is running. Stop it first (lfrBundle), or pass --force:" >&2
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

	# Past every guard and holding the lock, so this build is going to happen: wipe
	# the terminal and say what is being built, the way the bundle launcher does.
	# Wiping here and not earlier is what keeps a guard's refusal readable, and the
	# stale-lock notice is held back to here for the same reason.
	[ "${clear}" = 1 ] && declare -F _lfrClearScreen >/dev/null 2>&1 && _lfrClearScreen
	[ -n "${notice}" ] && echo "${notice}" >&2
	echo "Repo   : ${PWD}"
	echo "Bundle : ${mine:-unresolved}"
	echo "Command: ant all${antargs[*]:+ ${antargs[*]}}"
	echo

	# Run under the lock in a subshell so its cleanup trap is local and fires on
	# normal exit or interrupt, releasing the lock either way.
	(
		trap 'rm -rf "${lockdir}"' EXIT INT TERM
		echo "${BASHPID}" >"${lockdir}/pid"
		printf 'pid %s, repo %s, since %s\n' "${BASHPID}" "${mine:-${PWD}}" "$(date '+%F %T')" >"${lockdir}/info"
		ant all "${antargs[@]}"
	)
}

# Short alias.
lfraa() { lfrAntAll "$@"; }
