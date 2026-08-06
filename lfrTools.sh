# lfr.sh — single entry point for every Liferay tool under this folder.
#
# Source this one file from your shell rc. It loads every lfr-*.sh tool from
# each tool subfolder (LfrRepo, LfrCache, ...), defining their functions
# (lfrRepo, lfrWorktree, lfrCache, ...). It must be sourced, not executed, so
# the functions and their `cd`s land in your current shell:
#
#     source /path/to/liferay-tools/lfrTools.sh
#
# Each tool keeps living in its own folder. Drop a new lfr-<name>.sh in any
# subfolder and it gets picked up automatically. A folder's own lfr.sh
# aggregator is skipped (only lfr-<name>.sh files are loaded).

_lfr_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _lfr_script in "${_lfr_root}"/*/lfr-*.sh; do
	[ -r "${_lfr_script}" ] && . "${_lfr_script}"
done

unset _lfr_root _lfr_script

# lfrTools — explain the tool commands loaded by this entry point.
lfrTools() {
	cat <<-'EOF'
		Liferay helper commands. Run any with -h (or --help) for details.

		Repos and worktrees
		  lfrRepo               jump to a Liferay repo (picker, or by name)
		  lfrWorktree           create a git worktree + branch for a ticket
		  lfrWorktreeRemove     remove a worktree, its branch, its unused bundle,
		                        and IntelliJ's project state
		  lfrWorktreeIdeaClean  make IntelliJ forget worktree projects that are
		                        gone (lfrWorktreeIdeaCleanDry previews it)
		  lfrShare              point a repo at an already-built bundle (no rebuild)

		Server bundle
		  lfrBundle     start or stop a Liferay server (toggle); show status;
		                cd to a bundle; run its database upgrade tool
		  lfrRunBundle  same as lfrBundle

		Build
		  lfrAntAll     run `ant all`, guarded (running server, shared bundle, one at a time)
		  lfrCache      share one Gradle build cache across repos/worktrees

		Git
		  lfrGitClean       delete untracked/ignored files (keep IDE + your props)
		  lfrGitCleanDry    preview what lfrGitClean would delete
		  lfrGitSync        sync your team fork's master from upstream
		  lfrGitSyncEE      same, for liferay-portal-ee
		  lfrGitRebase      interactive rebase over the last N commits
		  lfrGitRebaseOnto  replay only this branch's own commits onto a target,
		                    dropping the mirror history it was rebased onto
		  lfrGitUpdateMaster  refresh master mirrors, optionally rebase your branch

		Code
		  lfrCodeView   pick a commit (or your local changes) and diff it

		Pull requests
		  lfrPulls      list open PRs on the Brian mirror; one ticket's pulls
		                (lfrPulls LPD-12345); per-month stats

		Every command has a short alias: lfrr, lfrw, lfrwr, lfrs, lfrb, lfrrb,
		lfraa, lfrc, lfrcv, lfrp, lfrgc, lfrgcd, lfrgs, lfrgse, lfrgr, lfrgro,
		lfrgum. Three expand to an lfrPulls subcommand: lfrpw (week), lfrps
		(stats), lfrpt (ticket).
	EOF
}
