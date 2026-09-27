#!/usr/bin/env bash
# App Folder uninstaller. Removes the plasmoid and/or the legacy daemon.
# Keeps folder configs unless --purge. Usage:
#   ./uninstall.sh [--legacy] [--purge]
set -euo pipefail

LEGACY=0
PURGE=0
for a in "$@"; do
  case "$a" in
    --legacy) LEGACY=1 ;;
    --purge) PURGE=1 ;;
    *) echo "unknown arg: $a (want --legacy and/or --purge)" >&2; exit 2 ;;
  esac
done

if [ "$LEGACY" = 1 ]; then
  APPDIR="$HOME/.local/lib/app-folder"
  CFGDIR="${APPFOLDER_CONFIG_DIR:-$HOME/.config/app-folder}"
  DESKDIR="$HOME/.local/share/applications"
  pkill -f "$APPDIR/app-folder " 2>/dev/null || true
  rm -rf "$APPDIR"
  rm -f "$DESKDIR"/appfolder-*.desktop
  if [ "$PURGE" = 1 ]; then
    rm -rf "$CFGDIR"
    echo "removed $CFGDIR"
  else
    echo "kept   $CFGDIR (use --purge to remove)"
  fi
  kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
  echo "Legacy daemon uninstalled. Unpin any leftover taskbar icons manually."
else
  if kpackagetool6 --list -t Plasma/Applet 2>/dev/null | grep -q "appfolder"; then
    kpackagetool6 -r appfolder -t Plasma/Applet
    echo "removed plasmoid appfolder"
  else
    echo "plasmoid appfolder not installed"
  fi
  echo "Remove any App Folder widgets from the panel/desktop manually."
fi
