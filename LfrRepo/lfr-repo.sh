# lfr-repo.sh — jump between Liferay repos (the lfrRepo command).
#
# The repo list, picker, and per-user config live in the shared module
# LfrCommon/lfr-repo-list.sh (loaded via the root lfrTools.sh).
#
# Usage:
#     lfrRepo            # picker over every repo under the configured roots
#     lfrRepo portal     # jump to the single match; picker prefiltered otherwise
#     lfrRepo -l         # list all repos and their roots, no cd

lfrRepo() {
	case "${1-}" in
	-h | --help)
		cat <<-'EOF'
			lfrRepo — jump (cd) to a Liferay repo.

			Usage:
			  lfrRepo          open a picker over every repo under your roots
			  lfrRepo <name>   jump to the match (picker if more than one matches)
			  lfrRepo -l       list all repos and their roots, without changing dir
		EOF
		return 0
		;;
	esac

	if [ "$1" = "-l" ] || [ "$1" = "--list" ]; then
		_lfrRepoEntries | cut -f2-
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

# Short alias.
lfrr() { lfrRepo "$@"; }

complete -F _lfrRepoComplete lfrRepo
complete -F _lfrRepoComplete lfrr
