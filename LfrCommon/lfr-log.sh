# lfr-log.sh - the run logs of the Liferay tools.
#
# Loaded via the root lfrTools.sh. Each log goes in the logs folder of the area
# of the command, in a folder for each worktree, the same as lfrAntAll:
#
#     <area>/logs/<worktree>/<worktree>_<kind>_<yyyyMMdd-HHmmss>.log
#
# <worktree> is the folder where the command runs. The logs older than 30 days
# are deleted. The .gitignore of lfrTools ignores each logs folder.
#
#     _lfrLogFile <logs dir> [kind]                  echo the path of a new log
#     _lfrLogRun <logs dir> <kind> <function> [args] run a command with a log

# Echo the path of a new log file for the worktree where the command runs, and
# delete the logs older than 30 days in <logs dir>. With a kind in $2 (for
# example precheck), the kind goes between the worktree and the time in the name.
_lfrLogFile() {
	local logs="${1}" kind="${2:+_${2}}" root dir
	root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="${PWD}"
	dir="${logs}/$(basename "${root}")"
	mkdir -p "${dir}"
	find "${logs}" -name '*.log' -mtime +30 -delete 2>/dev/null
	printf '%s/%s%s_%s.log\n' "${dir}" "$(basename "${root}")" "${kind}" "$(date '+%Y%m%d-%H%M%S')"
}

# Run <function> with its args in this shell, and copy its output (stdout and
# stderr) to a new log. The log starts with the command, the date, and the
# folder, and ends with the exit code and each local branch that the command
# created, moved, or deleted, with the old and the new commit. Then a deleted
# branch can come back with git branch <name> <old commit>. Prompts still work:
# they read stdin, and the output only goes through tee. Returns the exit code
# of <function>. The branches are read from the common git folder, so the list
# is right also when the command removes the worktree where it runs.
_lfrLogRun() {
	local logs="${1}" kind="${2}" fn="${3}" log rc before after gitdir
	shift 3
	log="$(_lfrLogFile "${logs}" "${kind}")"
	gitdir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
	before="$(git --git-dir="${gitdir:-.git}" for-each-ref --format='%(refname:short) %(objectname)' refs/heads 2>/dev/null | LC_ALL=C sort -k1,1)"
	{
		echo "command: ${fn} $*"
		echo "date: $(date '+%Y-%m-%d %H:%M:%S')"
		echo "folder: ${PWD}"
		echo "---"
	} >>"${log}"
	echo "Log: ${log}"
	"${fn}" "$@" > >(tee -a "${log}") 2>&1
	rc=$?
	wait "$!"
	after="$(git --git-dir="${gitdir:-.git}" for-each-ref --format='%(refname:short) %(objectname)' refs/heads 2>/dev/null | LC_ALL=C sort -k1,1)"
	{
		echo "---"
		echo "exit: ${rc}"
		echo "branches changed (old -> new):"
		LC_ALL=C join -a 1 -a 2 -e '(none)' -o 0,1.2,2.2 <(printf '%s\n' "${before}") <(printf '%s\n' "${after}") |
			awk '$2 != $3 { print "  " $1 " " $2 " -> " $3; n++ } END { if (!n) print "  none" }'
	} >>"${log}"
	return "${rc}"
}
