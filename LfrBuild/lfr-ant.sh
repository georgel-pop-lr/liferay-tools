# lfr-ant.sh — guarded `ant all` (the lfrAntAll command).
#
# Loaded via the root lfrTools.sh. Defines lfrAntAll (short alias lfraa): run
# `ant all` in the current repo, but first refuse if THIS repo's Liferay bundle
# is running. A full build while that server is up risks partial deploys, locked
# osgi/state and work/temp, and a corrupt runtime. A bundle from an unrelated
# checkout is left alone. Pass --force / -f to build anyway. Any extra args are
# forwarded to `ant all`.
#
# Bundle detection (_lfrBundleProcs / _lfrBundleList / _lfrBundlePidForDir) comes
# from LfrBundle.

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
	local force=0 a
	local -a antargs=()
	for a in "$@"; do
		case "${a}" in
		-f | --force) force=1 ;;
		*) antargs+=("${a}") ;;
		esac
	done

	if [ "${force}" != 1 ] && declare -F _lfrBundleProcs >/dev/null 2>&1; then
		local mine pid
		mine="$(_lfrRepoBundleDir)"
		if [ -n "${mine}" ] && declare -F _lfrBundlePidForDir >/dev/null 2>&1; then
			# We know which bundle this repo deploys into: only that one matters.
			if pid="$(_lfrBundlePidForDir "${mine}")"; then
				echo "lfrAntAll: this repo's bundle is running (PID ${pid}). Stop it first (lfrBundle), or pass --force:" >&2
				printf '  %s\n' "${mine}" >&2
				return 1
			fi
		elif [ -n "$(_lfrBundleProcs)" ]; then
			# Could not resolve this repo's bundle; block on any running bundle.
			echo "lfrAntAll: a Liferay bundle is running. Stop it first (lfrBundle), or pass --force:" >&2
			_lfrBundleList >&2
			return 1
		fi
	fi

	ant all "${antargs[@]}"
}

# Short alias.
lfraa() { lfrAntAll "$@"; }
