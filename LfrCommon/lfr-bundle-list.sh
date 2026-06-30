# lfr-bundle-list.sh — shared bundle discovery for the Liferay tools.
#
# Loaded via the root lfrTools.sh. Owns LFR_BUNDLES_DIRS and _lfrBundleEntries,
# reused by lfrShare (its bundle picker) and lfrBundle (the run/stop toggle).
# Export LFR_BUNDLES_DIRS to override the search roots.

if [ -z "${LFR_BUNDLES_DIRS+x}" ]; then
	LFR_BUNDLES_DIRS=("${HOME}/liferay/bundles" "/media/${USER}/Data/liferay/bundles")
fi

# Name prefixes floated to the top of the bundle picker, in order. Override in
# repos.local.conf. Mirrors LFR_REPO_PRIORITY for repos.
[ -z "${LFR_BUNDLES_PRIORITY+x}" ] && LFR_BUNDLES_PRIORITY=("liferay-bundle-master" "liferay-bundle")

# Emit "<path>\t<name>  (<root>)" for every bundle-looking dir under the roots,
# with LFR_BUNDLES_PRIORITY prefixes sorted first (stable within each rank).
_lfrBundleEntries() {
	local root d name rank i seq=0
	{
		for root in "${LFR_BUNDLES_DIRS[@]}"; do
			[ -d "${root}" ] || continue
			for d in "${root}"/*/; do
				[ -d "${d}" ] || continue
				if compgen -G "${d}tomcat*" >/dev/null 2>&1 || [ -e "${d}.liferay-home" ] || [ -d "${d}liferay-dxp" ]; then
					name="$(basename "${d}")"
					rank=9999
					for i in "${!LFR_BUNDLES_PRIORITY[@]}"; do
						if [ "${name#"${LFR_BUNDLES_PRIORITY[$i]}"}" != "${name}" ]; then
							rank="${i}"
							break
						fi
					done
					printf '%d\t%d\t%s\t%s  (%s)\n' "${rank}" "${seq}" "${d%/}" "${name}" "${root}"
					seq=$((seq + 1))
				fi
			done
		done
	} | sort -t$'\t' -k1,1n -k2,2n | cut -f3-
}
