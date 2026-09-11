# Changelog

## [0.2.1] - 2026-09-11

### Fixed
- The check no longer executes anything from the ambient PATH: every helper is called by absolute `/usr/bin` path, `PATH=/usr/bin:/bin` is pinned for the whole tree (borg and ssh included) and `BASH_ENV`, `LD_PRELOAD`, `PYTHON*` are dropped.
- borgmatic must be a trusted executable (regular file, not writable by others, owned by root or the user) or the check refuses to run. New `borgmaticPath` setting, default `/usr/bin/borgmatic`.
- The whole borgmatic/borg/ssh tree runs in a dedicated process group; the wrapper terminates then kills any member still alive on overflow and on exit, and the QML backstop kills the entire group.

## [0.2.0] - 2026-09-11

### Added
- A repository borgmatic cannot list (wrong passphrase, missing repository, host down) now gets its own highlighted row with borg's error message, while the other repositories keep refreshing. The hero reads "N stale · M unchecked" and the banner "M of N repositories could not be checked".

### Changed
- The whole-check failure banner is reserved for runs that produce no usable data; its message now strips borgmatic's label prefixes and generic wrapper lines so borg's own error is shown.

## [0.1.1] - 2026-09-11

### Fixed
- The borgmatic check is now bounded: 5 min deadline that kills the whole borgmatic/borg/ssh process group, and producer-side output caps (8 MiB stdout, 64 KiB stderr) before anything reaches the shell. Timeouts and overflows are reported as explicit errors while the last good data stays on screen.
- The failure banner shows the real cause (e.g. "Connection closed by remote host") instead of borgmatic's help footer or generic wrapper lines.

## [0.1.0] - 2026-09-06

### Added
- Initial release: borgmatic backup freshness monitor for Omarchy shell (Quickshell bar-widget plugin)
- Bar icon that turns urgent when the newest backup in any repository is older than the stale threshold (default 48 h)
- Popup panel listing every configured repository with its last backup date and relative age, stale repositories highlighted
- Failure banner when the check itself can't reach the server, keeping the last cached data visible
- Status cache in `~/.local/state/quickborgmatic/status.json` so status shows instantly after a shell restart
- Monitoring-only YAML config, one file per remote machine (see `example-monitor.yaml`)
