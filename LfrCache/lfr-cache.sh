# lfr-cache.sh — share one Gradle build cache across Liferay repos/worktrees.
#
# Liferay's build runs Gradle with a per-repo Gradle home (<repo>/.gradle) and
# forces caching on, so by default each repo caches to its own
# <repo>/.gradle/caches/build-cache-1 (not shared). lfrCache makes the listed
# repos share ONE cache by dropping a Gradle init script into
# <repo>/.gradle/init.d that points buildCache.local.directory at a shared dir.
# That init script IS loaded by the Liferay build (it reads init.d from its own
# Gradle home), so enabled repos read and write the same cache.
#
# Usage:
#   lfrCache on    [repo]   share the cache for a repo/worktree (picker if no arg)
#   lfrCache off   [repo]   stop sharing (remove the init script)
#   lfrCache status [repo]  show which repos share, and the shared cache size
#   lfrCache list           list the cache folders on disk (shared + per-repo) and owners
#   lfrCache seed  [repo]   copy a repo's existing build cache into the shared dir
#   lfrCache prune [repo]   delete the orphaned per-repo cache of a sharing repo
#
# Shared cache dir: $LFR_CACHE_DIR (default below); export to override.
#
# Caveat: <repo>/.gradle is wiped by a hard `git clean -xdf`, which removes the
# init script. Re-run `lfrCache on <repo>` after such a clean.

_lfrCacheDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${LFR_CACHE_DIR:=/media/georgelpop/Data/liferay/gradle-build-cache}"

# Resolve a repo path from an argument, or open the shared repo picker.
_lfrCacheResolveRepo() {
	local arg="${1-}" sel
	if [ -n "${arg}" ] && [ -d "${arg}" ]; then
		git -C "${arg}" rev-parse --show-toplevel 2>/dev/null && return 0
		echo "Not inside a git repo: ${arg}" >&2
		return 1
	fi
	if ! declare -F _lfrRepoPick >/dev/null 2>&1; then
		echo "lfrCache: repo picker needs LfrCommon loaded; pass a path instead." >&2
		return 1
	fi
	sel="$(_lfrRepoPick "${arg}")" || return 1
	git -C "${sel}" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${sel}"
}

# Interactive default: show each repo's cache-sharing state in the picker, then
# toggle the selected one (ON -> off, off -> ON). Esc cancels with no change.
_lfrCacheToggle() {
	if ! declare -F _lfrRepoEntries >/dev/null 2>&1; then
		echo "lfrCache: picker needs LfrCommon loaded; use lfrCache on|off <repo>." >&2
		return 1
	fi
	local entries="" path name state sel
	while IFS=$'\t' read -r path name; do
		[ -n "${path}" ] || continue
		if [ -f "${path}/.gradle/init.d/lfr-build-cache.gradle" ]; then
			state="cache: ON"
		else
			state="cache: off"
		fi
		entries+="${path}"$'\t'"${name}  [${state}]"$'\n'
	done < <(_lfrRepoEntries)
	[ -z "${entries}" ] && { echo "lfrCache: no repos found" >&2; return 1; }
	sel="$(printf '%s' "${entries}" | _lfrPick 'toggle cache> ')" || return 1
	if [ -f "${sel}/.gradle/init.d/lfr-build-cache.gradle" ]; then
		lfrCache off "${sel}"
	else
		lfrCache on "${sel}"
	fi
}

lfrCache() {
	local registry="${_lfrCacheDir}/enabled-repos.txt"
	local cmd="${1-}"
	while [ "${cmd}" != "${cmd#-}" ]; do cmd="${cmd#-}"; done
	local repo init

	mkdir -p "${_lfrCacheDir}"
	touch "${registry}"

	case "${cmd}" in
	"" | toggle)
		_lfrCacheToggle
		;;
	on)
		repo="$(_lfrCacheResolveRepo "${2-}")" || return 1
		mkdir -p "${repo}/.gradle/init.d" "${LFR_CACHE_DIR}"
		init="${repo}/.gradle/init.d/lfr-build-cache.gradle"
		cat >"${init}" <<EOF
