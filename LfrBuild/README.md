# LfrBuild

Build helpers for Liferay repos. Loaded as shell functions via the root
`lfrTools.sh`.

## Commands

| Command | Short | What it does |
| --- | --- | --- |
| `lfrAntAll [--force] [--no-clear] [--no-precheck] [ant args]` | `lfraa` | Run `ant all` in the current repo, with guards against a running server, a shared target bundle, a concurrent build, and a compile error in a changed module. |
| `lfrAntAllPrecheck [-n]` | | Build only the modules the branch changes, the same check that `lfrAntAll` runs first. `-n` prints the Gradle tasks. |

`lfrAntAll` guards a full build four ways:

1. **Running server.** A running server holds `osgi/state`, `work`, and `temp`,
   so building on top of it risks partial deploys and a corrupt runtime. It
   resolves the bundle this repo deploys into from `app.server.parent.dir` (in
   `app.server.${USER}.properties`, else `app.server.properties`, with
   `${project.dir}` substituted) and aborts only if that bundle is running; a
   bundle from an unrelated checkout is left alone. When it cannot resolve this
   repo's bundle it falls back to blocking on any running bundle.
2. **Shared bundle.** `ant all` rebuilds and overwrites the bundle it deploys
   into, so building into a bundle shared via `lfrShare` clobbers it for every
   repo that points at it (and defeats sharing, which is to run a prebuilt bundle
   without rebuilding). When the target bundle is shared, it aborts and names the
   sharing repos; reset the share (`lfrShare reset`) first, or pass `--force`.
   When the repo's bundle cannot be resolved this guard is skipped.
3. **One at a time.** Two full builds at once thrash and can corrupt the shared
   Gradle build cache, so a machine-wide (per-user) lock refuses a second
   `ant all` (exit code 3, naming the holder) while one is running. This lock is
   always enforced, even with `--force`; a stale lock from a build that died is
   reclaimed automatically.

4. **Compile error in a changed module.** `ant all` builds the portal core first
   and the modules about ten minutes later, so a module error shows late. Under
   the lock, before the terminal wipe, it builds the `jar` of each module that
   has `.lfrbuild-portal` and a file changed since the merge base with
   `upstream/master` (committed, staged, unstaged, or untracked). If that build
   fails, it prints the errors and the log path, releases the lock, and returns
   4. It skips the check when the source of a portal core directory
   (`portal-kernel`, `portal-impl`, `util-*`) is newer than its snapshot jar in
   the repo's `.m2`, because the modules compile against that jar and only
   `ant all` rebuilds it. `--no-precheck` / `-np`, or `LFR_ANT_PRECHECK=0`,
   skips it. `--force` does not.

`--force` / `-f` (accepted anywhere in the arguments, and consumed rather than
forwarded) bypasses guards 1 and 2 only. All other arguments are forwarded to
`ant all`. `-h`/`--help` prints usage.

## The build log

Each `lfrAntAll` run writes its full output to
`LfrBuild/logs/<worktree>/<worktree>_<YYYYmmdd-HHMMSS>.log`, with the start time,
the repo, HEAD, the bundle, and the command at the top, and the end time, the exit
code, and the time it took at the bottom. When the build fails, it prints the error
lines of the log (yarn, javac, the Gradle "What went wrong" block, and `BUILD
FAILED`) and the log path, since ant prints only the Gradle summary of a failed
task. The precheck writes its Gradle output to
`LfrBuild/logs/<worktree>/<worktree>_precheck_<YYYYmmdd-HHMMSS>.log` in the same
folder. Logs older than 30 days are deleted. Git ignores `LfrBuild/logs/`. The
path comes from `_lfrLogFile` in `LfrCommon/lfr-log.sh`, which the other logged
commands use too.

## The build stamp

After a build that passes, `lfrAntAll` writes `.lfr-build-head` in the bundle:
the commit, the branch, the repo, the date, and `clean`. `clean=1` means that
the tree had no tracked change before and after the build, and that `HEAD` did
not move. Thus the bundle holds exactly that commit. The old stamp is removed
before the build, so a failed build leaves no stamp.

`lfrWorktree` and `lfrWorktreeCopyBundle` read the stamp before they copy a
bundle into a worktree (see `LfrRepos/README.md`). A deploy into the bundle
after the stamp, or an install into the `.m2` of the clone, makes the stamp not
valid, because the bundle no longer holds only that commit.

## A clean terminal for each build

Once every guard has passed and the lock is held, so the build is certainly going
to run, the terminal is wiped (screen and scrollback, through
`_lfrClearScreen` from `LfrCommon`) and the build prints what it is building:

```
Repo   : /media/georgelpop/Data/liferay/repos/liferay-portal
Bundle : /media/georgelpop/Data/liferay/bundles/liferay-bundle-master
Command: ant all
```

`ant all` prints thousands of lines, and the run before it is only in the way
when you scroll back through them. Wiping at that point rather than earlier is
what keeps a guard's refusal on screen where you can read it; the stale-lock
notice is held back and printed after the wipe for the same reason.

`--no-clear` / `-nc` keeps the terminal as it is for a single build, and
`LFR_CLEAR_SCREEN=0` (in `repos.local.conf`, or exported) keeps it for good. The
wipe is a no-op off a TTY, so piped or redirected output is never touched. The
bundle launcher does the same thing at its own launch (see `LfrBundles`).

Bundle detection is shared with `LfrBundles` (`_lfrBundleProcs`,
`_lfrBundlePidForDir`, `_lfrBundleList`); the shared-bundle lookup with
`LfrShare` (`_lfrShareReposForBundle`). Guards 1 and 2 are no-ops when those
modules are not loaded.
