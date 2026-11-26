# LfrCommon

Shared internals for the Liferay tools. Not a command of its own; it is loaded
by the root `lfrTools.sh` and used by `lfrRepos`, `lfrWorktree`, `lfrCache`,
`lfrShare`, `lfrBundles`, and `lfrCodeView`.

## Contents

| File | Purpose |
|---|---|
| `lfr-repo-list.sh` | Sources `repos.local.conf` and sets the `LFR_REPO_*`/`LFR_WORKTREE_*` defaults; owns the shared helpers `_lfrPick` (generic fzf/numbered picker over `value<TAB>label` lines, taking a prompt plus optional prefilter query, preview command, bottom toolbar, and start-cursor value - the last three are fzf-only), `_lfrRepoEntries` (list git repos under the configured roots, labelling each with its checked-out branch when passed `--branch`), and `_lfrRepoPick` (pick a repo). `_lfrPick` is also reused by `lfrShare`, `lfrBundles`, `lfrCache`, and `lfrCodeView`. |
| `lfr-term.sh` | Owns `_lfrClearScreen`, the terminal wipe (screen and scrollback) that a tool taking over the terminal for a long run does once it is committed to running, so the window holds that run and nothing before it. Used by `lfrAntAll`; `LFR_CLEAR_SCREEN=0` turns it off, and it is a no-op off a TTY. `start-liferay.sh` carries its own copy, since it is a standalone script that sources nothing from here. Also owns `_lfrConfirm`, the yes/no prompt every tool asks through: it takes only `y`/`yes` or `n`/`no`, re-asks on anything else including a bare Enter, and returns no without asking when there is no terminal. Also owns the step spinner, the pattern for each step of each tool: `_lfrStep "<label>" <command>` shows `<label> (<seconds>s)` on the terminal while the command runs, then prints its output, and `_lfrSpinStart "<label>"` with `_lfrSpinStop` does the same around a phase of several commands or a command substitution. Only one spinner runs at a time, and an inner step keeps the outer label. Do not use it for an interactive command or for a command that streams a long output (`ant all`). `start-liferay.sh` sources this file for the spinner. |
| `lfr-bundle-list.sh` | Owns `LFR_BUNDLES_DIRS`, `LFR_BUNDLES_PRIORITY`, and `_lfrBundleEntries` (list the launchable Tomcat bundles under those roots - empty shells and Wildfly/JBoss bundles are skipped, priority prefixes float to the top), shared by `lfrShare`'s bundle picker and `lfrBundles`'s run/stop toggle. Also owns `_lfrBundleRepoBranches`, which reads every repo's `app.server.<user>.properties` once and emits `<bundle>\t<repo>\t<branch>\t<shared>`, so `lfrBundles` can label each bundle with the checkouts that deploy into it. |
| `lfr-master.sh` | The shared "is this ticket in master?" check. `_lfrMasterFetch <dir>` fetches master from `upstream` and `brian`, and returns 1 if a fetch fails. `_lfrMasterRefs <dir>` lists the master refs to read. `lfrGitMerged [-n] [-C dir] KEY...` prints one line for each key: merged, with the commit and the refs that hold it, or NOT merged. Brian merges first, so a check that reads upstream only, or a ref that nobody fetched, misses a merge for hours (LPD-115706, 2026-11-26). `lfrPulls` uses it. |
| `lfr-log.sh` | Owns the run logs. `_lfrLogFile <logs dir> [kind]` echoes a new log path, `<logs dir>/<worktree>/<worktree>_<kind>_<time>.log`, and deletes the logs older than 30 days. `_lfrLogRun <logs dir> <kind> <function> [args]` runs a command in the same shell, copies its output to the log, and adds the exit code and each branch that it moved or deleted (old and new commit). Used by `lfrAntAll` (through `_lfrAntLogFile`), `lfrGitRebaseStack`, `lfrGitClean`, `lfrGitUpdateMaster`, and `lfrWorktreeRemove`. |
| `repos.local.conf` | Your machine-specific repo roots and worktree settings. Gitignored. |
| `repos.local.conf.example` | Tracked template; copy it to `repos.local.conf`. |

## Per-user config

```bash
cp repos.local.conf.example repos.local.conf
# edit the variables below
```

| Variable | Default | Purpose |
|---|---|---|
| `LFR_REPO_ROOTS` | `$HOME/liferay/repos` | Directories scanned for repos, in listing order. |
| `LFR_REPO_PRIORITY` | `liferay-portal` | Repo-name prefixes floated to the top of the picker. |
| `LFR_WORKTREE_ROOT` | `$HOME/liferay/repos` | Where `lfrWorktree` creates new worktrees. |
| `LFR_WORKTREE_BASE` | `upstream/master` | Default base ref for new branches (also `lfrCodeView`'s default compare base). |
| `LFR_WORKTREE_SOURCES` | empty (no copy) | The clean clones whose built bundle `lfrWorktree` and `lfrWorktreeCopyBundle` copy. Each one stays clean on its line, and `lfrAntAll` stamps its bundle. |
| `LFR_IDEA_TEMPLATE` | `liferay-portal` in `LFR_WORKTREE_ROOT` | The clone `lfrWorktreeIdeaInit` copies the IntelliJ project from. |
| `LFR_BUNDLES_DIRS` | `$HOME/liferay/bundles`, `/media/$USER/Data/liferay/bundles` | Directories scanned for bundles (`lfrShare`, `lfrBundles`). |
| `LFR_BUNDLES_PRIORITY` | `liferay-bundle-master`, `liferay-bundle` | Bundle-name prefixes floated to the top of the bundle picker. |

`LFR_WORKTREE_ROOT`, `LFR_WORKTREE_BASE` and `LFR_IDEA_TEMPLATE` also honor an exported environment
value when the config does not set them; the four array variables are
config-file-only.
