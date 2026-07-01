# lfr-bundle.sh — start/stop Liferay bundles by toggling (the lfrBundle command).
#
# Loaded via the root lfrTools.sh. Defines lfrBundle (short alias lfrb):
#   lfrBundle [<bundle>] [start-flags]  toggle a bundle: start it if stopped
#                                       (forwarding start-flags to start-liferay.sh),
#                                       stop it if running. With no <bundle> a
#                                       picker shows every bundle's state; Esc cancels.
#   lfrBundle status                    list the running bundles and their ports
#   lfrBundle stop-all                  stop every running bundle (confirms)
#
# A running bundle is a java process started by `catalina.sh run`, so it carries
# -Dcatalina.base=<bundle>/tomcat-x.y.z; that is how we find them. Ports come
# from ss, so auto-picked ports show their real value. A bundle cannot run twice
# safely (a second instance shares the same catalina.base, database, and OSGi
# state), so there is only a toggle, never a blind second start.
#
# lfrRunBundle / lfrrb remain as back-compat aliases for lfrBundle.

_lfrBundleDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Echo "<pid>\t<catalina.base>" for every running Liferay/Tomcat process.
_lfrBundleProcs() {
	local pid base
	for pid in $(pgrep -f -- '-Dcatalina.base=' 2>/dev/null); do
		base="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null |
			grep -oE -- '-Dcatalina.base=[^ ]+' | head -1 | cut -d= -f2-)"
		[ -n "${base}" ] && printf '%s\t%s\n' "${pid}" "${base}"
	done
}

# Echo the sorted TCP ports a pid is listening on (space separated).
_lfrBundlePorts() {
	command -v ss >/dev/null 2>&1 || return 0
	ss -ltnpH 2>/dev/null |
		awk -v p="pid=${1}," '$0 ~ p { n = split($4, a, ":"); print a[n] }' |
		sort -nu | paste -sd' ' -
}

# Print the status table; sets the global _lfrBundleCount.
_lfrBundleList() {
	local pid base name ports n=0
	while IFS=$'\t' read -r pid base; do
		[ -n "${pid}" ] || continue
		name="$(basename "$(dirname "${base}")")"
		ports="$(_lfrBundlePorts "${pid}")"
		printf '  PID %-7s %-28s ports: %s\n' "${pid}" "${name}" "${ports:-?}"
		n=$((n + 1))
	done < <(_lfrBundleProcs)
	_lfrBundleCount="${n}"
}

# SIGTERM, wait up to 10s for a clean shutdown, then SIGKILL if still alive.
_lfrBundleKill() {
	local pid="${1}" name="${2}" i
	echo "Stopping ${name} (PID ${pid})..."
	kill "${pid}" 2>/dev/null || { echo "  could not signal ${pid}" >&2; return 1; }
	for i in $(seq 1 10); do
		kill -0 "${pid}" 2>/dev/null || { echo "  stopped cleanly."; return 0; }
		sleep 1
	done
	echo "  still alive after 10s, forcing (SIGKILL)..."
	kill -9 "${pid}" 2>/dev/null && echo "  killed."
}

# Stop the given "<pid>\t<base>" lines.
_lfrBundleStopLines() {
	local pid base name
	while IFS=$'\t' read -r pid base; do
		[ -n "${pid}" ] || continue
		name="$(basename "$(dirname "${base}")")"
		_lfrBundleKill "${pid}" "${name}"
	done
}

# Stop every running bundle, after confirming.
_lfrBundleStopAll() {
	local procs ans
	procs="$(_lfrBundleProcs)"
	if [ -z "${procs}" ]; then
		echo "No running Liferay bundles."
		return 0
	fi
	echo "Running Liferay bundles:"
	_lfrBundleList
	printf 'Stop all %s? [y/N] ' "${_lfrBundleCount}"
	read -r ans
	case "${ans}" in
	y | Y | yes) printf '%s\n' "${procs}" | _lfrBundleStopLines ;;
	*) echo "cancelled." ;;
	esac
}

# Echo the pid of the bundle running from <dir> (parent of its catalina.base),
# or nothing if that bundle is not running.
_lfrBundlePidForDir() {
	local want="${1}" pid base
	while IFS=$'\t' read -r pid base; do
		[ "$(dirname "${base}")" = "${want}" ] && { printf '%s\n' "${pid}"; return 0; }
	done < <(_lfrBundleProcs)
	return 1
}

