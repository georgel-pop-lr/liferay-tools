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

# Kept (not unset below) so lfrReload can re-source this file by path.
_lfrToolsEntry="${_lfr_root}/$(basename "${BASH_SOURCE[0]}")"

for _lfr_script in "${_lfr_root}"/*/lfr-*.sh; do
	[ -r "${_lfr_script}" ] && . "${_lfr_script}"
done

unset _lfr_root _lfr_script

# lfrReload — pick up edits to any lfr-*.sh in the shell you are already in, so
# changing a tool does not cost a new terminal or an `exec bash` (which would
# throw away the shell's state). Re-sourcing redefines every function, so a
# function you DELETED from a file stays defined until the shell restarts.
lfrReload() {
	. "${_lfrToolsEntry}" || return 1
	echo "lfrTools reloaded from ${_lfrToolsEntry}"
}

lfrrl() { lfrReload; }

# lfrTools — explain the tool commands loaded by this entry point.
lfrTools() {
	cat <<-'EOF'
		Liferay helper commands. Run any with -h (or --help) for details.

		Repos and worktrees
		  lfrRepo               jump to a Liferay repo (picker, or by name)
		  lfrWorktree           create a git worktree + branch for a ticket
		  lfrWorktreeRemove     remove a worktree, its branch, its bundle, and
		                        IntelliJ's project state (--keep-bundle keeps it)
		  lfrWorktreeIdeaClean  make IntelliJ forget worktree projects that are
		                        gone (lfrWorktreeIdeaCleanDry previews it)
		  lfrWorktreeIdeaInit   give a worktree the IntelliJ project (and the debug
		                        profiles) a clone already has
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
		  lfrGitUpdateBranch  update one branch (release-2026.q1) from upstream
		                      and push it to your fork
		  lfrGitCheckoutTag   check out a tag (2026.q1.8) on a local branch

		Code
		  lfrCodeView   pick a commit (or your local changes) and diff it

		Pull requests
		  lfrPulls      list open PRs on the Brian mirror; one ticket's pulls
		                (lfrPulls LPD-12345); per-month stats

		These tools
		  lfrReload     re-source lfrTools.sh, so edits to any tool take effect
		                in this shell (no new terminal needed)

		Every command has a short alias: lfrr, lfrw, lfrwr, lfrs, lfrb, lfrrb,
		lfraa, lfrc, lfrcv, lfrp, lfrgc, lfrgcd, lfrgs, lfrgse, lfrgr, lfrgro,
		lfrgum, lfrgub, lfrgct, lfrrl. Three expand to an lfrPulls subcommand:
		lfrpw (week), lfrps (stats), lfrpt (ticket).
	EOF
}
