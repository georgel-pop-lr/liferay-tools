# lfr-bundle-list.sh — shared bundle discovery for the Liferay tools.
#
# Loaded via the root lfrTools.sh. Owns LFR_BUNDLES_DIRS and _lfrBundleEntries,
# reused by lfrShare (its bundle picker) and lfrBundle (the run/stop toggle).
# Export LFR_BUNDLES_DIRS to override the search roots.

if [ -z "${LFR_BUNDLES_DIRS+x}" ]; then
	LFR_BUNDLES_DIRS=("${HOME}/liferay/bundles" "/media/${USER}/Data/liferay/bundles")
fi

# Emit "<path>\t<name>  (<root>)" for every bundle-looking dir under the roots.
_lfrBundleEntries() {
	local root d name
	for root in "${LFR_BUNDLES_DIRS[@]}"; do
		[ -d "${root}" ] || continue
		for d in "${root}"/*/; do
			[ -d "${d}" ] || continue
			if compgen -G "${d}tomcat*" >/dev/null 2>&1 || [ -e "${d}.liferay-home" ] || [ -d "${d}liferay-dxp" ]; then
				name="$(basename "${d}")"
				printf '%s\t%s  (%s)\n' "${d%/}" "${name}" "${root}"
			fi
		done
	done
}
