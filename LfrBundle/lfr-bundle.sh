# lfr-bundle.sh — manage Liferay bundles (the lfrBundle command): toggle
# start/stop, cd to one, or run its database upgrade tool.
#
# Loaded via the root lfrTools.sh. Defines lfrBundle (short alias lfrb):
#   lfrBundle [<bundle>] [start-flags]  toggle a bundle: start it if stopped
#                                       (forwarding start-flags to start-liferay.sh),
#                                       stop it if running. With no <bundle> a
#                                       picker shows every bundle's state; Esc cancels.
#   lfrBundle status                    list the running bundles and their ports
#   lfrBundle stop-all                  stop every running bundle (confirms)
#   lfrBundle cd [<bundle>]             jump to a bundle's Liferay home, no start
#   lfrBundle upgrade [<bundle>]        run the bundle's database upgrade tool
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

# Echo "<repo>@<branch>" for every repo pointing at the bundle <1>, comma
# separated, marking the ones lfrShare repointed. <2> is the map from
# _lfrBundleRepoBranches, passed in so a whole list costs one pass over the
# repos. Nothing is echoed when no repo deploys into that bundle.
_lfrBundleRepoLabel() {
	printf '%s\n' "${2}" | awk -F'\t' -v bundle="$(readlink -m "${1}" 2>/dev/null)" '
		$1 == bundle {
			printf "%s%s@%s%s", separator, $2, $3, ($4 == "" ? "" : " (" $4 ")")
			separator = ", "
		}
		END { if (separator != "") print "" }'
}