// Managed by lfrCache. Redirects this repo's Gradle build cache to a shared
// directory so other lfrCache-enabled repos and worktrees reuse the entries.
gradle.settingsEvaluated { settings ->
	settings.buildCache {
		local {
			directory = '${LFR_CACHE_DIR}'
			enabled = true
		}
	}
}
EOF
		grep -qxF "${repo}" "${registry}" || echo "${repo}" >>"${registry}"
		echo "Sharing build cache for: ${repo}"
		echo "  -> ${LFR_CACHE_DIR}"
		;;
	off)
		repo="$(_lfrCacheResolveRepo "${2-}")" || return 1
		rm -f "${repo}/.gradle/init.d/lfr-build-cache.gradle"
		grep -vxF "${repo}" "${registry}" >"${registry}.tmp" || true
		mv "${registry}.tmp" "${registry}"
		echo "Stopped sharing for: ${repo}"
		;;
	seed)
		repo="$(_lfrCacheResolveRepo "${2-}")" || return 1
		local src="${repo}/.gradle/caches/build-cache-1"
		[ -d "${src}" ] || { echo "no build cache at ${src}" >&2; return 1; }
		mkdir -p "${LFR_CACHE_DIR}"
		echo "Seeding shared cache from ${src} ..."
		cp -rn "${src}/." "${LFR_CACHE_DIR}/" && echo "seeded into ${LFR_CACHE_DIR}"
		;;
	status)
		repo="$(git -C "${2:-$PWD}" rev-parse --show-toplevel 2>/dev/null)"
		if [ -n "${repo}" ]; then
			if [ -f "${repo}/.gradle/init.d/lfr-build-cache.gradle" ]; then
				echo "SHARED ${repo}"
			else
				echo "local  ${repo}"
			fi
		fi
		echo "--- repos sharing the cache ---"
		grep -vE '^[[:space:]]*(#|$)' "${registry}" 2>/dev/null || echo "(none)"
		echo "--- shared cache dir ---"
		if [ -d "${LFR_CACHE_DIR}" ]; then
			echo "${LFR_CACHE_DIR} ($(du -sh "${LFR_CACHE_DIR}" 2>/dev/null | cut -f1), $(find "${LFR_CACHE_DIR}" -type f ! -name '*.lock' 2>/dev/null | wc -l) entries)"
		else
			echo "${LFR_CACHE_DIR} (not created yet)"
		fi
		;;
	prune)
		# Delete the orphaned per-repo build cache of sharing repos (their local
		# cache is unused once redirected to the shared dir).
		local targets=() r local_cache sz freed=0
		if [ -n "${2-}" ]; then
			repo="$(_lfrCacheResolveRepo "${2}")" || return 1
			targets=("${repo}")
		else
			while IFS= read -r r; do
				[ -n "${r}" ] && targets+=("${r}")
			done < <(grep -vE '^[[:space:]]*(#|$)' "${registry}")
		fi
		[ "${#targets[@]}" -eq 0 ] && { echo "no sharing repos to prune"; return 0; }
		for r in "${targets[@]}"; do
			if [ ! -f "${r}/.gradle/init.d/lfr-build-cache.gradle" ]; then
				echo "skip (not sharing, local cache still in use): ${r}"
				continue
			fi
			local_cache="${r}/.gradle/caches/build-cache-1"
			if [ -d "${local_cache}" ]; then
				sz=$(du -sb "${local_cache}" 2>/dev/null | cut -f1)
				rm -rf "${local_cache}" &&
					{ freed=$((freed + sz)); echo "pruned ${local_cache} ($(awk "BEGIN{printf \"%.0f\", ${sz}/1048576}") MB)"; }
			else
				echo "nothing to prune: ${r}"
			fi
		done
		echo "removed ~$(awk "BEGIN{printf \"%.1f\", ${freed}/1073741824}") GB of orphaned per-repo caches"
		echo "(entries hardlinked into the shared dir do not free until aged out there)"
		;;
	list | ls)
		echo "Shared cache:"
		if [ -d "${LFR_CACHE_DIR}" ]; then
			echo "  ${LFR_CACHE_DIR}  ($(du -sh "${LFR_CACHE_DIR}" 2>/dev/null | cut -f1), $(find "${LFR_CACHE_DIR}" -type f ! -name '*.lock' 2>/dev/null | wc -l) entries)"
		else
			echo "  ${LFR_CACHE_DIR}  (not created)"
		fi
		echo "Per-repo caches under: ${LFR_REPO_ROOTS[*]}"
		local root d bc tag found=0
		for root in "${LFR_REPO_ROOTS[@]}"; do
			[ -d "${root}" ] || continue
			for d in "${root}"/*/; do
				bc="${d}.gradle/caches/build-cache-1"
				[ -d "${bc}" ] || continue
				found=1
				if [ -f "${d}.gradle/init.d/lfr-build-cache.gradle" ]; then
					tag="redirected to shared (orphaned, prunable)"
				else
					tag="standalone"
				fi
				printf '  %-6s %s  [%s]\n' "$(du -sh "${bc}" 2>/dev/null | cut -f1)" "${d%/}" "${tag}"
			done
		done
		if [ "${found}" -eq 0 ]; then echo "  (none found)"; fi
		;;
	help | h)
		cat <<-'EOF'
			lfrCache — share ONE Gradle build cache across repos/worktrees, so a
			build in one reuses the artifacts another already built.

			Usage:
			  lfrCache               picker of each repo's share state; select to toggle
			  lfrCache on [repo]     start sharing the cache for a repo/worktree
			  lfrCache off [repo]    stop sharing (remove the init script)
			  lfrCache status [repo] show which repos share, and the shared cache size
			  lfrCache list          list the cache folders on disk (shared + per-repo)
			  lfrCache seed [repo]   copy a repo's existing cache into the shared dir
			  lfrCache prune [repo]  delete a sharing repo's orphaned per-repo cache

			Omit [repo] to use the current repo (or a picker). A hard `git clean`
			wipes the init script, so re-run `lfrCache on` after one.
		EOF
		;;
	*)
		echo "lfrCache: unknown command '${cmd}'" >&2
		echo "usage: lfrCache [toggle] | on|off|status|list|seed|prune [repo]" >&2
		return 1
		;;
	esac
}

# Short alias.
lfrc() { lfrCache "$@"; }