# Toggle one bundle by path: stop it if running, otherwise start it. Any extra
# args are start-liferay.sh flags, forwarded only on the start path.
_lfrBundleToggleOne() {
	local path="${1}" pid
	shift
	pid="$(_lfrBundlePidForDir "${path}")"
	if [ -n "${pid}" ]; then
		_lfrBundleKill "${pid}" "$(basename "${path}")"
	else
		"${_lfrBundleDir}/start-liferay.sh" "$@" "${path}"
	fi
}

# Resolve a bundle argument to a path: an existing dir is used directly, a bare
# name is matched against the discovered bundles.
_lfrBundleResolve() {
	local arg="${1}" matches=() path name
	[ -d "${arg}" ] && { (cd "${arg}" && pwd); return 0; }
	while IFS=$'\t' read -r path name; do
		[ "$(basename "${path}")" = "${arg}" ] && matches+=("${path}")
	done < <(_lfrBundleEntries)
	case "${#matches[@]}" in
	1) printf '%s\n' "${matches[0]}" ;;
	0) echo "lfrBundle: bundle '${arg}' not found under: ${LFR_BUNDLES_DIRS[*]}" >&2; return 1 ;;
	*) echo "lfrBundle: '${arg}' matches multiple, pass a path:" >&2
		printf '  %s\n' "${matches[@]}" >&2; return 1 ;;
	esac
}

# Toggle a bundle. $1 is an optional bundle name/path (empty opens the picker);
# the rest are start-liferay.sh flags forwarded when starting a stopped bundle.
_lfrBundleToggle() {
	local name="${1-}"
	shift 2>/dev/null
	local path running pid base entries epath ename pidfor state
	if [ -n "${name}" ]; then
		path="$(_lfrBundleResolve "${name}")" || return 1
		_lfrBundleToggleOne "${path}" "$@"
		return
	fi

	# Picker over every known bundle, each labelled with its current state.
	if ! declare -F _lfrBundleEntries >/dev/null 2>&1; then
		echo "lfrBundle: bundle list needs LfrCommon loaded; pass a bundle name." >&2
		return 1
	fi
	running=""
	while IFS=$'\t' read -r pid base; do
		[ -n "${pid}" ] && running+="$(dirname "${base}")"$'\t'"${pid}"$'\n'
	done < <(_lfrBundleProcs)
	entries=""
	while IFS=$'\t' read -r epath ename; do
		[ -n "${epath}" ] || continue
		pidfor="$(printf '%s' "${running}" | awk -F'\t' -v p="${epath}" '$1==p{print $2; exit}')"
		if [ -n "${pidfor}" ]; then
			state="RUNNING pid ${pidfor}, ports: $(_lfrBundlePorts "${pidfor}")"
		else
			state="stopped"
		fi
		entries+="${epath}"$'\t'"${ename}  [${state}]"$'\n'
	done < <(_lfrBundleEntries)
	[ -z "${entries}" ] && { echo "lfrBundle: no bundles found under: ${LFR_BUNDLES_DIRS[*]}" >&2; return 1; }
	path="$(printf '%s' "${entries}" | _lfrPick 'toggle bundle> ')" || return 1
	_lfrBundleToggleOne "${path}" "$@"
}

lfrBundle() {
	case "${1-}" in
	status | ls)
		if [ -z "$(_lfrBundleProcs)" ]; then
			echo "No running Liferay bundles."
			return 0
		fi
		echo "Running Liferay bundles:"
		_lfrBundleList
		echo "  (${_lfrBundleCount} running)"
		return 0
		;;
	stop-all | stopall)
		_lfrBundleStopAll
		return 0
		;;
	help | -h | --help)
		echo "usage: lfrBundle [<bundle>] [start-flags] | status | stop-all"
		echo "  Shows each bundle's state and toggles the one you pick or name:"
		echo "  a stopped bundle is started (start-flags like -c are forwarded),"
		echo "  a running one is stopped. Esc cancels. stop-all stops every bundle."
		return 0
		;;
	esac

	# Toggle: an optional leading bundle name (first non-flag arg), then flags
	# forwarded to start-liferay.sh when starting a stopped bundle.
	local name=""
	if [ "$#" -gt 0 ] && [ "${1#-}" = "${1}" ]; then
		name="${1}"
		shift
	fi
	_lfrBundleToggle "${name}" "$@"
}

# Short alias, plus back-compat aliases (they now toggle like lfrBundle).
lfrb() { lfrBundle "$@"; }
lfrRunBundle() { lfrBundle "$@"; }
lfrrb() { lfrBundle "$@"; }
