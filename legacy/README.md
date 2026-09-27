# App Folder v1 — standalone daemon (legacy, feature-frozen)

This is the original implementation: one resident Python process per folder
rendering its own layer-shell popup, opened from `.desktop` launchers pinned
to the task manager. It works standalone (no widget installation) and stays
available for non-Plasma or minimal setups.

New installs should prefer the native plasmoid (see `../README.md`).
Migrate any folder from the widget UI: *Folder settings…* → *Import v1*.

## Install

```sh
../install.sh --legacy
```

This copies the daemon to `~/.local/lib/app-folder`, seeds
`~/.config/app-folder/{browsers,folder1}.json` (never overwrites yours),
installs the `appfolder-*.desktop` launchers, and refreshes the menu cache.
Then pin *App Folder* from the application launcher to the taskbar.

## Usage

Click the pinned icon to open/close. Click an app to launch. Drag icons to
reorder. Right-click an app to remove, right-click empty space for
*Add app…* / *Keep open* / *Folder settings…* (icon picker, size sliders,
adapt-to-theme toggle with custom color/opacity/corners/outline, reset).
Folders with 9+ apps page with the mouse wheel. Right-click the pinned
launcher itself → *Folder settings…* jumps straight to the panel
(`app-folder <name> --settings`).

## Configuration

Folders: `~/.config/app-folder/<name>.json`
(`apps[]`, top-level `icon`, `ui{iconScale,frameScale,themeAdapt,bgColor,
bgOpacity,cornerScale,outlineScale}`).

Environment overrides (on the `Exec=` line or exported):

| Variable | Default | Meaning |
|---|---|---|
| `APPFOLDER_CONFIG_DIR` | `~/.config/app-folder` | Folder JSON directory |
| `APPFOLDER_ICON_SIZE` | `44` | Initial icon px with no saved scale |
| `APPFOLDER_PANEL_THICKNESS` | `55` | Bottom panel thickness (anchor math) |
| `APPFOLDER_PANEL_FLOAT_MARGIN` | `8` | Floating panel margin |
| `APPFOLDER_GAP` | `6` | Gap between panel and popup |
| `APPFOLDER_CENTER` | `0` | `1` = always center, skip cursor probe |
| `APPFOLDER_IDLE_QUIT` | `900` | Seconds hidden before the daemon exits (`0` = resident) |
| `APPFOLDER_DEBUG` | `0` | `1` = log drops/anchors to `/tmp/appfolder-debug.log` |
| `APPFOLDER_HOLD` | `0` | `1` = never auto-hide (screenshots/tests) |

## Remove

```sh
../uninstall.sh --legacy          # keeps ~/.config/app-folder
../uninstall.sh --legacy --purge  # removes it too
```
