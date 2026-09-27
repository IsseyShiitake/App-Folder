#!/usr/bin/env bash
# App Folder installer.
#
# Default: installs the native plasmoid (v2). Pass --legacy for the
# standalone Python daemon (v1, kept for non-Plasma or minimal setups).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install_plasmoid() {
  command -v kpackagetool6 >/dev/null 2>&1 \
    || { echo "missing: kpackagetool6 (KDE Plasma 6 required)" >&2; exit 1; }
  # Soft deps (see README Requirements): themed icons need python3, the
  # resize/placement assistance needs gdbus. Both ship with most distros.
  command -v python3 >/dev/null 2>&1 \
    || echo "note: python3 not found — app icons will render blank" >&2
  command -v gdbus >/dev/null 2>&1 \
    || echo "note: gdbus not found — resize/placement assistance will be inert" >&2
  if kpackagetool6 --list -t Plasma/Applet 2>/dev/null | grep -q "appfolder"; then
    kpackagetool6 -u "$SRC/plasmoid" -t Plasma/Applet
    echo "upgraded plasmoid appfolder"
  else
    kpackagetool6 -i "$SRC/plasmoid" -t Plasma/Applet
    echo "installed plasmoid appfolder"
  fi
  cat <<EOF

Done. Add a folder to your panel:
  1. Right-click the panel (or desktop) → Add widgets…
  2. Search "App Folder" → Add (repeat for each folder you want)
  3. Click the folder to open its popup → right-click a tile or the
     empty grid → Add app… to fill it (the closed widget's right-click
     is Plasma's own applet menu)
  4. Right-click → Folder settings… for the folder icon, sizes and
     the checked-grid folder size picker
EOF
}

install_legacy() {
  APPDIR="$HOME/.local/lib/app-folder"
  CFGDIR="${APPFOLDER_CONFIG_DIR:-$HOME/.config/app-folder}"
  DESKDIR="$HOME/.local/share/applications"

  need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; MISSING=1; }; }
  MISSING=0
  need python3
  need kbuildsycoca6
  need gdbus
  python3 -c "import PySide6.QtCore, PySide6.QtGui, PySide6.QtQml" 2>/dev/null \
    || { echo "missing: PySide6 for $(python3 --version 2>&1)" >&2; MISSING=1; }
  [ "$MISSING" = 0 ] || { echo "Install the missing bits above, then re-run." >&2; exit 1; }

  mkdir -p "$APPDIR" "$CFGDIR" "$DESKDIR"
  cp "$SRC/legacy/app-folder" "$SRC/legacy/AppFolderWindow.qml" \
     "$SRC/legacy/bridge.py" "$SRC/legacy/cursor.py" "$APPDIR/"
  chmod +x "$APPDIR/app-folder"

  # Seed example folders, but never overwrite the user's own.
  for f in "$SRC"/legacy/examples/*.json; do
    base="$(basename "$f")"
    if [ -e "$CFGDIR/$base" ]; then
      echo "keep    $CFGDIR/$base"
    else
      cp "$f" "$CFGDIR/$base"
      echo "seed    $CFGDIR/$base"
    fi
  done

  # Install launchers (filenames must stay appfolder-<name>.desktop: the app
  # derives each folder's entry from its folder name). Customized entries
  # (e.g. a picked folder icon) are never overwritten.
  for f in "$SRC"/legacy/examples/*.desktop; do
    base="$(basename "$f")"
    if [ -e "$DESKDIR/$base" ]; then
      echo "keep    $DESKDIR/$base"
    else
      sed -e "s|@APPDIR@|$APPDIR|g" "$f" > "$DESKDIR/$base"
      echo "install $DESKDIR/$base"
    fi
  done

  kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
  cat <<EOF

Done. Pin a folder to the taskbar:
  1. Open the application launcher, search "App Folder"
  2. Right-click it → Pin to Task Manager (or drag it there)
  3. Click the pinned icon to open the folder
EOF
}

if [ "${1:-}" = "--legacy" ]; then
  install_legacy
else
  install_plasmoid
fi
