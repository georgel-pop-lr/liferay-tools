# lfr-repo.sh - jump between Liferay repos (the lfrRepos command).
#
# The repo list, picker, and per-user config live in the shared module
# LfrCommon/lfr-repo-list.sh (loaded via the root lfrTools.sh).
#
# Usage:
#     lfrRepos            # picker over every repo under the configured roots
#     lfrRepos portal     # jump to the single match; picker prefiltered otherwise
#     lfrRepos -l         # list all repos, their branch and their roots, no cd

lfrRepos() {
	case "${1-}" in
	-h | --help)
		cat <<-'EOF'
			lfrRepos - jump (cd) to a Liferay repo.

			Usage:
			  lfrRepos          open a picker over every repo under your roots
			  lfrRepos <name>   jump to the match (picker if more than one matches)
			  lfrRepos -l       list all repos, their branch and their roots, no cd
		EOF
		return 0
		;;
	esac

	if [ "$1" = "-l" ] || [ "$1" = "--list" ]; then
		_lfrRepoEntries --branch | cut -f2-
		return 0
	fi

	local repo
	repo="$(_lfrRepoPick "${1:-}")" || return 1
	cd "${repo}" || return 1
}

# Tab-complete on repo names.
_lfrRepoComplete() {
	local names
	names="$(_lfrRepoEntries | sed -E 's/^[^\t]*\t([^ ]+).*/\1/')"
	COMPREPLY=($(compgen -W "${names}" -- "${COMP_WORDS[COMP_CWORD]}"))
}

# Short alias, plus lfrRepo, the name before the plural.
lfrr() { lfrRepos "$@"; }
lfrRepo() { lfrRepos "$@"; }

complete -F _lfrRepoComplete lfrRepos
complete -F _lfrRepoComplete lfrr
complete -F _lfrRepoComplete lfrRepo
