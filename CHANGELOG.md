# Changelog

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
