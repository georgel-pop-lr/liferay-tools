# lfr-bundle-list.sh — shared bundle discovery for the Liferay tools.
#
# Loaded via the root lfrTools.sh. Owns LFR_BUNDLES_DIRS, _lfrBundleEntries and
# _lfrBundleRepoBranches, reused by lfrShare (its bundle picker) and lfrBundle
# (the run/stop toggle). Export LFR_BUNDLES_DIRS to override the search roots.

if [ -z "${LFR_BUNDLES_DIRS+x}" ]; then
	LFR_BUNDLES_DIRS=("${HOME}/liferay/bundles" "/media/${USER}/Data/liferay/bundles")
fi

# Name prefixes floated to the top of the bundle picker, in order. Override in
# repos.local.conf. Mirrors LFR_REPO_PRIORITY for repos.
[ -z "${LFR_BUNDLES_PRIORITY+x}" ] && LFR_BUNDLES_PRIORITY=("liferay-bundle-master" "liferay-bundle")

# Emit "<path>\t<name>  (<root>)" for every launchable Tomcat bundle under the
# roots (a Tomcat dir directly or under liferay-dxp/, matching start-liferay.sh),
# with LFR_BUNDLES_PRIORITY prefixes sorted first (stable within each rank).
# Empty shells (a bare .liferay-home, no server) and non-Tomcat (Wildfly/JBoss)
# bundles are skipped, since lfrBundle only launches Tomcat.
_lfrBundleEntries() {
	local root d name rank i seq=0
	{
		for root in "${LFR_BUNDLES_DIRS[@]}"; do
			[ -d "${root}" ] || continue
			for d in "${root}"/*/; do
				[ -d "${d}" ] || continue
				if compgen -G "${d}tomcat*" >/dev/null 2>&1 || compgen -G "${d}liferay-dxp/tomcat*" >/dev/null 2>&1; then
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

# Emit "<bundle>\t<repo>\t<branch>\t<shared>" for every repo that points at a
# bundle through app.server.parent.dir, so a caller can say what each bundle is
# for. <bundle> is the resolved path (${project.dir} expanded), <branch> the
# checked-out branch or the short sha when HEAD is detached, and <shared> is
# "shared" when lfrShare repointed that repo (its backup file is still there).
#
# One pass over every repo, since the callers label a whole list of bundles: a
# per-bundle lookup would re-read all 30-odd repos for each of them.
_lfrBundleRepoBranches() {
	local path pf value branch
	declare -F _lfrRepoEntries >/dev/null 2>&1 || return 0
	while IFS=$'\t' read -r path _; do
		[ -n "${path}" ] || continue
		pf="${path}/app.server.${USER}.properties"
		value="$(grep -m1 '^app.server.parent.dir=' "${pf}" 2>/dev/null)" || continue
		value="${value#app.server.parent.dir=}"
		[ -n "${value}" ] || continue
		value="${value//\$\{project.dir\}/${path}}"
		branch="$(git -C "${path}" symbolic-ref --short -q HEAD ||
			git -C "${path}" rev-parse --short HEAD 2>/dev/null)"
		printf '%s\t%s\t%s\t%s\n' "$(readlink -m "${value}")" "$(basename "${path}")" \
			"${branch:-?}" \
			"$([ -f "${path}/app.server.${USER}.lfrshare-bak.properties" ] && echo shared)"
	done < <(_lfrRepoEntries)
}
