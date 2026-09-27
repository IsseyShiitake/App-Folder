"""Cursor-position query for appfolder (KDE Plasma 6, Wayland).

KWin exposes no pointer-position DBus method to regular clients, but KWin
scripts can read `workspace.cursorPos` and `callDBus()` back out.

Fast path: start_query() spawns the DBus helper IMMEDIATELY (its ~200 ms
python+dbus startup then overlaps with the caller's own startup work);
finish_query() loads+runs the throwaway KWin script and reads the result,
so the net latency added to the caller is ~100 ms.

Notes:
- KWin 6.7's callDBus only delivers a single string argument → payload "x,y".
- The helper owns the `local.appfolder` bus name with replace_existing, so a
  fresh query always steals the name from any leftover previous helper.

Set APPFOLDER_CENTER=1 to skip the query entirely (popup always centers).
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

BUS_DEFAULT = "local.appfolder"

HELPER = r'''
import dbus, dbus.service, sys, json
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib
DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
out_path = sys.argv[1]
timeout_ms = int(sys.argv[2])
bus_name = sys.argv[3] if len(sys.argv) > 3 else 'local.appfolder'
class D(dbus.service.Object):
    def __init__(self):
        dbus.service.Object.__init__(self, bus, '/wd')
    @dbus.service.method(bus_name, in_signature='s', out_signature='')
    def Cursor(self, xy):
        x, y = xy.split(",")
        open(out_path, 'w').write(json.dumps({"x": float(x), "y": float(y)}))
        GLib.MainLoop().quit()
    @dbus.service.method(bus_name, in_signature='s', out_signature='')
    def Dump(self, txt):
        open(out_path, 'w').write(txt)
name = dbus.service.BusName(bus_name, bus,
                            replace_existing=True, allow_replacement=True,
                            do_not_queue=True)
d = D()
loop = GLib.MainLoop()
GLib.timeout_add(timeout_ms, loop.quit)
loop.run()
'''

SCRIPT = (
    'var c = workspace.cursorPos; '
    'callDBus("local.appfolder", "/wd", "local.appfolder", "Cursor", '
    'String(c.x) + "," + String(c.y));'
)


def build_script(bus: str) -> str:
    """KWin probe posting cursorPos to the given bus name (single-string payload)."""
    return (
        'var c = workspace.cursorPos; '
        f'callDBus("{bus}", "/wd", "{bus}", "Cursor", '
        'String(c.x) + "," + String(c.y));'
    )


def _gdbus(*args, timeout=5):
    return subprocess.run(
        ["gdbus", *args],
        capture_output=True, text=True, timeout=timeout,
    )


class Query:
    """A cursor query in flight. start() is instant; finish() returns (x, y)."""

    def __init__(self, timeout_ms: int = 1500):
        self.timeout_ms = timeout_ms
        self.result_path = os.path.join(
            os.environ.get("XDG_RUNTIME_DIR", "/tmp"),
            f"appfolder-cursor-{os.getpid()}.json",
        )
        self.script_path = os.path.join(
            os.environ.get("XDG_RUNTIME_DIR", "/tmp"),
            f"appfolder-probe-{os.getpid()}.js",
        )
        self.name = f"appfolder-cursor-{os.getpid()}"
        self.helper: subprocess.Popen | None = None
        self.enabled = os.environ.get("APPFOLDER_CENTER", "0") != "1"
        self._started = False
        self._names: list[str] = []
    def start(self) -> None:
        """Spawn the DBus helper now; returns immediately."""
        if not self.enabled or self._started:
            return
        self._started = True
        Path(self.script_path).write_text(SCRIPT)
        self.helper = subprocess.Popen(
            [sys.executable, "-c", HELPER, self.result_path, str(self.timeout_ms)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )

    def finish(self) -> tuple[float, float]:
        """Complete the query: load+run the KWin probe, read the result.

        Must be called after start(). Returns (x, y) logical, or (-1, -1).
        """
        result = (-1.0, -1.0)
        if not self.enabled:
            return result
        if not self._started:
            self.start()
        if self.helper is None:
            return result
        try:
            # wait for the helper's service to be up
            up = False
            deadline = time.monotonic() + self.timeout_ms / 1000.0
            while time.monotonic() < deadline:
                r = _gdbus("call", "--session", "--dest", "org.freedesktop.DBus",
                           "--object-path", "/org/freedesktop/DBus",
                           "--method", "org.freedesktop.DBus.ListNames")
                if "local.appfolder" in r.stdout:
                    up = True
                    break
                time.sleep(0.02)
            if not up:
                return result

            # load+run the probe; retry a couple of times in case KWin was
            # briefly busy or the callback raced a stale service owner.
            for attempt in range(3):
                used_name = self.name if attempt == 0 else f"{self.name}-{attempt}"
                self._names.append(used_name)
                r = _gdbus("call", "--session", "--dest", "org.kde.KWin",
                           "--object-path", "/Scripting",
                           "--method", "org.kde.kwin.Scripting.loadScript",
                           self.script_path, used_name)
                m = re.match(r"\((\d+),\)", r.stdout.strip())
                if not m:
                    continue
                sid = m.group(1)

                _gdbus("call", "--session", "--dest", "org.kde.KWin",
                       "--object-path", f"/Scripting/Script{sid}",
                       "--method", "org.kde.kwin.Script.run")

                deadline = time.monotonic() + (0.5 if attempt < 2 else 1.0)
                while time.monotonic() < deadline:
                    if os.path.exists(self.result_path):
                        try:
                            data = json.loads(Path(self.result_path).read_text())
                            result = (float(data["x"]), float(data["y"]))
                        except Exception:
                            pass
                        return result
                    time.sleep(0.01)
                if attempt < 2:
                    # clear the stale helper (it owns the name) and respawn
                    try:
                        self.helper.terminate()
                        self.helper.wait(timeout=1)
                    except Exception:
                        pass
                    self.helper = subprocess.Popen(
                        [sys.executable, "-c", HELPER, self.result_path, str(self.timeout_ms)],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        start_new_session=True,
                    )
                    deadline = time.monotonic() + 1.0
                    while time.monotonic() < deadline:
                        r = _gdbus("call", "--session", "--dest", "org.freedesktop.DBus",
                                   "--object-path", "/org/freedesktop/DBus",
                                   "--method", "org.freedesktop.DBus.ListNames")
                        if "local.appfolder" in r.stdout:
                            break
                        time.sleep(0.02)
        finally:
            self.cleanup()
        return result

    def cleanup(self) -> None:
        for n in self._names:
            _gdbus("call", "--session", "--dest", "org.kde.KWin",
                   "--object-path", "/Scripting",
                   "--method", "org.kde.kwin.Scripting.unloadScript", n)
        if self.name and self.name not in self._names:
            _gdbus("call", "--session", "--dest", "org.kde.KWin",
                   "--object-path", "/Scripting",
                   "--method", "org.kde.kwin.Scripting.unloadScript", self.name)
        if self.helper is not None:
            try:
                self.helper.terminate()
                self.helper.wait(timeout=1)
            except Exception:
                self.helper.kill()
        for p in (self.result_path, self.script_path):
            try:
                os.unlink(p)
            except OSError:
                pass


def query_cursor(timeout_ms: int = 1500) -> tuple[float, float]:
    """One-shot convenience: start + finish."""
    q = Query(timeout_ms)
    return q.finish()

class Holder:
    """A long-lived warm cursor helper for daemons (~10 ms per query).

    Owns a per-process bus name (no cross-folder stealing), keeps one
    helper process parked on it, and runs a throwaway KWin probe per
    query. Respawn is automatic if the helper ever exits.
    """

    def __init__(self, helper_timeout_ms: int = 30 * 60 * 1000):
        self.helper_timeout_ms = helper_timeout_ms
        self.bus = f"local.appfolder.p{os.getpid()}"
        self.enabled = os.environ.get("APPFOLDER_CENTER", "0") != "1"
        run = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
        self.result_path = os.path.join(run, f"appfolder-live-{os.getpid()}.json")
        self.script_path = os.path.join(run, f"appfolder-live-{os.getpid()}.js")
        self.helper: subprocess.Popen | None = None
        self.seq = 0

    def start(self) -> None:
        """Spawn the helper now; returns immediately (warms up in background)."""
        if not self.enabled or self.alive():
            return
        Path(self.script_path).write_text(build_script(self.bus))
        self._spawn()

    def _spawn(self) -> None:
        self.helper = subprocess.Popen(
            [sys.executable, "-c", HELPER, self.result_path,
             str(self.helper_timeout_ms), self.bus],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )

    def alive(self) -> bool:
        return self.helper is not None and self.helper.poll() is None

    def _name_up(self, timeout_s: float = 2.0) -> bool:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            r = _gdbus("call", "--session", "--dest", "org.freedesktop.DBus",
                       "--object-path", "/org/freedesktop/DBus",
                       "--method", "org.freedesktop.DBus.ListNames")
            if self.bus in r.stdout:
                return True
            time.sleep(0.02)
        return False

    def query(self, wait_s: float = 0.5, retries: int = 2) -> tuple[float, float]:
        """Current cursor in logical px, or (-1, -1) when centered/disabled.

        Fast path unchanged (~15 ms warm): load, run, one 0.5 s wait. Only
        on failure do we retry (bounded: retries × wait_s), since a miss
        parks the popup screen-centered instead of over the icon.
        """
        if not self.enabled:
            return (-1.0, -1.0)
        if not self.alive():
            self.start()
        if not self._name_up():
            return (-1.0, -1.0)
        result = (-1.0, -1.0)
        for attempt in range(retries + 1):
            try:
                os.unlink(self.result_path)
            except OSError:
                pass
            name = f"appfolder-live-{os.getpid()}-{self.seq}"
            self.seq += 1
            try:
                r = _gdbus("call", "--session", "--dest", "org.kde.KWin",
                           "--object-path", "/Scripting",
                           "--method", "org.kde.kwin.Scripting.loadScript",
                           self.script_path, name)
                m = re.match(r"\((\d+),\)", r.stdout.strip())
                if not m:
                    continue
                _gdbus("call", "--session", "--dest", "org.kde.KWin",
                       "--object-path", f"/Scripting/Script{m.group(1)}",
                       "--method", "org.kde.kwin.Script.run")
                deadline = time.monotonic() + wait_s
                while time.monotonic() < deadline:
                    if os.path.exists(self.result_path):
                        try:
                            data = json.loads(Path(self.result_path).read_text())
                            result = (float(data["x"]), float(data["y"]))
                        except Exception:
                            pass
                        break
                    time.sleep(0.005)
                if result[0] >= 0:
                    break
                # Miss: helper may be wedged; respawn once before retrying.
                if attempt < retries:
                    try:
                        if self.helper is not None:
                            self.helper.terminate()
                            self.helper.wait(timeout=1)
                    except Exception:
                        pass
                    self.helper = None
                    self.start()
                    if not self._name_up(timeout_s=1.0):
                        break
            finally:
                _gdbus("call", "--session", "--dest", "org.kde.KWin",
                       "--object-path", "/Scripting",
                       "--method", "org.kde.kwin.Scripting.unloadScript", name)
        return result
    def probe(self, js_body: str, wait_s: float = 1.0) -> str:
        """Run a KWin snippet that ends with Dump(payload); return payload.

        The snippet must call
            callDBus("<bus>", "/wd", "<bus>", "Dump", payload)
        with self.bus as <bus> (single-string payload, KWin 6.7 limit).
        Returns "" on any failure. Helper stays warm across calls.
        """
        if not self.enabled:
            return ""
        if not self.alive():
            self.start()
        if not self._name_up():
            return ""
        try:
            os.unlink(self.result_path)
        except OSError:
            pass
        script_path = os.path.join(
            os.environ.get("XDG_RUNTIME_DIR", "/tmp"),
            f"appfolder-probe-{os.getpid()}-{self.seq}.js")
        name = f"appfolder-probe-{os.getpid()}-{self.seq}"
        self.seq += 1
        try:
            Path(script_path).write_text(js_body)
            r = _gdbus("call", "--session", "--dest", "org.kde.KWin",
                       "--object-path", "/Scripting",
                       "--method", "org.kde.kwin.Scripting.loadScript",
                       script_path, name)
            m = re.match(r"\((\d+),\)", r.stdout.strip())
            if not m:
                return ""
            _gdbus("call", "--session", "--dest", "org.kde.KWin",
                   "--object-path", f"/Scripting/Script{m.group(1)}",
                   "--method", "org.kde.kwin.Script.run")
            deadline = time.monotonic() + wait_s
            while time.monotonic() < deadline:
                if os.path.exists(self.result_path):
                    try:
                        return Path(self.result_path).read_text()
                    except OSError:
                        return ""
                time.sleep(0.005)
        finally:
            _gdbus("call", "--session", "--dest", "org.kde.KWin",
                   "--object-path", "/Scripting",
                   "--method", "org.kde.kwin.Scripting.unloadScript", name)
            try:
                os.unlink(script_path)
            except OSError:
                pass
        return ""

    def stop(self) -> None:
        if self.helper is not None:
            try:
                self.helper.terminate()
                self.helper.wait(timeout=1)
            except Exception:
                try:
                    self.helper.kill()
                except Exception:
                    pass
            self.helper = None
        for p in (self.result_path, self.script_path):
            try:
                os.unlink(p)
            except OSError:
                pass
