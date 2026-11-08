# Crexi build of git-ai

This fork carries one change on branch `crexi/metrics-retention` (based on upstream v1.7.6):
configurable retention for the local metrics database, with a separate, shorter window for
streamed transcript events. Releases of this repo are prebuilt binaries of that branch.

## Why

Stock git-ai keeps every local metric event for 365 days. With no usegitai.com login nothing is
ever uploaded, so `~/.git-ai/internal/metrics-db` grows without bound (23 GB on one of our
machines). Most of it is streamed transcript lines that git-ai only consults for about 3 seconds
around a file's edit time when you commit. Weave does not read this database; it reads the
`refs/notes/ai` git notes that git-ai pushes with your commits.

| key | default | scope |
|---|---|---|
| `metrics_retention_days` | 365 | every event kind |
| `session_event_retention_days` | `metrics_retention_days` | streamed transcript events only, never longer than the general value |

Our builds also default auto-updates off (so upstream cannot replace the binary) and bake in no
crash-reporting or analytics keys. They are not code-signed; the installers clear the macOS
quarantine flag and the Windows zone identifier.

## Install or upgrade

If you have never installed git-ai, run the upstream installer first so editor hooks and PATH are
set up, then run ours to swap in the Crexi build.

macOS / Linux:

```bash
curl -fsSL https://github.com/crexi/git-ai/releases/latest/download/install.sh | bash
```

Windows (PowerShell):

```powershell
irm https://github.com/crexi/git-ai/releases/latest/download/install.ps1 -OutFile install.ps1
.\install.ps1
```

Both set `disable_auto_updates true` and `session_event_retention_days 7` and restart the daemon.
`--shrink` / `-Shrink` also deletes transcript events already older than the window and VACUUMs
the database (needs `sqlite3`), which is how you get the disk back today.
`GIT_AI_SESSION_EVENT_RETENTION_DAYS=N` (or `-RetentionDays N`) changes the window. A
`.bak-<timestamp>` copy of the previous binary is left next to the new one; copy it back to roll back.

Nix users: `nix profile install 'github:crexi/git-ai/crexi/metrics-retention'`.

## Verify

```bash
git-ai --version
git-ai config session_event_retention_days      # 7
git-ai whoami                                    # event counts
du -sh ~/.git-ai/internal/metrics-db
```

The daemon prunes at most once per 24 hours and only on a metric insert, so an idle machine may
take a while to show the drop. The file does not shrink by itself after a prune (SQLite reuses the
freed pages); use `--shrink` once if you want the space back immediately.

## Cutting a release

Actions → "Crexi release" → Run workflow, with the ref to build (normally
`crexi/metrics-retention`) and the tag to create (`v<upstream version>-metrics-retention.<n>`,
e.g. `v1.7.6-metrics-retention.1`). The workflow builds Linux x64 (static musl), macOS arm64 and Windows x64 as
required targets, plus Linux arm64 and macOS x64 as optional ones, checks each binary answers
`--version` and knows the new setting, and publishes the binaries, `SHA256SUMS`, and both
installers as a release.
