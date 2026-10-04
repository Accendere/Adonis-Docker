# Adonis add-on (bootstrap)

Home Assistant Supervisor add-on repository for Adonis.

This repository is intentionally thin: it contains the container image
(packages only) and a small `bootstrap.sh`. On every start the bootstrap
fetches a private application repository at the tag set in the add-on's
`github_tag` option, using a read-only deploy key generated on first boot,
and runs that repository's `addon/run.sh`. All configuration, access policy
and documentation live there.

Without access to that private repository the add-on does nothing useful.

## Options the bootstrap itself reads

| Option | Purpose |
|---|---|
| `github_tag` | Tag of the app repo to deploy on this host (required) |
| `app_repo` | SSH URL of the app repo, `git@github.com:<owner>/<repo>.git` (required) |
| `rollback_after_failed_starts` | After this many starts in a row that never finish booting, run the last scripts that did, with the app pinned to their commit (default 3, 0 = never) |

Host ports are not set by default; map them in the add-on's Network config.

On first start the log prints this host's deploy key; add it as a
read-only deploy key on the app repo, then restart the add-on.

If GitHub is unreachable at boot, or the tag's scripts are broken, the
last `addon/` scripts that booted successfully (cached under
`/data/bootstrap`) are used instead, with the app pinned to that commit.
