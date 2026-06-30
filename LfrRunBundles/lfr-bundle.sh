# lfr-bundle.sh — run and stop Liferay bundles (the lfrBundle command).
#
# Loaded via the root lfrTools.sh. Defines lfrBundle (short alias lfrb):
#   lfrBundle run [args]   start a bundle (wraps start-liferay.sh, passes flags)
#   lfrBundle stop [all]   stop running bundles (picker; 'all' stops every one)
#   lfrBundle status       list running bundles with their PIDs and ports
#   lfrBundle              (no args) same as status
#
# A running bundle is a java process started by `catalina.sh run`, so it carries
# -Dcatalina.base=<bundle>/tomcat-x.y.z; that is how we find them. Ports come
# from ss, so auto-picked ports show their real value.
#
# lfrRunBundle / lfrrb stay as back-compat aliases for `lfrBundle run`.

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

# Stop running bundles: 'all' stops every one, otherwise pick which to stop.
_lfrBundleStop() {
	local sub="${1-}" procs entries pid base name ports sel line
	procs="$(_lfrBundleProcs)"
	if [ -z "${procs}" ]; then
		echo "No running Liferay bundles."
		return 0
	fi

	echo "Running Liferay bundles:"
	_lfrBundleList

	if [ "${sub}" = "all" ]; then
		local ans
		printf 'Stop all %s? [y/N] ' "${_lfrBundleCount}"
		read -r ans
		case "${ans}" in
		y | Y | yes) printf '%s\n' "${procs}" | _lfrBundleStopLines ;;
		*) echo "cancelled." ;;
		esac
		return 0
	fi

	echo
	# Build "<pid>\t<base>\t<label>": the picker shows the label, we keep pid+base.
	entries=""
	while IFS=$'\t' read -r pid base; do
		[ -n "${pid}" ] || continue
		name="$(basename "$(dirname "${base}")")"
		ports="$(_lfrBundlePorts "${pid}")"
		entries+="${pid}"$'\t'"${base}"$'\t'"PID ${pid}  ${name}  [ports: ${ports:-?}]"$'\n'
	done < <(_lfrBundleProcs)

	if command -v fzf >/dev/null 2>&1; then
		sel="$(printf '%s' "${entries}" | fzf \
			--delimiter=$'\t' --with-nth=3.. --multi \
			--height=40% --reverse --exit-0 \
			--prompt='stop bundle (TAB to mark, ESC cancels)> ')"
		[ -z "${sel}" ] && { echo "cancelled."; return 1; }
		printf '%s\n' "${sel}" | cut -f1,2 | _lfrBundleStopLines
		return 0
	fi

	# No fzf: numbered menu, accepts several indices or 'all'.
	local -a lines=()
	while IFS= read -r line; do [ -n "${line}" ] && lines+=("${line}"); done <<<"${entries}"
	local i reply tok
	for i in "${!lines[@]}"; do
		printf '  %d) %s\n' "$((i + 1))" "${lines[i]##*$'\t'}"
	done
	printf 'Stop which? (numbers, space separated, or "all", empty cancels) '
	read -r reply
	[ -z "${reply}" ] && { echo "cancelled."; return 1; }
	if [ "${reply}" = "all" ]; then
		printf '%s\n' "${procs}" | _lfrBundleStopLines
		return 0
	fi
	for tok in ${reply}; do
		case "${tok}" in '' | *[!0-9]*) continue ;; esac
		i=$((tok - 1))
		[ -n "${lines[i]-}" ] && printf '%s\n' "${lines[i]}" | cut -f1,2 | _lfrBundleStopLines
	done
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

# Toggle one bundle by path: stop it if running, otherwise start it.
_lfrBundleToggleOne() {
	local path="${1}" pid
	pid="$(_lfrBundlePidForDir "${path}")"
	if [ -n "${pid}" ]; then
		_lfrBundleKill "${pid}" "$(basename "${path}")"
	else
		"${_lfrBundleDir}/start-liferay.sh" "${path}"
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

# Interactive default: show each known bundle's state in the picker, then toggle
# the selected one. A running bundle is stopped; a stopped one is started. Esc
# cancels. Mirrors the lfrShare/lfrCache toggle. Lists bundles under
# LFR_BUNDLES_DIRS; use `lfrBundle stop` to reach a running bundle outside them.
_lfrBundleToggle() {
	if ! declare -F _lfrBundleEntries >/dev/null 2>&1; then
		echo "lfrBundle: bundle list needs LfrCommon loaded; use lfrBundle run|stop." >&2
		return 1
	fi
	# Map each running bundle dir (parent of catalina.base) to its pid.
	local running="" pid base
	while IFS=$'\t' read -r pid base; do
		[ -n "${pid}" ] && running+="$(dirname "${base}")"$'\t'"${pid}"$'\n'
	done < <(_lfrBundleProcs)

	local entries="" path name pidfor state
	while IFS=$'\t' read -r path name; do
		[ -n "${path}" ] || continue
		pidfor="$(printf '%s' "${running}" | awk -F'\t' -v p="${path}" '$1==p{print $2; exit}')"
		if [ -n "${pidfor}" ]; then
			state="RUNNING pid ${pidfor}, ports: $(_lfrBundlePorts "${pidfor}")"
		else
			state="stopped"
		fi
		entries+="${path}"$'\t'"${name}  [${state}]"$'\n'
	done < <(_lfrBundleEntries)
	[ -z "${entries}" ] && { echo "lfrBundle: no bundles found under: ${LFR_BUNDLES_DIRS[*]}" >&2; return 1; }

	local sel
	sel="$(printf '%s' "${entries}" | _lfrPick 'toggle bundle> ')" || return 1
	_lfrBundleToggleOne "${sel}"
}

lfrBundle() {
	local cmd="${1-}" procs
	case "${cmd}" in
	run)
		shift
		"${_lfrBundleDir}/start-liferay.sh" "$@"
		;;
	stop)
		shift
		_lfrBundleStop "$@"
		;;
	status | ls)
		procs="$(_lfrBundleProcs)"
		if [ -z "${procs}" ]; then
			echo "No running Liferay bundles."
			return 0
		fi
		echo "Running Liferay bundles:"
		_lfrBundleList
		echo "  (${_lfrBundleCount} running)"
		;;
	"" | toggle)
		_lfrBundleToggle
		;;
	help | -h | --help)
		echo "usage: lfrBundle [toggle] | <bundle> | run [args] | stop [all] | status"
		echo "  bare lfrBundle opens a picker showing each bundle's state; selecting one starts or stops it."
		echo "  lfrBundle <bundle> toggles that bundle by name/path: start if stopped, stop if running."
		;;
	*)
		# Shorthand: treat the argument as a bundle (name or path) and toggle it.
		local path
		path="$(_lfrBundleResolve "${cmd}")" || return 1
		_lfrBundleToggleOne "${path}"
		;;
	esac
}

# Short alias, plus back-compat aliases for the former separate commands.
lfrb() { lfrBundle "$@"; }
lfrRunBundle() { lfrBundle run "$@"; }
lfrrb() { lfrBundle run "$@"; }
