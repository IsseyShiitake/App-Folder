"""QML bridge objects for appfolder (exposed via context properties)."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

from PySide6.QtCore import QObject, QProcess, QUrl, Slot


class PythonBridge(QObject):
    """Callable from QML as `pythonBridge`."""

    SEARCH_ROOTS = (
        Path.home() / ".local/share/applications",
        Path("/usr/share/applications"),
        Path("/var/lib/flatpak/exports/share/applications"),
        Path.home() / ".local/share/flatpak/exports/share/applications",
    )

    def __init__(self, parent=None):
        super().__init__(parent)

    # -- persistence --------------------------------------------------------

    @Slot(str)
    def dumpGeometry(self, info: str) -> None:
        # verification hook: APPFOLDER_GEOM_DUMP=1 writes the popup geometry
        try:
            import os as _os
            if _os.environ.get("APPFOLDER_GEOM_DUMP") == "1":
                with open("/tmp/appfolder-geometry.txt", "a") as f:
                    f.write(info + "\n")
        except OSError:
            pass
    @Slot(str)
    def debugLog(self, msg: str) -> None:
        # diagnostics hook: APPFOLDER_DEBUG=1 appends to /tmp/appfolder-debug.log
        try:
            import os as _os
            if _os.environ.get("APPFOLDER_DEBUG") == "1":
                with open("/tmp/appfolder-debug.log", "a") as f:
                    f.write(msg + "\n")
        except OSError:
            pass

    @Slot(str, result=str)
    def localPath(self, url: str) -> str:
        """Drag URL or typed text → local filesystem path (percent-decoded).

        Handles file:// URLs, plain absolute paths, and ~ paths. Bare
        "name.desktop" lookups are NOT resolved here (QML falls back to
        addApp → SEARCH_ROOTS for those).
        """
        import os as _os
        from urllib.parse import unquote
        s = (url or "").strip().strip("'\"")
        if not s:
            return ""
        try:
            p = QUrl(s).toLocalFile()
        except Exception:
            p = ""
        if p:
            return p
        if s.startswith("file://"):
            return unquote(s[len("file://"):])
        if s.startswith("/") or s.startswith("~"):
            return _os.path.expanduser(s)
        return ""

    @staticmethod
    def _folder_path(conf_dir: str, folder: str) -> Path:
        d = Path(conf_dir)
        d.mkdir(parents=True, exist_ok=True)
        return d / f"{folder}.json"

    @staticmethod
    def _read_folder(conf_dir: str, folder: str) -> dict:
        try:
            raw = json.loads(PythonBridge._folder_path(conf_dir, folder).read_text())
            return raw if isinstance(raw, dict) else {"apps": raw}
        except (json.JSONDecodeError, OSError):
            return {}

    @Slot(str, str, str, result=bool)
    def save(self, conf_dir: str, folder: str, apps_json: str) -> bool:
        try:
            apps = json.loads(apps_json)
            data = PythonBridge._read_folder(conf_dir, folder)
            data["apps"] = apps  # merge: top-level metadata (icon, ui) survives
            PythonBridge._folder_path(conf_dir, folder).write_text(
                json.dumps(data, indent=2) + "\n")
            return True
        except (json.JSONDecodeError, OSError):
            return False

    @Slot(str, str, result=str)
    def folderMeta(self, conf_dir: str, folder: str) -> str:
        """Top-level folder metadata (icon, ui) as JSON, without apps."""
        try:
            data = PythonBridge._read_folder(conf_dir, folder)
            data.pop("apps", None)
            return json.dumps(data)
        except OSError:
            return "{}"

    @Slot(str, str, str, result=bool)
    def saveMeta(self, conf_dir: str, folder: str, meta_json: str) -> bool:
        """Merge top-level metadata keys (never touches apps)."""
        try:
            meta = json.loads(meta_json)
            if not isinstance(meta, dict):
                return False
            meta.pop("apps", None)
            p = PythonBridge._folder_path(conf_dir, folder)
            try:
                data = json.loads(p.read_text())
                if not isinstance(data, dict):
                    data = {"apps": data}
            except (json.JSONDecodeError, OSError):
                data = {"apps": []}
            data.update(meta)
            p.write_text(json.dumps(data, indent=2) + "\n")
            return True
        except (json.JSONDecodeError, OSError):
            return False

    # -- folder icon --------------------------------------------------------

    _icon_cache: list | None = None

    @staticmethod
    def _icon_theme() -> str:
        try:
            import configparser
            c = configparser.ConfigParser()
            c.read(Path.home() / ".config/kdeglobals")
            return c["Icons"].get("Theme", "breeze")
        except Exception:
            return "breeze"

    @Slot(result=str)
    def listIcons(self) -> str:
        """Installed icon names (current theme + breeze + hicolor + pixmaps)."""
        if PythonBridge._icon_cache is not None:
            return json.dumps(PythonBridge._icon_cache)
        theme = PythonBridge._icon_theme()
        names: set[str] = set()
        roots = [Path.home() / ".local/share/icons",
                 Path("/usr/share/icons")]
        for base in roots:
            for th in (theme, "breeze", "hicolor"):
                d = base / th
                if not d.is_dir():
                    continue
                for ext in ("*.svg", "*.svgz", "*.png", "*.xpm"):
                    try:
                        for f in d.rglob(ext):
                            names.add(f.stem)
                    except OSError:
                        pass
        for ext in ("*.svg", "*.svgz", "*.png", "*.xpm"):
            try:
                for f in Path("/usr/share/pixmaps").glob(ext):
                    names.add(f.stem)
            except OSError:
                pass
        out = sorted(names)
        PythonBridge._icon_cache = out
        return json.dumps(out)

    def _desktop_entry(self, folder: str) -> Path | None:
        p = Path.home() / ".local/share/applications" / f"appfolder-{folder}.desktop"
        return p if p.exists() else None

    @staticmethod
    def _entry_icon(p: Path) -> str:
        try:
            for line in p.read_text(errors="replace").splitlines():
                if line.startswith("Icon="):
                    return line.split("=", 1)[1].strip()
        except OSError:
            pass
        return ""

    @Slot(str, str, result=str)
    def folderIcon(self, conf_dir: str, folder: str) -> str:
        """Current folder icon: folder json, else the pinned entry, else ''."""
        data = PythonBridge._read_folder(conf_dir, folder)
        if isinstance(data.get("icon"), str) and data["icon"]:
            return data["icon"]
        p = self._desktop_entry(folder)
        if p is not None:
            return PythonBridge._entry_icon(p)
        return ""

    @Slot(str, str, str, result=bool)
    def setFolderIcon(self, conf_dir: str, folder: str, icon: str) -> bool:
        """Persist folder icon in json AND rewrite our pinned entry's Icon=."""
        try:
            if not self.saveMeta(conf_dir, folder, json.dumps({"icon": icon})):
                return False
            p = self._desktop_entry(folder)
            if p is None:
                self.debugLog(f"setFolderIcon: no entry for {folder}")
                return True
            try:
                text = p.read_text(errors="replace")
            except OSError:
                return True
            if "app-folder" not in text and "appfolder" not in text:
                self.debugLog(f"setFolderIcon: not our entry, skip {p}")
                return True  # don't clobber foreign launchers
            lines = text.splitlines()
            done = False
            for i, line in enumerate(lines):
                if line.startswith("Icon=") and not done:
                    lines[i] = f"Icon={icon or 'folder'}"
                    done = True
            if not done:
                lines.insert(1, f"Icon={icon or 'folder'}")
            try:
                p.write_text("\n".join(lines) + "\n")
            except OSError:
                return True
            try:
                proc = QProcess(self)
                proc.setProgram("kbuildsycoca6")
                proc.setArguments(["--noincremental"])
                proc.startDetached()
            except Exception:
                pass
            self.debugLog(f"setFolderIcon {folder} -> {icon or 'folder'}")
            return True
        except (json.JSONDecodeError, OSError):
            return False



    # -- .desktop reading ----------------------------------------------------

    @staticmethod
    def _resolve(desktop: str) -> Path | None:
        p = Path(desktop)
        if p.is_absolute():
            return p if p.exists() else None
        for root in PythonBridge.SEARCH_ROOTS:
            c = root / desktop
            if c.exists():
                return c
        return None

    @Slot(str, str, result=str)
    def desktopField(self, desktop: str, field: str) -> str:
        p = self._resolve(desktop)
        if not p:
            return ""
        try:
            in_actions = False
            for line in p.read_text(errors="replace").splitlines():
                if line.startswith("["):
                    in_actions = line.strip().startswith("[Desktop Action")
                    continue
                if in_actions:
                    continue
                if line.startswith(field + "="):
                    return line.split("=", 1)[1].strip()
        except OSError:
            pass
        return ""

    # -- launching -----------------------------------------------------------

    @Slot(str)
    def launch(self, desktop: str) -> None:
        p = self._resolve(desktop)
        if not p:
            return
        proc = QProcess(self)
        proc.setProgram("kioclient")
        proc.setArguments(["exec", str(p)])
        proc.startDetached()
