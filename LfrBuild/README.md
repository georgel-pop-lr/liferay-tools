# LfrBuild

Build helpers for Liferay repos. Loaded as shell functions via the root
`lfrTools.sh`.

## Commands

| Command | Short | What it does |
| --- | --- | --- |
| `lfrAntAll [--force] [ant args]` | `lfraa` | Run `ant all` in the current repo, but refuse if this repo's Liferay bundle is running. |

`lfrAntAll` guards a full build: a running server holds `osgi/state`, `work`,
and `temp`, so building on top of it risks partial deploys and a corrupt
runtime. It resolves the bundle this repo deploys into from
`app.server.parent.dir` (in `app.server.${USER}.properties`, else
`app.server.properties`, with `${project.dir}` substituted) and aborts only if
that bundle is running; a bundle from an unrelated checkout is left alone. When
it cannot resolve this repo's bundle it falls back to blocking on any running
bundle. Stop the bundle with `lfrBundle` first, or pass `--force` / `-f` to
build anyway. Extra arguments are forwarded to `ant all`.

Bundle detection is shared with `LfrBundle` (`_lfrBundleProcs`,
`_lfrBundlePidForDir`).