# Print the status table; sets the global _lfrBundleCount. Shows the full bundle
# path so bundles that share a name across roots stay distinguishable, and the
# checkouts that deploy into it, so it is clear what the server is running.
_lfrBundleList() {
	local pid base dir ports repos map="" n=0
	declare -F _lfrBundleRepoBranches >/dev/null 2>&1 && map="$(_lfrBundleRepoBranches)"
	while IFS=$'\t' read -r pid base; do
		[ -n "${pid}" ] || continue
		dir="$(dirname "${base}")"
		ports="$(_lfrBundlePorts "${pid}")"
		repos="$(_lfrBundleRepoLabel "${dir}" "${map}")"
		printf '  PID %-7s ports: %-22s %s\n' "${pid}" "${ports:-?}" "${dir}"
		[ -n "${repos}" ] && printf '      <- %s\n' "${repos}"
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

# Picker over every known bundle, each labelled with its current state; $1 is
# the prompt. Echoes the chosen bundle path.
_lfrBundlePickWithState() {
	local prompt="${1}" running pid base entries epath ename pidfor state repos map=""
	if ! declare -F _lfrBundleEntries >/dev/null 2>&1; then
		echo "lfrBundle: bundle list needs LfrCommon loaded; pass a bundle name." >&2
		return 1
	fi
	map="$(_lfrBundleRepoBranches)"
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
		# Name the checkouts that deploy into this bundle, and the branch each one
		# is on, since that is what says which ticket a bundle is for. A repo
		# marked (shared) got here through lfrShare, so it is a deploy target of
		# someone else's worktree before you stop it.
		repos="$(_lfrBundleRepoLabel "${epath}" "${map}")"
		entries+="${epath}"$'\t'"${ename}  [${state}]${repos:+  <- ${repos}}"$'\n'
	done < <(_lfrBundleEntries)
	[ -z "${entries}" ] && { echo "lfrBundle: no bundles found under: ${LFR_BUNDLES_DIRS[*]}" >&2; return 1; }
	printf '%s' "${entries}" | _lfrPick "${prompt}"
}

# Resolve an optional bundle name/path ($1), opening the picker with prompt $2
# when it is empty. Echoes the bundle path.
_lfrBundleNameOrPick() {
	if [ -n "${1}" ]; then
		_lfrBundleResolve "${1}"
	else
		_lfrBundlePickWithState "${2}"
	fi
}

# Toggle a bundle. $1 is an optional bundle name/path (empty opens the picker);
# the rest are start-liferay.sh flags forwarded when starting a stopped bundle.
_lfrBundleToggle() {
	local name="${1-}"
	shift 2>/dev/null
	local path
	path="$(_lfrBundleNameOrPick "${name}" 'toggle bundle> ')" || return 1
	_lfrBundleToggleOne "${path}" "$@"
}

# Echo a bundle's Liferay home: the bundle dir itself, or liferay-dxp/ inside
# it when a packaged DXP bundle nests its Tomcat and portal-ext there.
_lfrBundleHome() {
	if [ -d "${1}/liferay-dxp" ]; then
		printf '%s\n' "${1}/liferay-dxp"
	else
		printf '%s\n' "${1}"
	fi
}

# Jump (cd) to a bundle's Liferay home without starting anything, to edit its
# portal-ext.properties, poke its logs, or run a tool by hand.
_lfrBundleCd() {
	local path
	path="$(_lfrBundleNameOrPick "${1-}" 'cd bundle> ')" || return 1
	cd "$(_lfrBundleHome "${path}")" || return 1
}

# Run the database upgrade tool of a bundle. $1 is an optional bundle
# name/path; the rest go to db_upgrade_client.sh. Refuses while the bundle is
# running, since the upgrade needs the database to itself.
_lfrBundleUpgrade() {
	local name=""
	if [ "$#" -gt 0 ] && [ "${1#-}" = "${1}" ]; then
		name="${1}"
		shift
	fi
	local path pid dir
	path="$(_lfrBundleNameOrPick "${name}" 'upgrade bundle> ')" || return 1
	pid="$(_lfrBundlePidForDir "${path}")"
	if [ -n "${pid}" ]; then
		echo "lfrBundle: $(basename "${path}") is running (PID ${pid}); stop it before upgrading." >&2
		return 1
	fi
	dir="$(_lfrBundleHome "${path}")/tools/portal-tools-db-upgrade-client"
	if [ ! -x "${dir}/db_upgrade_client.sh" ]; then
		echo "lfrBundle: no upgrade client at ${dir}" >&2
		return 1
	fi
	(cd "${dir}" && ./db_upgrade_client.sh "$@")
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
	cd)
		shift
		_lfrBundleCd "${1-}"
		return
		;;
	upgrade)
		shift
		_lfrBundleUpgrade "$@"
		return
		;;
	help | -h | --help)
		cat <<-'EOF'
			lfrBundle — Liferay server bundles: toggle start/stop, jump to one,
			or run its database upgrade.

			Usage:
			  lfrBundle                    pick a bundle from a list, then toggle it
			  lfrBundle <bundle>           toggle the named bundle (by name or path)
			  lfrBundle <bundle> -d        start it with the flags below
			  lfrBundle status             list the running bundles and their ports
			  lfrBundle stop-all           stop every running bundle (asks first)
			  lfrBundle cd [<bundle>]      cd to a bundle's Liferay home; never
			                               starts or stops anything
			  lfrBundle upgrade [<bundle>] run a stopped bundle's database upgrade
			                               tool (extra args go to db_upgrade_client.sh)

			Toggle means a stopped bundle is started and a running one is stopped.
			Press Esc to cancel the picker.

			Start flags (forwarded to start-liferay.sh, and only when starting):
			  -d,  --debug        run so a remote debugger can attach
			  -s,  --suspend      debug, but wait for the debugger before starting
			  -c,  --clean        wipe the bundle's runtime state AND reset its DB
			  -cc, --clean-cache  clear only the OSGi/work caches (keeps the DB)
			  -y,  --yes          with --clean, skip the confirmation prompt
			  -dbd,--db-docker N  with --clean, reset the DB in docker container N
			  -t,  --test         deploy the osgi/test bundles (Arquillian/DataGuard
			                      connectors included), so testIntegration can run
			                      against the live bundle
			  -nc, --no-clear     leave the terminal as it is; by default it is
			                      wiped at launch so only this boot's log is there
		EOF
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
