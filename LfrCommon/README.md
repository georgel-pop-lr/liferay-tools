# LfrCommon

Shared internals for the Liferay tools. Not a command of its own; it is loaded
by the root `lfrTools.sh` and used by `lfrRepo`, `lfrWorktree`, `lfrCache`,
`lfrShare`, and `lfrBundle`.

## Contents

| File | Purpose |
|---|---|
| `lfr-repo-list.sh` | Owns the per-user repo config and the shared helpers `_lfrPick` (generic fzf/numbered picker over `value<TAB>label` lines), `_lfrRepoEntries` (list git repos under the configured roots), and `_lfrRepoPick` (pick a repo). `_lfrPick` is also reused by `lfrShare` and `lfrBundle`. |
| `lfr-bundle-list.sh` | Owns `LFR_BUNDLES_DIRS` and `_lfrBundleEntries` (list bundle dirs under those roots), shared by `lfrShare`'s bundle picker and `lfrBundle`'s run/stop toggle. |
| `repos.local.conf` | Your machine-specific repo roots and worktree settings. Gitignored. |
| `repos.local.conf.example` | Tracked template; copy it to `repos.local.conf`. |

## Per-user config

```bash
cp repos.local.conf.example repos.local.conf
# edit LFR_REPO_ROOTS, LFR_REPO_PRIORITY, LFR_WORKTREE_ROOT, LFR_WORKTREE_BASE
```

| Variable | Default | Purpose |
|---|---|---|
| `LFR_REPO_ROOTS` | `$HOME/liferay/repos` | Directories scanned for repos, in listing order. |
| `LFR_REPO_PRIORITY` | `liferay-portal` | Repo-name prefixes floated to the top of the picker. |
| `LFR_WORKTREE_ROOT` | `$HOME/liferay/repos` | Where `lfrWorktree` creates new worktrees. |
| `LFR_WORKTREE_BASE` | `upstream/master` | Default base ref for new branches. |
| `LFR_BUNDLES_DIRS` | `$HOME/liferay/bundles`, `/media/$USER/Data/liferay/bundles` | Directories scanned for bundles (`lfrShare`, `lfrBundle`). |
| `LFR_BUNDLES_PRIORITY` | `liferay-bundle-master`, `liferay-bundle` | Bundle-name prefixes floated to the top of the bundle picker. |
