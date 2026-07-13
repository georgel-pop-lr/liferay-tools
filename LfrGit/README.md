# LfrGit

Liferay git helpers: a safe `git clean`, fork sync from upstream, keeping your
master mirror current, and a quick interactive rebase. Loaded as shell functions
via the root `lfrTools.sh`.

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
| `LFR_GIT_MASTER_MIRRORS` | Master mirrors `lfrGitUpdateMaster` keeps current, as `branch:remote` pairs | `("master:upstream")` |

## Commands

| Command | Short | What it does |
| --- | --- | --- |
| `lfrGitCleanDry` | `lfrgcd` | Preview what `git clean` would remove. Run this first. |
| `lfrGitClean` | `lfrgc` | Remove untracked and ignored files, keeping `*.iml`, `.idea`, and `app.server/build/test.$USER.properties`. |
| `lfrGitSync [org]` | `lfrgs` | `gh repo sync <org>/liferay-portal --source <upstream>/liferay-portal`. `org` defaults to `LFR_GIT_FORK_ORG`. |
| `lfrGitSyncEE [org]` | `lfrgse` | Same for `liferay-portal-ee` master. |
| `lfrGitRebase [N]` | `lfrgr` | `git rebase -i HEAD~N` (N defaults to 20). |
| `lfrGitUpdateMaster [-r] [-f] [-p] [rebase-target]` | `lfrgum` | Update every local `master*` branch from the `<remote>/master` it tracks (`master` from upstream, `masterBrian` from brian) and sync the team fork; `-r` rebases the current branch onto a target (default `upstream/master`, or pass a remote/branch), `-f` forces it, `-p` force-pushes it. |

`lfrGitSync`/`lfrGitSyncEE` take an optional fork org to sync a different fork
than the configured `LFR_GIT_FORK_ORG`, e.g. `lfrGitSync my-other-org`.

`lfrGitUpdateMaster` keeps your master mirrors current in one run. The mirrors
are the `branch:remote` pairs in `LFR_GIT_MASTER_MIRRORS` (default
`("master:upstream")`), so `("master:upstream" "masterBrian:brian")` maintains
both `master` and `masterBrian`.

1. For each configured `branch:remote` pair (e.g. `master:upstream`,
   `masterBrian:brian`): fetch `<remote>/master` (no tags), push it to your fork
   under `<branch>` (creating the branch on the fork if missing, and forcing with
   `--force-with-lease` if the fork diverged because the source rewrote master),
   and update the local `<branch>` to it (fast-forwarded in place if it is the
   branch you have checked out; a mirror checked out in another worktree is left
   alone with a note).
2. Sync the team fork: `lfrGitSync`, or `lfrGitSyncEE` when the repo's remotes
   point at `liferay-portal-ee` (detected by remote, not folder name).
3. With `-r`/`--rebase`, rebase the current branch onto a target, skipped when you
   are on a `master*` mirror. The target defaults to `upstream/master`; pass a
   remote (e.g. `lfrGitUpdateMaster -r brian` -> `brian/master`) or a branch (e.g.
   `lfrGitUpdateMaster -r masterBrian`) to rebase onto Brian's line instead. The
   rebase is skipped when the branch already sits on the latest target;
   `-f`/`--force-rebase` forces it, and `-p`/`--push` (implies `-r`) then
   force-pushes the rebased branch with `--force-with-lease`.

List your mirrors in `LFR_GIT_MASTER_MIRRORS`; each is created if missing (locally,
tracking `<remote>/master`, and on your fork), so a fresh clone just needs the
config. A pair whose remote does not exist is skipped with a note.

`lfrGitClean` and `lfrGitCleanDry` accept extra `git clean` arguments, e.g.
`lfrGitClean modules/apps/some-app`.
