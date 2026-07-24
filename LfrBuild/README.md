# LfrBuild

Build helpers for Liferay repos. Loaded as shell functions via the root
`lfrTools.sh`.

## Commands

| Command | Short | What it does |
| --- | --- | --- |
| `lfrAntAll [--force] [ant args]` | `lfraa` | Run `ant all` in the current repo, with guards against a running server, a shared target bundle, and a concurrent build. |

`lfrAntAll` guards a full build three ways:

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
3. **One at a time.** Two full builds at once thrash and can corrupt the shared
   Gradle build cache, so a machine-wide (per-user) lock refuses a second
   `ant all` while one is running. This lock is always enforced, even with
   `--force`; a stale lock from a build that died is reclaimed automatically.

`--force` / `-f` bypasses guards 1 and 2 only. Extra arguments are forwarded to
`ant all`.

Bundle detection is shared with `LfrBundle` (`_lfrBundleProcs`,
`_lfrBundlePidForDir`); the shared-bundle lookup with `LfrShare`
(`_lfrShareReposForBundle`).
