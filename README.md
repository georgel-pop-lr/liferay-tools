# Liferay Tools

A small collection of shell tools for working with Liferay across multiple repos
and worktrees. Source one file and you get every command.

## Install

Add this to your shell rc (for example `~/.bashrc`):

```bash
source /path/to/liferay-tools/lfrTools.sh
```

Open a new shell, then run `lfrTools` to list the available commands.

## Tools

Most commands have a short alias (same function, fewer letters), so `lfrShare`
and `lfrs` are interchangeable, and all accept `-h`/`--help`.

| Command | Short | What it does | Folder |
| --- | --- | --- | --- |
| `lfrRepo` | `lfrr` | Jump between Liferay repos with a picker showing each one's checked-out branch (or by name, with tab-completion); `-l` just lists them | `LfrRepo/` |
| `lfrWorktree` | `lfrw` | Create a git worktree off a base ref, wired to its own bundle and database (per-user props copied and repointed, bundle dir created with `portal-ext.properties` on `portal-<branch>`) | `LfrRepo/` |
| `lfrWorktreeRemove` | `lfrwr` | Remove a worktree, its branch, its bundle dir (built or not, since it belongs to that checkout alone), and IntelliJ's project state (recent-projects entry, trusted path, Open File history, task state, and every cache keyed by the project's path hash). Refuses while that bundle's Tomcat runs; never drops the database, but prints the `dropdb` command. Takes `[--force] [--keep-bundle]` | `LfrRepo/` |
| `lfrWorktreeIdeaClean` / `lfrWorktreeIdeaCleanDry` | | Make IntelliJ forget every `liferay-portal-<branch>` project whose directory is gone, and delete its caches: the leftovers of a worktree removed by hand or while an IDE was open. Refuses while IntelliJ runs | `LfrRepo/` |
| `lfrWorktreeIdeaInit` | | Give a worktree the IntelliJ project a clone already has: the project model, every `.iml`, and the run configurations (the Debugg profiles) written to `.idea/runConfigurations`. Leaves out the data sources, the shelf, and the Tomcat configurations, which are bound to the source clone's bundle | `LfrRepo/` |
| `lfrCache` | `lfrc` | Share one Gradle build cache across repos/worktrees: build master once, and the others reuse its compiled modules instead of rebuilding. Bare `lfrCache` shows each repo's state and toggles the one you pick; also `on`/`off`/`status`/`list`/`seed`/`prune`. | `LfrCache/` |
| `lfrGitClean` / `lfrGitCleanDry` | `lfrgc` / `lfrgcd` | Safe `git clean` keeping IDE and per-user props | `LfrGit/` |
| `lfrGitSync` / `lfrGitSyncEE` | `lfrgs` / `lfrgse` | Sync a fork from upstream (optional `[org]`, defaults to your configured fork) | `LfrGit/` |
| `lfrGitRebase` | `lfrgr` | Interactive rebase over the last N commits (default 20) | `LfrGit/` |
| `lfrGitRebaseOnto` | `lfrgro` | Replay only the current branch's own commits onto a target (default `upstream/master`), dropping the mirror history it was rebased onto in between: the fix for a branch that ended up on `masterBrian` and belongs on `master`. Updates no mirror and syncs no fork. Takes `[target]` | `LfrGit/` |
| `lfrGitUpdateMaster` | `lfrgum` | Update each mirror configured in `LFR_GIT_MASTER_MIRRORS` from its `<remote>/master` (e.g. `master` from upstream, `masterBrian` from brian) and sync the team fork (`lfrGitSync`/`lfrGitSyncEE`); run it from any worktree, a mirror checked out in another one is fast-forwarded inside it; `-r` rebases the current branch onto a target (default `upstream/master`, or pass a remote/branch), `-f` forces it, `-o` cuts at the branch's own fork point, `-p` force-pushes it. Only the branch's own commits ever move: a branch built on another mirror is cut at its real fork point, and a rebase that would replay more than `LFR_GIT_REBASE_MAX` (default 50) commits is refused. Takes `[-r] [-f] [-o] [-p] [rebase-target]` | `LfrGit/` |
| `lfrGitUpdateBranch` | `lfrgub` | Update one branch (e.g. `release-2026.q1`) from upstream and push it to your fork: fetches `upstream/<branch>` (no tags), moves the local branch to it wherever it is checked out, and pushes it to origin. Defaults to the branch you are on, and creates it locally when you do not have it. Takes `[branch] [-n]` | `LfrGit/` |
| `lfrGitCheckoutTag` | `lfrgct` | Check out a tag (e.g. `2026.q1.8`, `fix-pack-de-85-7010`) on a local branch: fetches the tag from upstream, branches off it, and pushes the branch to origin with `-u`. The branch is named after the tag unless you name it, and an existing one is checked out as it is rather than moved. Takes `<tag> [branch] [-n]` | `LfrGit/` |
| `lfrBundle` | `lfrb` | Toggle Liferay bundles: shows each bundle's state and starts the one you pick/name if stopped (forwarding start-flags like `-c`) or stops it if running. Also `lfrBundle status`, `lfrBundle stop-all`, `lfrBundle cd` (jump to a bundle's Liferay home without starting it), and `lfrBundle upgrade` (run a stopped bundle's database upgrade tool). `lfrRunBundle` / `lfrrb` alias it. | `LfrBundle/` |
| `lfrShare` | `lfrs` | Point a worktree at a shared, already-built bundle (no rebuild to switch). Bare `lfrShare` shows each repo's state and toggles the one you pick. | `LfrShare/` |
| `lfrAntAll` | `lfraa` | Run `ant all`, guarded: refuses while this repo's bundle is running or shared via lfrShare (`--force` bypasses both), and while another `ant all` runs (always) | `LfrBuild/` |
| `lfrCodeView` | `lfrcv` | Read the code of a change from a picker instead of copying hashes: your uncommitted changes, the branch vs its base, and each commit it adds. Picking runs `git show` / `git diff`, with a key toolbar on the bottom line of both views (`→`/`enter` view and `←`/`esc` quit in the list, `←`/`b` back and `q` quit in a diff), reopening the list on the entry you just read, so it loops until you stop. `-a [ticket]` lists that ticket's commits on every ref (master copy, backports) | `LfrCodeView/` |
| `lfrReload` | `lfrrl` | Re-source `lfrTools.sh` in the shell you are in, so an edit to any tool takes effect without a new terminal (or an `exec bash`, which drops the shell's state). A function deleted from a file stays defined until the shell restarts | root |
| `lfrPulls` | `lfrp` | List open pull requests on the Brian mirror (yours or all), with an `AHEAD` merge-queue position. Also `lfrPulls <TICKET>` / `lfrPulls ticket` (`lfrpt`) for every pull ever opened for one ticket plus what it landed on the master ref, `lfrPulls week` (`lfrpw`) for your pulls closed in the last days with merged/rejected status, and `lfrPulls stats` (`lfrps`) for per-month counts. | `LfrPulls/` |

Each folder has its own README with the details.

## Per-user config

Machine-specific settings are kept out of git. Each tool ships a committed
`*.example`; copy it to the real (gitignored) name and edit, so you can pull
updates without clobbering anyone's local paths.

| Copy from | To (gitignored) |
| --- | --- |
| `LfrCommon/repos.local.conf.example` | `LfrCommon/repos.local.conf` (shared by lfrRepo, lfrWorktree, lfrCache, lfrShare, lfrBundle, lfrCodeView) |
| `LfrCache/enabled-repos.txt.example` | `LfrCache/enabled-repos.txt` (or use `lfrCache on`) |
| `LfrGit/lfr-git.local.conf.example` | `LfrGit/lfr-git.local.conf` |
| `LfrBundle/start-liferay.conf.example` | `LfrBundle/start-liferay.conf` |
| `LfrPulls/lfr-pulls.local.conf.example` | `LfrPulls/lfr-pulls.local.conf` |
