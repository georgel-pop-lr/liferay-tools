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

Every command has a short alias (same function, fewer letters), so `lfrShare`
and `lfrs` are interchangeable.

| Command | Short | What it does | Folder |
| --- | --- | --- | --- |
| `lfrRepo` | `lfrr` | Jump between Liferay repos with a picker | `LfrRepo/` |
| `lfrWorktree` | `lfrw` | Create a git worktree off a base ref | `LfrRepo/` |
| `lfrCache` | `lfrc` | Share one Gradle build cache across repos/worktrees: build master once, and the others reuse its compiled modules instead of rebuilding. Bare `lfrCache` shows each repo's state and toggles the one you pick. | `LfrCache/` |
| `lfrGitClean` / `lfrGitCleanDry` | `lfrgc` / `lfrgcd` | Safe `git clean` keeping IDE and per-user props | `LfrGit/` |
| `lfrGitSync` / `lfrGitSyncEE` | `lfrgs` / `lfrgse` | Sync a fork from upstream (optional `[org]`, defaults to your configured fork) | `LfrGit/` |
| `lfrGitRebase` | `lfrgr` | Interactive rebase over the last N commits | `LfrGit/` |
| `lfrBundle` | `lfrb` | Run and stop Liferay bundles (`run` / `stop` / `status`). Bare `lfrBundle` shows each bundle's state and toggles the one you pick (start if stopped, stop if running); `lfrBundle <name>` toggles that bundle directly. `lfrRunBundle` / `lfrrb` still alias `lfrBundle run`. | `LfrRunBundles/` |
| `lfrShare` | `lfrs` | Point a worktree at a shared, already-built bundle (no rebuild to switch). Bare `lfrShare` shows each repo's state and toggles the one you pick. | `LfrShare/` |

Each folder has its own README with the details.

## Per-user config

Machine-specific settings are kept out of git. Each tool ships a committed
`*.example`; copy it to the real (gitignored) name and edit, so you can pull
updates without clobbering anyone's local paths.

| Copy from | To (gitignored) |
| --- | --- |
| `LfrCommon/repos.local.conf.example` | `LfrCommon/repos.local.conf` (shared by lfrRepo, lfrWorktree, lfrCache) |
| `LfrCache/enabled-repos.txt.example` | `LfrCache/enabled-repos.txt` (or use `lfrCache on`) |
| `LfrGit/lfr-git.local.conf.example` | `LfrGit/lfr-git.local.conf` |
| `LfrRunBundles/start-liferay.conf.example` | `LfrRunBundles/start-liferay.conf` |
