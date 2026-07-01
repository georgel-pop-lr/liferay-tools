# LfrGit

Liferay git helpers: a safe `git clean`, fork sync from upstream, and a quick
interactive rebase. Loaded as shell functions via the root `lfrTools.sh`.

## Per-user config

Copy the example and set your team's fork org (gitignored, so it stays local):

```bash
cp lfr-git.local.conf.example lfr-git.local.conf
# edit LFR_GIT_FORK_ORG
```

| Variable | Meaning | Default |
| --- | --- | --- |
| `LFR_GIT_FORK_ORG` | Your team's fork org on GitHub | (required for sync) |
| `LFR_GIT_UPSTREAM_ORG` | Upstream org to sync from | `liferay` |

## Commands

| Command | Short | What it does |
| --- | --- | --- |
| `lfrGitCleanDry` | `lfrgcd` | Preview what `git clean` would remove. Run this first. |
| `lfrGitClean` | `lfrgc` | Remove untracked and ignored files, keeping `*.iml`, `.idea`, and `app.server/build/test.$USER.properties`. |
| `lfrGitSync [org]` | `lfrgs` | `gh repo sync <org>/liferay-portal --source <upstream>/liferay-portal`. `org` defaults to `LFR_GIT_FORK_ORG`. |
| `lfrGitSyncEE [org]` | `lfrgse` | Same for `liferay-portal-ee` master. |
| `lfrGitRebase [N]` | `lfrgr` | `git rebase -i HEAD~N` (N defaults to 20). |
| `lfrGitUpdateMaster [-r] [remote] [local-branch]` | `lfrgum` | Update your local master branch, push it to your fork, sync the team fork; with `-r` also rebase your current branch onto it. |

`lfrGitSync`/`lfrGitSyncEE` take an optional fork org to sync a different fork
than the configured `LFR_GIT_FORK_ORG`, e.g. `lfrGitSync my-other-org`.

`lfrGitUpdateMaster` automates the whole after-master-update routine:

1. Fast-forward the local master branch from the source remote (no tags).
2. Push it to your fork (its configured push remote, e.g. `origin`).
3. Sync the team fork: `lfrGitSync`, or `lfrGitSyncEE` when the repo's remotes
   point at `liferay-portal-ee` (detected by remote, not folder name, so an
   EE worktree named `liferay-portal-7.4.x` is still handled).
4. With `-r`/`--rebase`, rebase your current branch onto the updated branch
   (run last, so a rebase conflict does not block the sync).

Rebase is off by default, so a plain run just keeps the master branch current
and never rebases `master` onto another branch (e.g. running it while on
`master` to update `masterBrian`). Pass `-r` when you want your feature branch
rebased onto the fresh master.

The source remote defaults to `upstream`. The local branch defaults to the
`master*`-named branch that tracks `<remote>/master` (else plain `master`), so a
non-default remote lands in its own branch without naming it: `lfrGitUpdateMaster
brian` updates whichever `master*` branch tracks `brian/master`. Pass a branch to
force it, e.g. `lfrGitUpdateMaster brian masterBrian`. The remote-side branch is
always `master`.

`lfrGitClean` and `lfrGitCleanDry` accept extra `git clean` arguments, e.g.
`lfrGitClean modules/apps/some-app`.
