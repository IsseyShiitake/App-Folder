// SPDX-License-Identifier: MIT
// App Folder — macOS-style app folders for the Plasma panel (plasmoid v2).
//
// Native applet: one widget per folder (add from "Add widgets"), each with
// its own config. The shell owns the popup (anchor, theme, blur,
// outside-click), so the v1 daemon/cursor/layer-shell machinery is gone.
// Launch + file reads go through the executable-engine bridge below.

import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtQuick.Dialogs as Dialogs

import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // Standard dialog background (themed + blurred by the shell). Without
    // this the popup draws nothing of its own in adapt mode — the reported
    // "background disappears" bug.
    Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground | PlasmaCore.Types.ConfigurableBackground

    // Panel icon follows the folder icon (per-instance config, live).
    Plasmoid.icon: plasmoid.configuration.folderIcon || "folder"

    // Keep-open pin: while set, the shell must not collapse the popup on
    // outside focus, otherwise starting a drag from another window kills
    // the drop target first. Off by default = stock shell behavior.
    property bool pinned: false
    // Frame size captured when settings opens; Back re-pins to it (0 = no
    // capture yet, fall back to the canonical 3x3).
    property int preSettingsW: 0
    property int preSettingsH: 0
    // True while a context menu is open. QQC2 menus with popupType Window
    // are Qt::Popup windows, which the shell's PopupPlasmaWindow already
    // counts as "child has focus" — this guard is defense in depth so a
    // focus flip through the menu window can never deactivate-close the
    // folder underneath (and it is not the user's Keep-open pin, so it
    // never flips the menu's checkable state).
    property bool menuGuard: false
    // The popup hides on deactivation (stock Plasma behavior; the S44b
    // diag-era `&& !diag` immunity was removed 2026-09-22 S48 — the thief
    // theory died with the hover-input localization, and the immunity had
    // become a user-visible bug: folders stopped closing on outside click).
    hideOnWindowDeactivate: !pinned && !menuGuard

    // The fullRepresentation visibility flip is not a reliable close signal
    // across hosts, so reset view state on collapse here instead: reopening
    // always lands on the grid, never on a stale settings page.
    onExpandedChanged: {
        trace("expanded " + root.expanded)
        if (!root.expanded) {
            // Persist the dialog chrome BEFORE the flush: config survives
            // plasmashell restarts (the in-memory shrinkChrome does not), so
            // even the FIRST open of a session knows the grid->window offset
            // and can run the pre-map tile-exact write instead of leaving a
            // +-1px residue for the stillness snap to enforce later (the
            // "settles a few pixels lower" jitter).
            var zrep = fullRepresentationItem
            var zwin = (zrep && zrep.Window) ? zrep.Window.window : null
                if (zrep && zrep.gridView && zwin && zwin.width >= 10 && tile > 0) {
                    var zcw = Math.round(zwin.width - zrep.gridView.width)
                    var zch = Math.round(zwin.height - zrep.gridView.height)
                    if (zcw > 0 && zcw < tile && zch > 0 && zch < tile) {
                        plasmoid.configuration.chromeW = zcw
                        plasmoid.configuration.chromeH = zch
                    }
                }
                // Expire the hook-at-map open intent (belt-and-braces; the
                // hook's own 2.5s age gate is the real expiry).
                plasmoid.configuration.afMapAt = "0"
                flushConfig()
            trace("collapse settings=" + showSettings)
            // Final snap: the session may end on a half-tile size (the
            // in-session settle only fires after a long stillness, and
            // mid-drag triggers must never move the frame). Nearest-round
            // here; the next open clamps straight to it. SKIPPED when the
            // grid cannot be trusted: collapsed straight off the settings
            // page (the grid still wears the pinned settings size at this
            // instant — showSettings flips a few lines below), or dynamic
            // resizing off (the picked grid is the size of record; the
            // next open's pre-map write restores it).
            var crep = fullRepresentationItem
            if (dynamicResize && !showSettings && crep && crep.gridView && tile > 0) {
                var cgw = crep.gridView.width
                var cgh = crep.gridView.height
                if (cgw >= 1 && cgh >= 1) {
                    snappedW = Math.min(15, Math.max(1, Math.round(cgw / tile))) * tile
                    snappedH = Math.min(15, Math.max(1, Math.round(cgh / tile))) * tile
                }
            }
            geo("close")
            // Flush any unpersisted settings edits before dropping the
            // settings flag: sliders persist on RELEASE (S55), but a
            // KEYBOARD-adjusted slider (arrow keys — no press, no release
            // signal) would otherwise be lost on close.
            if (showSettings)
                persistUi()
            showSettings = false
            pinned = false
            // Direct reset, never rely on the menus' own close signals: a
            // menu whose popup window died with the folder never emits them
            // (rig-proven), and a latched guard permanently disables the
            // outside-click close (hideOnWindowDeactivate).
            menuGuard = false
            // Never hand a fresh window stale clamps (hide can land mid-hold)
            // — and never leave a shrink stepper ticking against a hidden
            // window (it would write stale glide sizes into the new one).
            enforcingW = false
            enforcingH = false
            shrinkStop("w")
            shrinkStop("h")
            grabSeen = false
            releaseSeen = false
            recenterRounds = 0
            openPlaceArmed = false
            wantExact = false
            backstop.stop()
            backstopTries = 0
            armDebounce.stop()
            // KWin-truth position dies with the window; the next open
            // re-seeds it from the fresh map-time coordinates.
            trueX = -1
            trueY = -1
            if (fullRepresentationItem) {
                // Drop stale hover: the window hidden under the cursor
                // never delivered hover-leave, and the delegates SURVIVE
                // the close/reopen cycle (the stuck-tooltip bug).
                fullRepresentationItem.setHoverArmed(false)
                fullRepresentationItem.dragSource = -1
                fullRepresentationItem.dropTarget = -1
                fullRepresentationItem.closeAllMenus()
            }
        } else {
            // Open path: always land on the grid (close-flips are
            // unreliable on some hosts, leaving reopen stuck in settings).
            showSettings = false
            root.applyShellSlide()
            root.refreshPanelMode()
            if (fullRepresentationItem) {
                // hoverArmed re-arms AFTER the disarm at collapse cleared
                // any stale hover state (a popup hidden under the cursor
                // never delivers hover-leave). The rep's own onVisibleChanged
                // never fires on this shell build — expanded flips are the
                // reliable signal (trace-proven).
                fullRepresentationItem.setHoverArmed(true)
                fullRepresentationItem.dragSource = -1
                fullRepresentationItem.dropTarget = -1
                fullRepresentationItem.closeAllMenus()
                // ARM (not start) the content open animation: the window is
                // UNPLACED here and renders nothing, so a ramp started
                // now burns invisibly against map time. It is started at the
                // window's visibility flip (the starter that wins in
                // practice), with the steady-render gate and the 900ms
                // fallback as alternates — and because the ramp is
                // wall-clock Timer driven (openRamp), a presentation stall
                // around map can no longer freeze it into half-states.
                fullRepresentationItem.armOpenAnim()
            }
            var win = (fullRepresentationItem && fullRepresentationItem.Window)
                ? fullRepresentationItem.Window.window : null
            // Clamp straight to the whole-tile size: collapse stored the
            // nearest-round target in snappedW/H, and the shell restore is
            // at most a pixel or two off it. Every open lands pinned; the
            // lift frees the dialog 250ms later, so no half-tile size and
            // no stale manual size is ever shown.
            if (win && win.width >= 10 && tile > 0) {
                // Fresh window: drop the previous session's KWin-truth
                // position (re-seeded from map-time coords below).
                trueX = -1
                trueY = -1
                // Quantize the GRID size, not the raw window: the window
                // includes dialog chrome, and rounding (grid+chrome)/tile
                // rounds a tile HIGH once chrome crosses half a tile — the
                // frame then re-opened one icon wider than saved. Chrome
                // preference: LIVE (window minus grid measured right now —
                // the grid survives the close, so this is exact), then the
                // chrome frozen at the last snap. Without either (very first
                // open, grid not laid out yet) fall back to 0.
                var erep = fullRepresentationItem
                var chW = 0
                var chH = 0
                if (erep && erep.gridView) {
                    var liveW = Math.round(win.width - erep.gridView.width)
                    var liveH = Math.round(win.height - erep.gridView.height)
                    if (liveW > 0 && liveW < tile)
                        chW = liveW
                    if (liveH > 0 && liveH < tile)
                        chH = liveH
                }
                if (chW === 0 && shrinkChromeW > 0 && shrinkChromeW < tile)
                    chW = shrinkChromeW
                if (chH === 0 && shrinkChromeH > 0 && shrinkChromeH < tile)
                    chH = shrinkChromeH
                // Last resort: chrome persisted at the previous collapse
                // (survives restarts — first open of a session included).
                if (chW === 0 && plasmoid.configuration.chromeW > 0
                    && plasmoid.configuration.chromeW < tile)
                    chW = plasmoid.configuration.chromeW
                if (chH === 0 && plasmoid.configuration.chromeH > 0
                    && plasmoid.configuration.chromeH < tile)
                    chH = plasmoid.configuration.chromeH
                // Dynamic resizing OFF keeps the picked grid as the size of
                // record — never re-derive from the restored window (a
                // stray drag or mid-glide close would otherwise stick); the
                // pre-map write below then forces the window onto it.
                if (!fixedGridSize()) {
                    snappedW = Math.min(15, Math.max(1, Math.round((win.width - chW) / tile))) * tile
                    snappedH = Math.min(15, Math.max(1, Math.round((win.height - chH) / tile))) * tile
                }
                // PRE-MAP tile-exact write: the saved popup size is whatever
                // the window wore at hide (mid-glide closes save uneven
                // sizes), and correcting it AFTER the map is visible as a
                // grow/shrink a beat after opening plus a shell re-anchor
                // that fights the recenter (the "two-step open" and the
                // "frame adjusts itself half a second late"). The window
                // object exists here with the restored size but is still
                // UNPLACED — writing now means it maps at the final size
                // and nothing moves afterwards. Direct writes are the
                // proven both-direction channel (the stepper's).
                if (chW > 0 && chH > 0) {
                    var exW = snappedW + chW
                    var exH = snappedH + chH
                    if (Math.abs(Math.round(win.width) - exW) > 1
                        || Math.abs(Math.round(win.height) - exH) > 1) {
                        win.width = exW
                        win.height = exH
                        trace("open-exact " + Math.round(win.width) + "x" + Math.round(win.height)
                            + " -> " + exW + "x" + exH)
                    }
                } else {
                    // No chrome knowledge this early: defer the tile-exact
                    // write to the 350ms exactTimer (see wantExact).
                    wantExact = true
                    exactTimer.restart()
                }
                // The anchor is the PANEL ICON's screen center — never the
                // popup's own x. Plasma re-opens a recently-closed popup at
                // its last (possibly detached) position, so recording
                // win.x here anchored the frame to the detached spot and
                // recentering "correctly" kept it detached (the video).
                // NOTE: compactRepresentationItem is a PlasmoidItem (root)
                // property, NOT on the plasmoid object — reading it from
                // plasmoid silently returned undefined and the anchor NEVER
                // captured (the S26 fix never actually took; the win.x
                // fallback anchored to the wrong spot). root. is the way.
                // captureAnchor() also refreshes anchorCy + the panel-screen
                // bounds the map intent clamps against.
                captureAnchor()
                if (anchorCx <= 0 && win.x > 0) {
                    // No compact item (e.g. plasmawindowed host): fall back
                    // to the open position, but only when it is real.
                    anchorCx = win.x + win.width / 2
                }
                // Publish the open intent for the KWin hook (see
                // publishMapIntent): still pre-map, where latency is free.
                publishMapIntent()
            } else {
                snappedW = columns * tile
                snappedH = columns * tile
            }
            root.sizePinned = true
            enforcingW = false
            enforcingH = false
            shrinkStop("w")
            shrinkStop("h")
            pinRetries = 0
            openPlaceArmed = true
            // Per-open budget for the "exactly one real KWin write per open"
            // rule (see borderArmWrite) and the never-placed backstop probe.
            kwinWriteThisOpen = false
            placeCheck.restart()
            checkDiag()
            // Bootstrap the shared hook + query scripts here, not at
            // Component.onCompleted: the executable engine can race applet
            // construction and silently drop early commands (observed:
            // unwritten query scripts).
            ensureHookScript()
            ensureQueryScript()
            // Open-path centering is owned by the PLACEMENT hook (first
            // x>0 below) plus its verify-converge loop — NOT a write here:
            // at the flip the window is unplaced, and QML win.x still holds
            // the PREVIOUS map's frozen value (x only ever changes at map),
            // so a recenter here seeds KWin-truth with a stale position and
            // fires a script against a window KWin cannot even see yet.
            root.lastRecenterAt = 0
            root.recenterRounds = 0
            // Belt-and-braces for the render-gated animation start (see
            // onAfterRendering): never let icons sit at openProgress 0.
            openFallback.restart()
            root.lastRenderAt = 0
            if (fullRepresentationItem) {
                fullRepresentationItem.dragSource = -1
                fullRepresentationItem.dropTarget = -1
                fullRepresentationItem.closeAllMenus()
            }
            sizeSettle.restart()
            geo("open")
        }
    }
    // Dialog sizing, per AppletPopup source: with a saved size, implicit
    // sizes are ignored and the save rewrites on every hide — but Layout
    // minimum/maximum always clamp. Pinned transitions (open/Back) clamp
    // to content; settled, enforcement clamps a single side per off-grid
    // axis (manual drags requantize via snapPause/snapFrame below).
    // Lift the pin shortly after transitions so manual resizes work.
    Timer {
        id: sizeSettle
        interval: 250
        repeat: false
        onTriggered: {
            // Dynamic resizing OFF keeps the pin FOREVER (user-directed
            // S57): min==max==snapped clamps the xdg to one size, so a
            // border/corner grab moves nothing at all (previously the
            // zones — armed by the placement recenter's KWin write — let
            // the frame follow the drag and spring back on release).
            root.sizePinned = !dynamicResize
            geo("lift")
            // Placement fallback: if openPlaceArmed is STILL set, the popup
            // has not reported a fresh placement — either the map is slow
            // (>250ms; the hook fires later and runs its own recenter) or
            // the window mapped at the SAME x as the previous open, in
            // which case QML x never changes and the hook NEVER fires
            // (win.x freezes at map). Recenter here: in the same-x case
            // this IS the placement correction; in the slow-map case the
            // write finds no mapped window (no-ops) and the verify query
            // self-corrects once it maps. Do NOT clear the flag — a
            // placement that arrives later still consumes it.
            if (root.openPlaceArmed) {
                root.captureAnchor()
                // Verify-only, never write (the placement-hook comment): the
                // shell's own placement is the policy target; a read-only
                // query keeps truth fresh for later verdicts.
                root.runStateQuery()
                if (root.wantExact)
                    exactTimer.restart()
                // Slow-map/equal-x fallback path gets its border-arm write
                // too (no-op when a placement path already wrote).
                root.borderArmWrite()
            }
            // A release that arrived while the open pin held the window:
            // resolve it now that enforcement is possible again.
            if (root.releaseSeen) {
                root.releaseSeen = false
                root.snapFrame(true)
            }
            // No blind recenter here (it wrote with a stale map-time truth
            // while the open write's verification was still pending). The
            // verify loop owns centering; only kick a query if no write is
            // under verification at all (open write never fired — e.g. a
            // host whose win.x is 0 at map).
            if (!verifyPending)
                runStateQuery()
        }
    }
    // Belt-and-braces for the render-gated animation start: if no frame was
    // ever rendered within 900ms of the expand (exotic host, signal quirk),
    // start the ramp anyway — an animation that runs invisibly is a safe
    // failure mode; icons stuck at openProgress 0 (opacity 0 = fully
    // transparent under the S54f static fade-in) are not.
    Timer {
        id: openFallback
        interval: 900
        repeat: false
        onTriggered: {
            if (root.expanded && fullRepresentationItem
                && !fullRepresentationItem.openAnimStarted) {
                fullRepresentationItem.startOpenAnim()
                trace("anim start fallback")
            }
        }
    }
    // Never-placed backstop (S32c residual): one observed open right after
    // a plasmashell restart mapped with QML win stuck at 0,0 (grid-sized,
    // chrome 0) — invisible to every correction path, which all require
    // win.x > 0. If the window exists with a real size but still reports
    // x == 0 this late, ask KWin directly: the query payload carries the
    // REAL position even when QML x is 0, and handleQueryList's truth
    // refresh + position self-correction then recenters (which also runs a
    // KWin write — arming the border zones). A popup legitimately clamped
    // to the screen's left edge sits at x == 0 too; the query then finds it
    // already centered and writes nothing, so the probe is safe there.
    Timer {
        id: placeCheck
        interval: 1200
        repeat: false
        onTriggered: {
            if (!root.expanded || showSettings)
                return
            var rep = fullRepresentationItem
            var win = (rep && rep.Window) ? rep.Window.window : null
            if (win && win.width >= 10 && Math.round(win.x) === 0) {
                trace("unplaced-backstop query")
                runStateQuery()
            }
        }
    }
    // Recorded whole-tile target (grid pixels). While a resize grab
    // holds, the frame follows the cursor freely and this target only
    // tracks (snapPause sync below); the glide onto the target fires on
    // buttonless pointer motion — the release. Open/Back pin straight to
    // it.
    property int snappedW: columns * tile
    property int snappedH: columns * tile
    // Single-sided enforcement state: only an off-grid axis is clamped, and
    // only on the side pulling toward the target, so the resize grab stays
    // alive in every other direction (a full min==max freeze mid-grab wedges
    // the shell resize and needs a reopen to clear).
    property bool enforcingW: false
    property bool enforcingH: false
    property bool pushW: false
    property bool pushH: false
    property double enforceSince: 0
    property int pinRetries: 0
    // Stillness sync: after external size changes settle, record the
    // nearest-tile target (never enforce — enforcement needs buttonless
    // pointer evidence, i.e. the release, so the frame always follows the
    // cursor undisturbed while a grab holds).
    Timer {
        id: snapPause
        interval: 400
        repeat: false
        onTriggered: root.snapFrame(false)
    }
    // enforce=false: bookkeeping sync only (recorded target follows the
    // live size); enforce=true: clamp + glide to the nearest whole tile.
    function snapFrame(enforce) {
        if (showSettings || !root.expanded) {
            enforcingW = false
            enforcingH = false
            return
        }
        // Watchdog backstop: enforcement normally ends within ~320ms (glide
        // + hold) or instantly via the divergence check; anything older is
        // a wedged state, so clear the flags before deciding anything.
        if ((enforcingW || enforcingH) && Date.now() - enforceSince > 1500) {
            enforcingW = false
            enforcingH = false
        }
        // Retry (not drop) covers drags started inside the 250ms sizeSettle
        // pin window after open / Back-from-settings. Bounded: a stuck pin
        // must never churn the timer forever.
        if (sizePinned) {
            if (pinRetries < 10) {
                pinRetries++
                snapPause.restart()
            }
            return
        }
        // In flight: the KWin shrink stepper owns the window. Re-entering
        // mid-stepper re-arms the animation clock from a stale size and
        // stacks writes that fight each other (proven: 7s of glide-cancel
        // churn on one snap).
        if (enforcingW || enforcingH || shrinkWActive || shrinkHActive)
            return
        pinRetries = 0
        var rep = fullRepresentationItem
        if (!rep || !rep.gridView)
            return
        var gw = rep.gridView.width
        var gh = rep.gridView.height
        if (gw < 1 || gh < 1 || tile < 1)
            return
        // Nearest whole tiles, per spec: an uneven end position (say 3.4
        // tiles) snaps to the CLOSEST multiple (3), never systematically
        // up. Directional ceil made any post-release size drift (Wayland
        // configure lag on a fast drag back) grow a full tile instead of
        // reverting — the out-and-back bug.
        var cols = Math.min(15, Math.max(1, Math.round(gw / tile)))
        var rows = Math.min(15, Math.max(1, Math.round(gh / tile)))
        // Dynamic resizing OFF never adopts the dragged size: the picked
        // grid stays the target, so a stray border drag springs back on
        // release (enforcement below runs against snappedW/H).
        var fixed = fixedGridSize()
        var tw = fixed ? snappedW : cols * tile
        var th = fixed ? snappedH : rows * tile
        // 1px tolerance per axis, unconditionally: compositor rounding or a
        // restore residue already at the target is never a reason to clamp.
        // The old non-integer-remainder exception made a lone 1px diff
        // enforce a full 170ms stepper whose window write re-anchored the
        // popup DOWN a pixel ("settles lower after open") while buying
        // nothing visible — a 1px off-tile residue is imperceptible, the
        // re-anchor jump is not. Sizes reach integers on their own; the
        // pre-map exact write (with persisted chrome) prevents the residue
        // at the source instead.
        var needW = Math.abs(gw - tw) > 1
        var needH = Math.abs(gh - th) > 1
        if (!needW && !needH) {
            // Silent settle: keep the recorded target in sync so the next
            // open/Back uses what is actually on screen.
            snappedW = tw
            snappedH = th
            verifyTries = 0
            return
        }
        // Bookkeeping only: pointer evidence of a held grab or a plain
        // stillness sync — record the target, move nothing. The frame is
        // only ever clamped on buttonless pointer motion (the release),
        // open/close pins, or a convergence retry.
        if (!enforce) {
            snappedW = tw
            snappedH = th
            verifyTries = 0
            return
        }
        // Fresh convergence budget per new target: a previous gesture's
        // exhausted retries must not starve this one.
        if (tw !== snappedW || th !== snappedH)
            verifyTries = 0
        snappedW = tw
        snappedH = th
        var win0 = (rep && rep.Window) ? rep.Window.window : null
        if (!win0) {
            // No window handle (popup mid-construction): bookkeeping only;
            // the stillness sync or a later hover re-snaps once the window
            // exists. Enforcing without one leaves the stepper blind (no
            // chrome to freeze) and every write would be skipped anyway.
            return
        }
        // Freeze the grid->window chrome ONCE, from a window and grid
        // measured in the same instant. Re-measuring per tick on the panel
        // read a grid that lags the window by a layout pass, so every
        // step baked the previous step's delta into the chrome and each
        // write overshot — the self-sustaining "+1 icon width, then +1
        // icon height" runaway that began the moment the cursor entered
        // the frame (each hover re-armed the release trigger, the oracle
        // saw the drift as a fresh release, and the cycle never ended).
        shrinkChromeW = Math.round(win0.width - gw)
        shrinkChromeH = Math.round(win0.height - gh)
        // Order matters: park glideCur* on the measured size BEFORE the
        // enforcing flags flip — stale values here poisoned every reader
        // that sampled between the two assignments.
        glideCurW = needW ? gw : tw
        glideCurH = needH ? gh : th
        pushW = tw > gw
        pushH = th > gh
        enforcingW = needW
        enforcingH = needH
        enforceSince = Date.now()
        // Enforcement is ONE channel: the direct-write stepper below,
        // animating BOTH directions with the same OutCubic curve. The
        // min-hint path is retired (it only ever grew, its binding
        // evaluation raced the flag flips, and KWin re-clamped external
        // resizes against it mid-glide); Layout.maximum* was always inert
        // on Wayland (xdg_toplevel has no max_size — proven: 5 enforcement
        // cycles moved nothing, the "must try 2-3 times" bug).
        // One constant duration for every snap: the distance-scaled
        // 110-300ms range made identical gestures feel different run to
        // run ("looks different sometimes"). 170ms reads as a quick,
        // uniform settle regardless of hop size.
        var glideDur = 170
        snapClear.interval = glideDur + 150
        // Both axes go to the direct-write stepper. The old split
        // (shrink = writes, grow = min-hint glide) left grow-by-1px gaps
        // unfilled — a min only clamps EXTERNAL resizes, nothing re-writes
        // an already-shown window, so 539 stayed 539 with a 540 min forever
        // (the 1px wedge). One path, exact integer finals, no binding
        // evaluation order to race.
        if (needW) {
            shrinkFromW = gw
            shrinkToW = tw
            shrinkStartW = Date.now()
            shrinkWActive = true
            shrinkWTick.restart()
        }
        if (needH) {
            shrinkFromH = gh
            shrinkToH = th
            shrinkStartH = Date.now()
            shrinkHActive = true
            shrinkHTick.restart()
        }
        trace("snap gw=" + Math.round(gw) + " gh=" + Math.round(gh)
            + " -> " + (tw / tile) + "x" + (th / tile) + " " + (pushW ? "W+" : "W-") + (pushH ? "H+" : "H-")
            + (needW && !pushW ? "/kw" : "") + (needH && !pushH ? "/kh" : ""))
        recenterIfNeeded()
        snapClear.restart()
    }
    // Clamp hold must outlast the glide (170ms) plus a configure-ack
    // margin; the divergence check below releases early if the user
    // resumes dragging, so this is only the worst-case wall.
    Timer {
        id: snapClear
        interval: 320
        repeat: false
        onTriggered: {
            root.enforcingW = false
            root.enforcingH = false
            // A release that arrived while this motion owned the window:
            // the user's verdict outranks the old target — requantize NOW
            // from the landed size.
            if (root.releaseSeen && !(shrinkWActive || shrinkHActive)) {
                root.releaseSeen = false
                root.snapFrame(true)
                root.recenterIfNeeded(true)
                geo("free")
                return
            }
            // Convergence proof: if the window missed the target (configure
            // races can drop the enforcement resize), requantize again —
            // bounded, so a fight between two size writers cannot churn.
            if (shrinkWActive || shrinkHActive) {
                // A glide or stepper still owns the window; verification now
                // would burn a retry against a moving size (the guard eats
                // the re-snap and the off-tile rest wedges — the video bug
                // "stays halfway until I move the mouse in"). Re-check when
                // motion ends.
                snapClear.restart()
                geo("free")
                return
            }
            var rep = fullRepresentationItem
            if (rep && rep.gridView && tile > 0 && verifyTries < 3) {
                var gw = rep.gridView.width
                var gh = rep.gridView.height
                if (Math.abs(gw - snappedW) > 1 || Math.abs(gh - snappedH) > 1) {
                    verifyTries++
                    root.snapFrame(true)
                } else {
                    verifyTries = 0
                    // Arrived: the shell re-derives the popup x whenever
                    // the window changed size under it — pull the frame
                    // back over the icon now that motion ended.
                    root.recenterIfNeeded(true)
                }
            }
            geo("free")
        }
    }
    property int verifyTries: 0
    // Glide state (grid pixels): the shrink stepper's live per-axis value,
    // parked on snapped* whenever no snap is running (snapFrame start,
    // grabCancel, stepper completion).
    property real glideCurW: 0
    property real glideCurH: 0
    // Release detection via BUTTON STATE, not event absence: a resize
    // grab exists only while its initiating button is held, and every
    // pointer event the popup receives during the grab carries that
    // button (the shell's EdgeEventForwarder preserves me->buttons in
    // the border-strip synthetic events too). So: any event with buttons
    // held = grab may be active = NEVER enforce; the first buttonless
    // pointer motion = the release = snap + glide. This is correct
    // regardless of whether the compositor forwards pointer events
    // mid-grab.
    property double lastHeldAt: 0
    function pointerWake(held) {
        if (held) {
            lastHeldAt = Date.now()
            return
        }
        snapFrame(true)
    }
    // -- KWin grab events (compositor truth, push-delivered) ---------------
    // Release detector v3. A persistent KWin script (afhookS, shared by all
    // instances) hooks every window's moveResizedChanged — interactive
    // move/resize START/END transitions only; proven live: script-forced
    // and client-side geometry writes never fire it — and on each plasma
    // popup transition pushes "<seq> <flags> <x>,<y> <w>x<h>" into EVERY
    // App Folder widget's config key afEv<id> (KWin callDBus ->
    // plasmashell evaluateScript -> widget.writeConfig; live propagation
    // into QML bindings is dead on this build — proven — but the disk
    // write is immediate). This applet greps its key at 120ms while
    // expanded: release latency is one poll tick (~50-150ms), zero engine
    // load at rest, no capture windows, no wedges (a dropped grep just
    // re-reads the same value next tick — self-healing by construction).
    // A quiesced off-tile frame with no event verdict falls back to
    // one-shot state queries (same channel) every 1.5s: covers a dead
    // hook and the plasmawindowed harness (whose host window class the
    // hook filter intentionally skips).
    readonly property int instId: plasmoid.id !== undefined ? plasmoid.id : 0
    property string lastEv: ""
    property bool grabSeen: false        // saw this gesture's grab-start event
    property bool releaseSeen: false     // release arrived while motion owned the window
    property bool hookReady: false
    property int querySeq: 0
    property int backstopTries: 0
    property double lastHookCheckAt: 0
    // Popup anchor: the horizontal center the shell placed the frame at
    // open (over the panel icon). Enforcement resizes keep the top-left
    // corner fixed, so left-side drags leave the frame displaced from its
    // anchor; after each release we restore it (QML cannot move Wayland
    // windows — the KWin script channel can, proven by the harness).
    property real anchorCx: 0
    // Vertical center + panel-screen bounds, captured alongside anchorCx
    // (the hook-at-map intent needs them; recenterDesiredX keeps its own
    // proven window-side sources).
    property real anchorCy: 0
    property int scrEdgeL: 0
    property int scrEdgeR: 0
    property int scrEdgeT: 0
    property int scrEdgeB: 0
    // PLACEMENT POLICY (S40, user decision): "centered on icon, standard
    // Plasma clamping". The popup centers on the icon EXCEPT along the
    // panel's clamp axis, where it may never overhang the PANEL's extent —
    // the same rule libplasma applies at placement. The applet's target
    // therefore EQUALS the shell's initial placement: nothing corrects
    // anything, and the M1 open-teleport flash is gone by construction
    // (overhanging folders sit panel-flush, like every stock popup).
    // The panel bounds are read from the applet's own window — for a
    // panel applet that IS the panel view window, i.e. the exact rect
    // the shell clamps against. Clamp margin 8: rig-measured across five
    // popup spans (S42), the shell places the popup's right edge at
    // panelWindowRight - 8, exactly — our target must match so the intent
    // equals the shell's placement and no post-map correction ever fires.
    readonly property int panelPlaceMargin: 8
    property int panelEdgeL: 0
    property int panelEdgeR: 0
    property int panelEdgeT: 0
    property int panelEdgeB: 0
    property bool panelBoundsOk: false
    // KWin-truth window position. QML win.x/y on panel popups is frozen at
    // MAP TIME (xdg_popup positions are compositor-side; Qt never learns
    // about moves — proven live: after a recenter write KWin reported 712
    // while QML still said 463). Seeded at open (map-time == truth) and
    // refreshed from every matching event/query entry; position matching
    // compares truth to truth, never truth to the stale QML value.
    property real trueX: -1
    property real trueY: -1
    // The anchor MUST come from the panel icon, but at the expand flip the
    // shell may already be tearing the compact representation down
    // (observed live: auto-opened popups captured anchor=0 and every
    // recenter silently no-oped). While collapsed the compact item is
    // alive and rendered, so keep the anchor fresh at rest; expand uses
    // the last capture and refreshes it inline when it can.
    function captureAnchor() {
        var ci = null
        try { ci = root.compactRepresentationItem } catch (e) { ci = null }
        if (!ci && typeof plasmoid !== "undefined" && plasmoid.compactRepresentationItem)
            ci = plasmoid.compactRepresentationItem
        if (ci && ci.width > 0) {
            var gp = ci.mapToGlobal(Qt.point(ci.width / 2, ci.height / 2))
            if (gp.x > 0) {
                anchorCx = gp.x
                anchorCy = gp.y
                // Panel-screen bounds ride along: the compact icon is
                // always placed, while the popup window is UNPLACED at the
                // expand flip — the map intent clamps against these.
                if (ci.scrR > ci.scrL) {
                    scrEdgeL = ci.scrL
                    scrEdgeR = ci.scrR
                    scrEdgeT = ci.scrT
                    scrEdgeB = ci.scrB
                }
            }
        }
        // Panel WINDOW bounds (the S40 policy's clamp rect). For a panel
        // applet the applet's own window IS the panel view window — the
        // exact geometry libplasma clamps popups against. Read from root
        // first (survives compact-item teardown mid-open), falling back
        // to the compact item's window.
        var pw = null
        try { pw = (root.Window && root.Window.window) ? root.Window.window : null } catch (e3) { pw = null }
        if (!pw && ci) {
            try { pw = (ci.Window && ci.Window.window) ? ci.Window.window : null } catch (e4) { pw = null }
        }
        if (pw && pw.width > 20 && pw.height > 20) {
            // Orientation-neutral sanity gate: a vertical panel's window
            // is legitimately ~45px WIDE (the thin dimension) — only
            // implausible sub-icon sizes are rejected.
            panelEdgeL = Math.round(pw.x)
            panelEdgeT = Math.round(pw.y)
            panelEdgeR = Math.round(pw.x + pw.width)
            panelEdgeB = Math.round(pw.y + pw.height)
            panelBoundsOk = true
        }
    }
    Timer {
        id: anchorProbe
        // 300ms, not 1s: the folder icons SHIFT whenever the task manager's
        // width changes (windows opening/closing), and an open fired inside
        // the stale window recenters — and CONVERGES — on the OLD anchor
        // position (misplaced-open hypothesis H1). mapToGlobal is pure QML,
        // no engine forks, so a fast cadence is free.
        interval: 300
        repeat: true
        running: !root.expanded
        onTriggered: root.captureAnchor()
    }
    // 90ms after the last grid size change: verify the hook is alive and
    // arm the query backstop when the frame rests off-tile.
    Timer {
        id: armDebounce
        interval: 90
        repeat: false
        onTriggered: root.hookCheck()
    }
    // Event poll: one cheap grep while expanded (a few ms of engine time).
    Timer {
        id: evTimer
        interval: 120
        repeat: true
        running: root.expanded && !root.showSettings
        onTriggered: root.evPoll()
    }
    // No event verdict and the frame sits off-tile: ask KWin directly.
    Timer {
        id: backstop
        interval: 1500
        repeat: false
        onTriggered: root.backstopFire()
    }
    // Every recenter write is verified by one state query ~300ms later:
    // the write's landing spot can be re-anchored away by the shell, and
    // the payload refreshes trueX/trueY (the ONLY trusted source — the
    // applet must never assume its write stuck). If the query finds the
    // frame still off-center it writes again (bounded by recenterRounds):
    // write -> verify -> write ... until the icon-centered position is
    // confirmed — the shell re-anchors on every resize, so only the write
    // that lands LAST sticks, and only a query proves it landed.
    property bool verifyPending: false
    Timer {
        id: verifyTimer
        interval: 300
        repeat: false
        onTriggered: {
            if (!verifyPending || !root.expanded || showSettings) {
                verifyPending = false
                return
            }
            verifyPending = false
            runStateQuery()
        }
    }
    function runStateQuery() {
        querySeq++
        var n = "afqS" + instId + "-" + querySeq
        var prev = querySeq > 1 ? "afqS" + instId + "-" + (querySeq - 1) : ""
        var cmd = (prev !== ""
                ? "gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.unloadScript " + prev + " >/dev/null 2>&1; " : "")
            + "test -f \"" + artifactDir + "/afqS.js\" || exit 0; "
            + "o=$(gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.loadScript \"" + artifactDir + "/afqS.js\" " + n + " 2>/dev/null); "
            + "s=$(echo \"$o\" | grep -oE '[0-9]+' | head -1); "
            + "[ -n \"$s\" ] && gdbus call --session --dest org.kde.KWin --object-path /Scripting/Script$s --method org.kde.kwin.Script.run >/dev/null 2>&1; "
            + "gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.unloadScript " + n + " >/dev/null 2>&1 #qs" + instId + "-" + querySeq
        runCmd(cmd)
    }
    // Shared, STATIC hook script — no per-instance interpolation, so every
    // applet writes byte-identical files. Loaded once per KWin session at
    // the first folder open; dies with the compositor; hookCheck reloads.
    // The rc filter ("org.kde.plasmashell") matches plasma popup windows
    // ONLY — proven live: panels/desktop report "plasmashell" (no prefix),
    // the popup reports "org.kde.plasmashell". Foreign windows' drags
    // generate no config traffic at all.
    // MAPFIX ARM (hook-at-map design — log.md durable background §3): popup
    // windows are DESTROYED on
    // close and RECREATED on every open, so windowAdded fires for every
    // folder open carrying the CLAMPED map-time geometry. The arm asks
    // plasmashell for fresh open intents (in-process readConfig through
    // evaluateScript; the reply — print() output, NOT the completion
    // value — is delivered into the callDBus callback, S37b-proven) and
    // moves a UNIQUELY size-matching popup onto the intent position
    // before the user sees a settled frame. Pure MOVE (size preserved) —
    // but NEVER at map+0ms: a configure racing the popup's initial
    // expose/polishAndSync deadlocked plasmashell's main thread (S38 rig
    // soak, cycle 5, core dump: QSGThreadedRenderLoop::polishAndSync
    // waiting on the render thread inside the expose dispatch). The whole
    // collect+match+write round trip is DEFERRED ~80ms via a scripting
    // QTimer (new QTimer() — QTimer() throws; only works in persistently
    // loaded scripts; setTimeout does NOT exist on KWin 6.7.5), past the
    // typical first-presentation window. Diagnostics push ONLY on a real
    // move or an ambiguity (n>1): afEv is single-slot and carries release
    // detection — a per-open "nomatch/skip" push could clobber a pending
    // grab verdict.
    function ensureHookScript(force) {
        if (hookReady && force !== true)
            return
        hookReady = true
        var body = ""
            + "function push(p) {\n"
            + "    var js = \"var ps=panels();for(var i=0;i<ps.length;i++){var ws2=ps[i].widgets();for(var j=0;j<ws2.length;j++){var g=ws2[j];if(String(g.type).indexOf('appfolder')===0){g.currentConfigGroup=['General'];g.writeConfig('afEv'+g.id,'\"+p+\"')}}}\"\n"
            + "    callDBus(\"org.kde.plasmashell\", \"/PlasmaShell\", \"org.kde.PlasmaShell\", \"evaluateScript\", js)\n"
            + "}\n"
            + "var seq = 0\n"
            + "function report(w) {\n"
            + "    try {\n"
            + "        if (String(w.resourceClass) != \"org.kde.plasmashell\") return\n"
            + "        var g = w.frameGeometry\n"
            + "        seq++\n"
            + "        push(seq + \" \" + (w.resize ? 1 : 0) + (w.move ? 1 : 0) + \" \" + Math.round(g.x) + \",\" + Math.round(g.y) + \" \" + Math.round(g.width) + \"x\" + Math.round(g.height))\n"
            + "    } catch (e) {}\n"
            + "}\n"
            + "function hook(w) { w.moveResizedChanged.connect(function() { report(w) }) }\n"
            + "function mapMove(w, reply) {\n"
            + "    try {\n"
            + "        var g = w.frameGeometry\n"
            + "        var entries = String(reply).split(\";\")\n"
            + "        var n = 0\n"
            + "        var pick = null\n"
            + "        for (var i = 0; i < entries.length; i++) {\n"
            + "            var t = entries[i]\n"
            + "            if (t === \"\") continue\n"
            + "            var f = t.split(\",\")\n"
            + "            if (f.length < 5) continue\n"
            + "            var iw = parseInt(f[3])\n"
            + "            var ih = parseInt(f[4])\n"
            + "            if (iw <= 0 || ih <= 0) continue\n"
            + "            if (Math.abs(g.width - iw) > 10 || Math.abs(g.height - ih) > 10) continue\n"
            + "            n++\n"
            + "            pick = f\n"
            + "        }\n"
            + "        if (n !== 1 || pick === null) {\n"
            + "            if (n > 1) {\n"
            + "                seq++\n"
            + "                push(seq + \" mapfix amb n=\" + n)\n"
            + "            }\n"
            + "            return\n"
            + "        }\n"
            + "        var ix = parseInt(pick[1])\n"
            + "        var iy = parseInt(pick[2])\n"
            + "        var gx = Math.round(g.x)\n"
            + "        var gy = Math.round(g.y)\n"
            + "        // Move threshold 12px, gross-only: since the S40 policy the intent equals the shell's placement rule, so a popup within ~1px of the intent is ALREADY correct; a 2-12px gap means the shell placed with FRESHER geometry (anchor/panel churn between our flip-time intent and the map) — moving onto our staler intent is wrong and visible (the post-open nudge). >=12px = genuine drift or a placement bug: the net fires.\n"
            + "        var nx = (ix >= 2 && Math.abs(gx - ix) >= 12) ? ix : gx\n"
            + "        var ny = (iy >= 2 && Math.abs(gy - iy) >= 12) ? iy : gy\n"
            + "        if (nx === gx && ny === gy) return\n"
            + "        w.frameGeometry = { x: nx, y: ny, width: g.width, height: g.height }\n"
            + "        seq++\n"
            + "        push(seq + \" mapfix \" + gx + \"->\" + nx + \" y\" + gy + \"->\" + ny + \" \" + Math.round(g.width) + \"x\" + Math.round(g.height))\n"
            + "    } catch (e) {}\n"
            + "}\n"
            + "function onAdded(w) {\n"
            + "    hook(w)\n"
            + "    try {\n"
            + "        if (String(w.resourceClass) != \"org.kde.plasmashell\") return\n"
            + "        var g0 = w.frameGeometry\n"
            + "        if (g0.width < 40 || g0.height < 40) return\n"
            + "        var t = new QTimer()\n"
            + "        mapfixTimers.push(t)\n"
            + "        t.singleShot = true\n"
            + "        t.interval = 80\n"
            + "        t.timeout.connect(function() {\n"
            + "            try {\n"
            + "                var k = mapfixTimers.indexOf(t)\n"
            + "                if (k >= 0) mapfixTimers.splice(k, 1)\n"
            + "            } catch (e2) {}\n"
            + "            var js = \"var out='';var ps=panels();for(var i=0;i<ps.length;i++){var ws2=ps[i].widgets();for(var j=0;j<ws2.length;j++){var g=ws2[j];if(String(g.type).indexOf('appfolder')===0){g.currentConfigGroup=['General'];var at=parseInt(String(g.readConfig('afMapAt','0')));if(at>0&&(Date.now()-at)<2500){out+=g.id+','+parseInt(String(g.readConfig('afMapX','-1')))+','+parseInt(String(g.readConfig('afMapY','-1')))+','+parseInt(String(g.readConfig('afMapW','0')))+','+parseInt(String(g.readConfig('afMapH','0')))+';'}}}}print(out)\"\n"
            + "            callDBus(\"org.kde.plasmashell\", \"/PlasmaShell\", \"org.kde.PlasmaShell\", \"evaluateScript\", js, function(reply) { mapMove(w, reply) })\n"
            + "        })\n"
            + "        t.start()\n"
            + "    } catch (e) {}\n"
            + "}\n"
            + "var mapfixTimers = []\n"
            + "var ws = workspace.windowList()\n"
            + "for (var i = 0; i < ws.length; i++) hook(ws[i])\n"
            + "workspace.windowAdded.connect(function(w) { onAdded(w) })\n"
            + "push(\"1 00 0,0 1x1 boot3 \" + ws.length)\n"
        // UNLOAD FIRST: KWin keeps a loaded script across plasmashell
        // restarts, and loadScript under a live duplicate name fails (the
        // reply's -1 makes the id grep run a blind Script1 that fails
        // silently — S37 lesson). Unloading the previous content makes
        // every deploy self-upgrade; steady state is one unload+load per
        // applet instance per session, each healed by hookCheck if it fails.
        var hpath = artifactDir + "/afhookS.js"
        runCmd("cat > \"" + hpath + "\" <<'AFHSEOF'\n" + body + "AFHSEOF\n"
            + "gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.unloadScript afhookS >/dev/null 2>&1; "
            + "o=$(gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.loadScript \"" + hpath + "\" afhookS 2>/dev/null); "
            + "s=$(echo \"$o\" | grep -oE '[0-9]+' | head -1); "
            + "[ -n \"$s\" ] && gdbus call --session --dest org.kde.KWin --object-path /Scripting/Script$s --method org.kde.kwin.Script.run >/dev/null 2>&1 && echo hook-loaded #hs" + (traceSeq++))
    }
    // One-shot state query (backstop): snapshots EVERY window's interactive
    // resize state (no class filter — the plasmawindowed harness host and
    // 0,0-reporting popups must match too) and pushes it through the same
    // afEv channel. Date.now() makes each payload unique, or writeConfig
    // would no-op on an unchanged value and the grep would never see it.
    function ensureQueryScript() {
        var body = ""
            + "var out = \"\"\n"
            + "var ws = workspace.windowList()\n"
            + "for (var i = 0; i < ws.length; i++) {\n"
            + "    try {\n"
            + "        var w = ws[i]\n"
            + "        var g = w.frameGeometry\n"
            + "        if (out !== \"\") out += \"|\"\n"
            + "        out += (w.resize ? \"1\" : \"0\") + (w.move ? \"1\" : \"0\") + \" \" + Math.round(g.x) + \",\" + Math.round(g.y) + \" \" + Math.round(g.width) + \"x\" + Math.round(g.height)\n"
            + "    } catch (e) {}\n"
            + "}\n"
            + "var js = \"var ps=panels();for(var i=0;i<ps.length;i++){var ws2=ps[i].widgets();for(var j=0;j<ws2.length;j++){var g=ws2[j];if(String(g.type).indexOf('appfolder')===0){g.currentConfigGroup=['General'];g.writeConfig('afEv'+g.id,'\"+(Date.now())+\" q \"+out+\"')}}}\"\n"
            + "callDBus(\"org.kde.plasmashell\", \"/PlasmaShell\", \"org.kde.PlasmaShell\", \"evaluateScript\", js)\n"
        runCmd("cat > \"" + artifactDir + "/afqS.js\" <<'AFQSEOF'\n" + body + "AFQSEOF\n#qs" + (traceSeq++))
    }
    function hookCheck() {
        if (!root.expanded || showSettings)
            return
        // Off-tile at rest: the release we are still waiting for may need
        // the backstop (dead hook, harness host).
        var rep = fullRepresentationItem
        if (rep && rep.gridView && tile > 0
            && (Math.abs(rep.gridView.width - snappedW) > 1
                || Math.abs(rep.gridView.height - snappedH) > 1)) {
            if (backstopTries < 20)
                backstop.restart()
        }
        if (Date.now() - lastHookCheckAt < 3000)
            return
        lastHookCheckAt = Date.now()
        runCmd("gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.isScriptLoaded afhookS 2>/dev/null; test -f \"" + artifactDir + "/afhookS.js\" && echo HOK; test -f \"" + artifactDir + "/afqS.js\" && echo QOK #hc" + (traceSeq++), (out, code) => {
            var o = String(out || "")
            if (o.indexOf("true") < 0) {
                trace("hook-dead, reloading")
                ensureHookScript(true)
            }
            if (o.indexOf("QOK") < 0)
                ensureQueryScript()
        })
    }
    function evPoll() {
        // Unique source name per poll (the engine keys by command string):
        // identical concurrent commands would stack callbacks.
        runCmd("sed -n \"s/^afEv" + instId + "=//p\" $HOME/.config/plasma-org.kde.plasma.desktop-appletsrc | tail -1 #ev" + (traceSeq++), (out, code) => {
            var v = String(out).trim()
            if (v === "" || v === lastEv)
                return
            lastEv = v
            handleKwinPayload(v)
        })
    }
    function handleKwinPayload(v) {
        if (!root.expanded || showSettings)
            return
        var parts = v.split(" ")
        if (parts.length < 4)
            return
        // Query payloads carry their build time (ms epoch): a stale disk
        // value from a previous session must never act as a verdict.
        var when = parseInt(parts[0])
        if (when > 1000000000000 && Date.now() - when > 15000) {
            trace("kwin-event stale, dropped")
            return
        }
        trace("kwin-event " + v)
        var rep = fullRepresentationItem
        var win = (rep && rep.Window) ? rep.Window.window : null
        if (!win)
            return
        // Query snapshots carry "<when> q <entry>|<entry>..." — the window
        // list carries its own per-entry flags.
        if (parts[1] === "q") {
            handleQueryList(parts.slice(2).join(" "), win)
            return
        }
        var flags = parts[1]
        var resizeHeld = flags.charAt(0) === "1"
        var isMove = flags.length > 1 && flags.charAt(1) === "1"
        if (isMove)
            return
        if (!payloadMatchesWindow(parts[2], parts[3], win))
            return
        var pp = /^(-?\d+),(-?\d+)$/.exec(parts[2])
        if (pp) {
            trueX = parseInt(pp[1])
            trueY = parseInt(pp[2])
        }
        if (resizeHeld) {
            grabSeen = true
            grabCancel()
            trace("grab-start event")
            return
        }
        // Release verdict. A trusted start/end pair skips the evidence
        // gates; an orphan end (hook armed mid-gesture) still needs them —
        // a mid-drag false release is what used to teleport the frame.
        var now = Date.now()
        if (!grabSeen && now - lastHeldAt < 150) {
            trace("release event suppressed")
            return
        }
        if (grabSeen)
            lastHeldAt = 0
        grabSeen = false
        handleRelease()
    }
    function payloadMatchesWindow(posStr, sizeStr, win) {
        var p = /^(-?\d+),(-?\d+)$/.exec(posStr)
        var s = /^(\d+)x(\d+)$/.exec(sizeStr)
        if (!p || !s)
            return false
        var pw = parseInt(s[1])
        var ph = parseInt(s[2])
        var dw = Math.abs(pw - Math.round(win.width))
        var dh = Math.abs(ph - Math.round(win.height))
        var sizeOk = (dw <= 8 && dh <= 8)
        if (!sizeOk) {
            // During our own glide the live size sits between the release
            // size and the target; match the whole span so mid-glide orphan
            // verdicts still bind (the stepper is monotonic).
            var tgtW = snappedW + shrinkChromeW
            var tgtH = snappedH + shrinkChromeH
            var wLo = Math.min(Math.round(win.width), Math.round(tgtW)) - 8
            var wHi = Math.max(Math.round(win.width), Math.round(tgtW)) + 8
            var hLo = Math.min(Math.round(win.height), Math.round(tgtH)) - 8
            var hHi = Math.max(Math.round(win.height), Math.round(tgtH)) + 8
            if (pw < wLo || pw > wHi || ph < hLo || ph > hHi)
                return false
        }
        // Position: truth to truth, loosely — the hook's rc filter has
        // already narrowed the field to plasma popups, and the truth seed
        // can lag a shell re-anchor mid-resize (observed 28px after one
        // forced resize). A stale seed must never reject a real grab.
        // (Sibling folder popups with identical tile sizes sit >80px apart
        // unless two are pinned open side by side — a false claim there
        // only snaps an on-tile frame back to place.)
        if (trueX >= 0 || trueY >= 0)
            return Math.abs(parseInt(p[1]) - trueX) <= 80
                && Math.abs(parseInt(p[2]) - trueY) <= 80
        return true
    }
    function handleRelease() {
        trace("release event")
        if (enforcingW || enforcingH || shrinkWActive || shrinkHActive) {
            // Motion still owns the window: snap the moment it ends.
            releaseSeen = true
            return
        }
        if (sizePinned) {
            releaseSeen = true
            return
        }
        snapFrame(true)
        // Silent release (frame already on-tile): no snap fires, so
        // recenter here — a left-drag that landed exactly on a tile still
        // leaves the frame displaced from its anchor.
        if (!enforcingW && !enforcingH)
            recenterIfNeeded(true)
    }
    function handleQueryList(list, win) {
        var entries = list.split("|")
        var strictHeld = false
        var strictReleased = false
        var looseSizes = 0
        var looseHeld = false
        var matchedPos = null
        var loosePos = null
        for (var i = 0; i < entries.length; i++) {
            var m = /^([01])([01]) (-?\d+),(-?\d+) (\d+)x(\d+)$/.exec(entries[i].trim())
            if (!m)
                continue
            var dw = Math.abs(parseInt(m[5]) - Math.round(win.width))
            var dh = Math.abs(parseInt(m[6]) - Math.round(win.height))
            if (dw > 8 || dh > 8)
                continue
            // Position: KWin-truth to KWin-truth when we have it; the
            // stale QML win.x must never gate this (moves freeze it).
            var strict = (trueX >= 0 || trueY >= 0)
                ? Math.abs(parseInt(m[3]) - trueX) <= 24
                    && Math.abs(parseInt(m[4]) - trueY) <= 24
                : true
            if (m[1] === "1") {
                strictHeld = strictHeld || strict
                looseHeld = true
            } else if (strict) {
                strictReleased = true
                matchedPos = m
            } else {
                looseSizes++
                loosePos = m
            }
        }
        var released = strictReleased || (!strictHeld && !looseHeld && looseSizes === 1)
        // Truth refresh from whichever entry identifies us: a strict hit,
        // or the UNIQUE size match (the seed goes stale the moment the
        // shell re-anchors the popup during a resize — rejecting the fresh
        // position kept the seed stale forever).
        var winner = matchedPos !== null ? matchedPos : (looseSizes === 1 && !looseHeld && !strictHeld ? loosePos : null)
        if (winner) {
            trueX = parseInt(winner[3])
            trueY = parseInt(winner[4])
        }
        trace("query verdict rel=" + released + " loose=" + looseSizes
            + " strictR=" + strictReleased + " truth=" + Math.round(trueX) + "," + Math.round(trueY))
        if (released) {
            var now = Date.now()
            // A "released" verdict with no gesture evidence and an on-tile
            // frame is the OPEN path talking: nothing is being resized, so
            // every state query ever fired says released — acting on it fed
            // a snap + recenter churn about a second after every open. Only
            // a seen grab, a deferred release, or an actually off-tile
            // frame makes the verdict actionable.
            var repq = fullRepresentationItem
            var offTile = repq && repq.gridView && tile > 0
                && (Math.abs(repq.gridView.width - snappedW) > 1
                    || Math.abs(repq.gridView.height - snappedH) > 1)
            if ((grabSeen || releaseSeen || offTile) && now - lastHeldAt >= 150)
                handleRelease()
            else
                trace("query release suppressed")
            // Query-driven position self-correction: the shell re-derives
            // the popup x on its own resizes; KWin truth now on record.
            // Re-capture the anchor FIRST so desired uses CURRENT panel
            // bounds — the query lands >=300ms after the flip, and anchor
            // or panel-edge churn in that window would otherwise make a
            // correct fresh placement look off-target and trigger a
            // write. With fresh bounds only GROSS misplacement (>8px)
            // corrects; the confirmation resets the loop budget.
            if (!grabSeen && !enforcingW && !enforcingH && !shrinkWActive && !shrinkHActive
                && trueX >= 0 && anchorCx > 0) {
                root.captureAnchor()
                var desiredX = recenterDesiredX()
                if (desiredX >= 0 && Math.abs(trueX - desiredX) > 8)
                    recenterIfNeeded(true)
                else if (desiredX >= 0)
                    recenterRounds = 0
            }
        } else if (strictHeld || looseHeld) {
            lastHeldAt = Date.now()
            // The query had to do the hook's job: the hook is probably
            // dead — re-verify so the NEXT gesture is event-covered.
            lastHookCheckAt = 0
            hookCheck()
        }
    }
    // Backstop: quiesced, off-tile, and the hook gave no verdict (dead
    // after a compositor restart, or a harness host the hook filters out).
    // One state query through the same channel; repeat while it stays
    // unresolved, bounded so a wedged frame can never churn the engine.
    function backstopFire() {
        if (!root.expanded || showSettings) {
            backstopTries = 0
            return
        }
        var rep = fullRepresentationItem
        if (!rep || !rep.gridView) {
            backstopTries = 0
            return
        }
        var onTile = Math.abs(rep.gridView.width - snappedW) <= 1
            && Math.abs(rep.gridView.height - snappedH) <= 1
        if (onTile) {
            backstopTries = 0
            return
        }
        if (enforcingW || enforcingH || shrinkWActive || shrinkHActive || sizePinned) {
            // Motion owns the window; re-check when it settles.
            backstopTries = 0
            backstop.restart()
            return
        }
        backstopTries++
        trace("backstop query x" + backstopTries)
        runStateQuery()
        if (backstopTries < 20)
            backstop.restart()
        else
            backstopTries = 0
    }
    // Restore the popup over its panel-icon anchor after a release: size
    // snaps alone never move x (top-left-anchored resizes), so a left-side
    // drag leaves the frame drifted. Fires a one-shot KWin script that
    // matches our window by client geometry and sets its frame x to the
    // anchor-centered position. No-op when already centered.
    // Rate-limited (unless force): convergence retries re-enter snapFrame
    // and must not spam the recenter script. The shell RE-DERIVES the
    // popup x whenever it resizes the window itself (proven: a forced
    // resize moved x to the anchor-derived spot), so this also runs on
    // snap ARRIVAL and from the x-drift monitor.
    property double lastRecenterAt: 0
    // Budget for the write->verify->write convergence loop (each script
    // write is ~5 engine forks, so the loop must be bounded; reset at
    // open, at grab start, and whenever a query confirms centered).
    property int recenterRounds: 0
    // True once ANY KWin-side geometry write (recenter or border-arm) has
    // touched THIS open's popup. Reset at every expand — see borderArmWrite.
    property bool kwinWriteThisOpen: false
    // Frame origin that centers a grid+chrome span over an anchor, clamped
    // to the caller-supplied bounds on both edges. Since S40 the bounds
    // are the PANEL extent (standard Plasma clamping — see the policy note
    // by panelBoundsOk); the screen bounds remain only as a fallback.
    // Clamp with the LARGEST span the frame will have (glide target), so
    // the final position is inside the bounds too. Pure math — shared by
    // recenterDesiredX (post-map correction) and the map intent (pre-map
    // publish), byte-identical to the original inline formula.
    function clampCentered(aC, gridW, chromeW, curW, edgeL, edgeR) {
        var v = Math.round(aC - gridW / 2 - chromeW / 2)
        var tgt = Math.round(gridW + chromeW)
        if (edgeR > edgeL)
            v = Math.max(edgeL, Math.min(v, Math.round(edgeR - Math.max(curW, tgt))))
        return v
    }
    // Target origin along the panel's clamp axis per the S40 policy:
    // center on the anchor, clamped so the popup NEVER overhangs the
    // panel's extent (dialog margin padded in), panel-centered when the
    // popup is wider than the panel — the shell's own wider-than-parent
    // rule. horizontal=true clamps x (top/bottom panel), false clamps y
    // (left/right panel). Returns -1 when the panel bounds are unknown.
    function placeClamped(aC, gridW, chromeW, curW, horizontal) {
        if (!panelBoundsOk)
            return -1
        var lo = horizontal ? panelEdgeL : panelEdgeT
        var hi = horizontal ? panelEdgeR : panelEdgeB
        if (hi <= lo)
            return -1
        var span = Math.round(gridW + chromeW)
        if (span >= hi - lo - 2 * panelPlaceMargin)
            return lo + Math.round((hi - lo - span) / 2)
        return clampCentered(aC, gridW, chromeW, curW,
            lo + panelPlaceMargin, hi - panelPlaceMargin)
    }
    function recenterDesiredX() {
        var rep = fullRepresentationItem
        var win = (rep && rep.Window) ? rep.Window.window : null
        if (!win || !rep.gridView)
            return -1
        // Vertical panels clamp on Y, not X: an x "recenter" would drag
        // the popup against the shell's free-x placement. The map intent
        // carries the y correction instead (see publishMapIntent).
        var ff = -1
        try { ff = plasmoid.formFactor } catch (e) { ff = -1 }
        if (ff === undefined || ff === null)
            ff = -1
        if (ff === PlasmaCore.Types.Vertical)
            return -1
        var chromeW = win.width - rep.gridView.width
        var px = placeClamped(anchorCx, snappedW, chromeW, win.width, true)
        if (px >= 0)
            return px
        // No panel bounds (rare): fall back to the old screen clamp so
        // centering still converges for this open.
        var edgeL = 0
        var edgeR = -1
        var sc = win.screen
        if (sc && sc.width > 0) {
            edgeL = sc.virtualX
            edgeR = sc.virtualX + sc.width
        } else if (rep.screenEdgeR > rep.screenEdgeL) {
            edgeL = rep.screenEdgeL
            edgeR = rep.screenEdgeR
        }
        return clampCentered(anchorCx, snappedW, chromeW, win.width, edgeL, edgeR)
    }
    // -- hook-at-map open intent (the M1 fix; design in log.md §3) --------
    // The shell clamps popup placement to the ANCHOR WINDOW's horizontal
    // extent (a floating, content-hugging panel means the rightmost folder
    // maps with its right edge pinned at panel-right), and no applet
    // channel can position a popup before map — KWin cannot see unmapped
    // windows. But popups are RECREATED on every open, so KWin's
    // workspace.windowAdded fires with the clamped map-time geometry, and
    // the shared hook can MOVE the window onto the intended spot (a pure
    // move — distinct from the S30 resize-near-map crash class) before the
    // first presented frame, if it knows the target in advance. That is
    // this intent: published at the expand flip (window exists with its
    // final size, still UNPLACED — latency is free here), read LIVE by the
    // hook through evaluateScript/readConfig (same plasmashell process,
    // zero forks). The hook's 2.5s age gate expires stale intents (anchor
    // churn makes older ones wrong); collapse clears afMapAt as
    // belt-and-braces.
    function publishMapIntent() {
        var rep = fullRepresentationItem
        var win = (rep && rep.Window) ? rep.Window.window : null
        if (!win || !rep.gridView || win.width < 10)
            return
        // Chrome estimate = the S31 chain: live (window minus the
        // surviving grid) > frozen shrinkChrome > persisted config. After
        // the pre-map tile-exact write above, the window already wears
        // snappedW/H + it.
        var chW = 0
        var chH = 0
        var liveW = Math.round(win.width - rep.gridView.width)
        var liveH = Math.round(win.height - rep.gridView.height)
        if (liveW > 0 && liveW < tile)
            chW = liveW
        if (liveH > 0 && liveH < tile)
            chH = liveH
        if (chW === 0 && shrinkChromeW > 0 && shrinkChromeW < tile)
            chW = shrinkChromeW
        if (chH === 0 && shrinkChromeH > 0 && shrinkChromeH < tile)
            chH = shrinkChromeH
        if (chW === 0 && plasmoid.configuration.chromeW > 0
            && plasmoid.configuration.chromeW < tile)
            chW = plasmoid.configuration.chromeW
        if (chH === 0 && plasmoid.configuration.chromeH > 0
            && plasmoid.configuration.chromeH < tile)
            chH = plasmoid.configuration.chromeH
        if (chW <= 0 || chH <= 0 || anchorCx <= 0)
            return
        // Screen bounds from the PANEL's screen (captured with the anchor)
        // — only the FALLBACK when the panel window bounds are unknown;
        // the policy clamp below uses the panel extent itself.
        var edgeL = scrEdgeL
        var edgeR = scrEdgeR
        var edgeT = scrEdgeT
        var edgeB = scrEdgeB
        var sc = win.screen
        if (edgeR <= edgeL && sc && sc.width > 0) {
            edgeL = sc.virtualX
            edgeR = sc.virtualX + sc.width
            edgeT = sc.virtualY
            edgeB = sc.virtualY + sc.height
        }
        if (edgeR <= edgeL || edgeB <= edgeT)
            return
        // The clamp axis follows the panel: transientplacementhint clamps
        // popups to the anchor window along the panel's SHORT axis — x for
        // horizontal panels, y for vertical ones. An unreadable formFactor
        // publishes NOTHING (fail safe: a wrong-axis write would drag a
        // vertical-panel popup onto the panel). The intent is the S40
        // POLICY target (panel-clamped == what the shell will place), so
        // the hook's mapfix self-suppresses on normal opens and only
        // nudges when the shell's placement drifted from the predicted
        // spot (anchor churn between flip and map).
        var ff = -1
        try { ff = plasmoid.formFactor } catch (e) { ff = -1 }
        if (ff === undefined || ff === null)
            ff = -1
        var mx = -1
        var my = -1
        if (ff === PlasmaCore.Types.Vertical) {
            if (anchorCy > 0)
                my = placeClamped(anchorCy, snappedH, chH, win.height, false)
        } else if (ff >= 0) {
            mx = placeClamped(anchorCx, snappedW, chW, win.width, true)
        }
        if (mx < 0 && my < 0) {
            // Panel bounds unknown: publish the old screen-clamped target
            // so the hook still aligns gross mismatches (S38 behavior).
            if (ff === PlasmaCore.Types.Vertical) {
                if (anchorCy > 0)
                    my = clampCentered(anchorCy, snappedH, chH, win.height, edgeT, edgeB)
            } else if (ff >= 0 && anchorCx > 0) {
                mx = clampCentered(anchorCx, snappedW, chW, win.width, edgeL, edgeR)
            }
        }
        if (mx < 0 && my < 0)
            return
        // afMapAt as a STRING: epoch ms overflows KConfig Int. The hook
        // parseInts it and applies the 2.5s freshness gate.
        plasmoid.configuration.afMapX = mx
        plasmoid.configuration.afMapY = my
        plasmoid.configuration.afMapW = Math.round(snappedW + chW)
        plasmoid.configuration.afMapH = Math.round(snappedH + chH)
        plasmoid.configuration.afMapAt = String(Date.now())
        flushConfig()
        trace("map-intent x=" + mx + " y=" + my + " span="
            + Math.round(snappedW + chW) + "x" + Math.round(snappedH + chH)
            + " anch=" + Math.round(anchorCx) + "," + Math.round(anchorCy))
    }
    function recenterIfNeeded(force) {
        if (anchorCx <= 0)
            return
        // Never write after a collapse: the query verdicts can arrive just
        // as the popup dies, and a geometry write to a closing window is a
        // wasted script at best (trace S32: wrote 760 onto a dying popup).
        if (!root.expanded)
            return
        if (force !== true && Date.now() - lastRecenterAt < 400)
            return
        // Never move the frame while a grab may be live: this KWin write is
        // the teleport writer — a false release mid-drag moved the popup
        // +300px in one frame (video 21.5s). Button evidence within the
        // last 250ms means a hold; KWin writes then fight the cursor.
        // (A TRUSTED release event clears lastHeldAt before calling in.)
        if (Date.now() - lastHeldAt < 250)
            return
        var rep = fullRepresentationItem
        var win = (rep && rep.Window) ? rep.Window.window : null
        if (!win || !rep.gridView)
            return
        trace("renc enter tx=" + Math.round(trueX) + " wx=" + Math.round(win.x)
            + " anch=" + Math.round(anchorCx))
        // Truth comes ONLY from the placement-moment seed, query verdicts
        // and grab events — NEVER from win.x here. Between maps QML x is
        // frozen at the LAST open's placement (stale by exactly the anchor
        // churn since then): seeding from it fired writes against problems
        // that no longer existed, moving correctly-placed popups (the
        // post-open nudge, S42 rig-proven).
        if (trueX < 0)
            return
        var desiredX = recenterDesiredX()
        if (desiredX < 0)
            return
        if (Math.abs(trueX - desiredX) <= 4) {
            // Already icon-centered: fresh budget for the next correction.
            recenterRounds = 0
            return
        }
        // Bounded convergence: this write will be verified ~300ms later by
        // one state query which re-fires this if the shell re-anchored it
        // away. The cap stops a fight between two position writers from
        // churning the engine forever.
        if (recenterRounds >= 8)
            return
        recenterRounds++
        fireRecenterScript(desiredX, "rc")
        lastRecenterAt = Date.now()
        // Never assume the write stuck: verify it with one state query
        // (refreshes truth + re-centers if the shell re-anchored it away).
        verifyPending = true
        verifyTimer.restart()
        trace("recenter wrote " + desiredX)
    }
    // The KWin geometry write shared by recenterIfNeeded and borderArmWrite:
    // a one-shot script that matches this popup (size span + position, see
    // the matcher comments in recenterIfNeeded) and sets its frame x to
    // targetX. Runs through the executable engine like every other KWin
    // interaction — the fork/DBus latency keeps it >=300ms away from the
    // map moment (the crash floor), never a direct timing race.
    function fireRecenterScript(targetX, tag) {
        var rep = fullRepresentationItem
        var win = (rep && rep.Window) ? rep.Window.window : null
        if (!win || !rep.gridView)
            return
        // Match the KWin window across the WHOLE glide span, not the size
        // frozen at build time: this script executes ~100-200ms after the
        // snap started, mid-glide, with the window already somewhere between
        // the release size and the target — the old exact ±6 match missed
        // and the recenter silently no-oped. The stepper is monotonic, so
        // every in-flight size lies inside [from, target]. Position still
        // tightens the match only when QML reports real coordinates (panel
        // popups do; plasmawindowed hosts report 0,0).
        var chromeW = win.width - rep.gridView.width
        var chromeH = win.height - rep.gridView.height
        var tgtW = Math.round(snappedW + chromeW)
        var tgtH = Math.round(snappedH + chromeH)
        var wLo = Math.round(Math.min(win.width, tgtW)) - 6
        var wHi = Math.round(Math.max(win.width, tgtW)) + 6
        var hLo = Math.round(Math.min(win.height, tgtH)) - 6
        var hHi = Math.round(Math.max(win.height, tgtH)) + 6
        var posOk = trueX >= 0 && trueY >= 0
        // The shell re-anchors the popup x on EVERY client resize (each
        // stepper write), so the build-time truth position may be stale by
        // the time this script runs. Match by position ±80 when possible;
        // otherwise a UNIQUE plasma-popup size match wins on its own.
        var body = ""
            + "var ws = workspace.windowList()\n"
            + "var best = null\n"
            + "var n = 0\n"
            + "for (var i = 0; i < ws.length; i++) {\n"
            + "    var w = ws[i]\n"
            + "    if (w.resourceClass != \"org.kde.plasmashell\") continue\n"
            + "    var g = w.clientGeometry\n"
            + "    if (g.width >= " + wLo + " && g.width <= " + wHi
            + " && g.height >= " + hLo + " && g.height <= " + hHi + ") {\n"
            + "        n++\n"
            + (posOk
                ? "        if (Math.abs(g.x - " + Math.round(trueX) + ") <= 80) best = w\n"
                : "        best = w\n")
            + "    }\n"
            + "}\n"
            + "if (best === null && n === 1) {\n"
            + "    for (var j = 0; j < ws.length; j++) {\n"
            + "        var w2 = ws[j]\n"
            + "        if (w2.resourceClass != \"org.kde.plasmashell\") continue\n"
            + "        var g2 = w2.clientGeometry\n"
            + "        if (g2.width >= " + wLo + " && g2.width <= " + wHi
            + " && g2.height >= " + hLo + " && g2.height <= " + hHi + ") { best = w2; break }\n"
            + "    }\n"
            + "}\n"
            + "if (best !== null) {\n"
            + "    var fg = best.frameGeometry\n"
            + "    best.frameGeometry = { x: " + targetX + ", y: fg.y, width: fg.width, height: fg.height }\n"
            + "}\n"
        var n = "af" + tag + instId + "-" + (traceSeq++)
        var rpath = artifactDir + "/" + n + ".js"
        runCmd("cat > \"" + rpath + "\" <<'AFREOF'\n" + body + "AFREOF\n"
            + "o=$(gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.loadScript \"" + rpath + "\" " + n + " 2>/dev/null); "
            + "s=$(echo \"$o\" | grep -oE '[0-9]+' | head -1); "
            + "[ -n \"$s\" ] && gdbus call --session --dest org.kde.KWin --object-path /Scripting/Script$s --method org.kde.kwin.Script.run >/dev/null 2>&1; "
            + "gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.unloadScript " + n + " >/dev/null 2>&1; "
            + "rm -f \"" + rpath + "\" #" + tag + n)
        kwinWriteThisOpen = true
    }
    // BORDER ZONES (S32c correlation, n=6 over two sessions): border-drag
    // resize was live ONLY on popups our KWin script had MOVED that session
    // and dead on shell-placed-only ones — cursor shows the resize shape
    // (libplasma WindowResizeHandler gates hover and press identically) but
    // the click does nothing: startSystemResize fails at the platform level
    // and its failure is swallowed. A scripted KWin geometry change is the
    // only observed state that re-arms the zones. So: EVERY open performs
    // exactly ONE real KWin frameGeometry write — the recenter when the
    // popup opens off-center (clamped), and this arm write when it opens
    // already centered (where recenterIfNeeded's <=4px early-return used to
    // skip the write entirely). A same-x write could be deduped into a
    // no-op by KWin's property setter, so the arm write always carries a
    // REAL delta: the corrective desiredX when 1..4px off, else a 1px nudge
    // (imperceptible, and every placement is re-derived from the anchor on
    // the next open, so nothing accumulates). Verify like a recenter: the
    // query confirms the position and keeps truth fresh for later verdicts.
    function borderArmWrite() {
        // Pointless with dynamic resizing off (border grabs are not a
        // wanted size channel); the recenter path still writes when needed.
        if (!dynamicResize || kwinWriteThisOpen || anchorCx <= 0 || !root.expanded || showSettings)
            return
        // Never write while a grab may be live (same rule as recenter).
        if (Date.now() - lastHeldAt < 250)
            return
        var rep = fullRepresentationItem
        var win = (rep && rep.Window) ? rep.Window.window : null
        if (!win || !rep.gridView || win.width < 10)
            return
        // No stale-seed fallback: without established truth (placement
        // seed or a query verdict) there is nothing real to nudge from —
        // an equal-x reopen with no placement event simply skips the arm
        // write this open (border grabs are opportunistic anyway).
        if (trueX < 0)
            return
        var desiredX = recenterDesiredX()
        var ax
        if (desiredX < 0) {
            // Vertical panels (no x policy): the arm nudge must still fire
            // — the real-delta KWin write is the border-zone re-armer.
            ax = Math.round(trueX) + 1
        } else {
            ax = Math.abs(Math.round(trueX) - desiredX) >= 1
                ? desiredX : Math.round(trueX) + 1
        }
        fireRecenterScript(ax, "ba")
        lastRecenterAt = Date.now()
        verifyPending = true
        verifyTimer.restart()
        trace("border-arm wrote " + ax + " (tx=" + Math.round(trueX)
            + " anch=" + Math.round(anchorCx) + ")")
    }
    // -- shell slide animation: BOTH WAYS, by design (S56f) ---------------
    // The popup open/close slide is KWin's "Sliding Popups" (PopupPlasma-
    // Window::updateSlideEffect): armed once (animated=true at the expand
    // flip, pre-map, where the write's queued reposition is free; on a
    // fresh window the default is already true, so no write fires at all).
    // USER-DIRECTED 09-26: slide-IN on open and slide-OUT on close (both
    // the icon re-click and the click-away) is the wanted behavior.
    // The S56c/d disarm experiment (one animated=false at map+500ms to
    // make closes instant) is REMOVED: the write lands and reads back,
    // but the user's real-panel observation proved closes still slide —
    // KWin's close behavior rides the MAP-LATCHED slide data and a
    // post-map animated write does not change it. Per-trigger close
    // styling (slide on icon re-click, fade/instant on click-away) is
    // unreachable with the stock effect: the shell unmaps synchronously
    // on focus loss with no applet-side pre-close hook, and the latch is
    // per-window, not per-close. Known tradeoff shipped deliberately:
    // on auto-hide/dodge panels a click-away slide-out dives toward the
    // panel's old border while the panel itself is leaving (the S31
    // "ghost line") — accepted by the user with the slide restored.
    // setAnimated ALWAYS queues a position update: value-change writes
    // only — with no disarm, that is at most ONE write per window
    // lifetime (the re-arm after a host that left it false).
    property bool slideSupported: false
    property bool slideEffectOn: true
    readonly property bool slideArmed: slideSupported && slideEffectOn
    function applyShellSlide() {
        var rep = fullRepresentationItem
        var win = (rep && rep.Window) ? rep.Window.window : null
        if (!win)
            return
        var ok = false
        try {
            if (win.animated !== undefined) {
                if (win.animated !== true)
                    win.animated = true
                ok = (win.animated === true)
            }
        } catch (e) {}
        slideSupported = ok
        trace("slide arm rc=" + (ok ? "ok" : "unsupported"))
    }
    // kwinrc [Plugins] slidingpopupsEnabled false = the effect is off
    // system-wide: arming animates nothing and the popup would open bare
    // (muted content, no motion). Detect that and route opens to the
    // rise+fade fallback instead.
    function refreshPanelMode() {
        runCmd("echo \"eff=$(awk '/^\\[Plugins\\]/{p=1;next} /^\\[/{p=0}"
            + " p&&/^slidingpopupsEnabled=/{sub(/^[^=]*=/,\"\");print;exit}'"
            + " $HOME/.config/kwinrc)\" #pm" + (traceSeq++), (out, code) => {
            var m = /eff=(\S*)/.exec(String(out || ""))
            if (!m)
                return
            var eff = m[1] !== "false"
            if (eff !== slideEffectOn) {
                slideEffectOn = eff
                trace("slide eff " + eff)
            }
        })
    }

    // Shrink stepper: animates a snap axis by writing the window size
    // directly each tick (the only reliable channel for making an
    // over-large Wayland window smaller; Layout.maximum* is inert because
    // xdg_toplevel carries min_size only). Same OutCubic curve and tick
    // as the grow glide so both halves of a snap read as one motion.
    // A new grab (grabCancel) or a fresh snapFrame target cancels it.
    property bool shrinkWActive: false
    property real shrinkFromW: 0
    property real shrinkToW: 0
    property real shrinkStartW: 0
    property bool shrinkHActive: false
    property real shrinkFromH: 0
    property real shrinkToH: 0
    property real shrinkStartH: 0
    // Grid->window chrome frozen once per snap (snapFrame). Measured
    // per tick it read a lagging grid on the panel and grew each step —
    // the +1-icon runaway.
    property real shrinkChromeW: 0
    property real shrinkChromeH: 0
    Timer {
        id: shrinkWTick
        interval: 16
        repeat: true
        triggeredOnStart: true
        onTriggered: root.shrinkStep("w")
    }
    Timer {
        id: shrinkHTick
        interval: 16
        repeat: true
        triggeredOnStart: true
        onTriggered: root.shrinkStep("h")
    }
    // A grab-START event: the user owns the window now. Stop every writer
    // instantly (the old design needed button-state heuristics for this —
    // the compositor event is authoritative) and lift transition pins so
    // the drag starts from the live size. NO mute: the release event that
    // ends this grab must fire straight through.
    function grabCancel() {
        shrinkStop("w")
        shrinkStop("h")
        glideCurW = snappedW
        glideCurH = snappedH
        shrinkChromeW = 0
        shrinkChromeH = 0
        enforcingW = false
        enforcingH = false
        snapClear.stop()
        releaseSeen = false
        recenterRounds = 0
        backstop.stop()
        backstopTries = 0
        // Keep the lock when dynamic resizing is off (S57): the grab
        // must not free the min==max clamp — an off-mode frame never
        // follows a border drag.
        if (dynamicResize)
            sizePinned = false
        lastHeldAt = Date.now()
        wantExact = false
        // Truth dies with the grab: during the drag the shell re-anchors x
        // to its task-manager clamp on every configure, and the KWin grab-
        // transition payloads carry the PRE-re-anchor position (S34 trace)
        // — any truth we hold is stale or about to be poisoned by the
        // release payload's seed. The arrival query (rszLog) re-seeds
        // truth from the real geometry.
        trueX = -1
        trueY = -1
        snapPause.restart()
        trace("grab-cancel")
    }
    function shrinkEase(t) {
        // OutCubic: fast start, gentle landing.
        return 1 - Math.pow(1 - t, 3)
    }
    function shrinkStep(axis) {
        var active = axis === "w" ? shrinkWActive : shrinkHActive
        if (!active)
            return
        var dur = 170
        var now = Date.now()
        var from = axis === "w" ? shrinkFromW : shrinkFromH
        var to = axis === "w" ? shrinkToW : shrinkToH
        var t0 = axis === "w" ? shrinkStartW : shrinkStartH
        var t = Math.min(1, (now - t0) / dur)
        var v = from + (to - from) * shrinkEase(t)
        if (axis === "w")
            glideCurW = v
        else
            glideCurH = v
        applyShrinkGeometry(t >= 1)
        if (t >= 1) {
            if (axis === "w") {
                shrinkWActive = false
                shrinkWTick.stop()
            } else {
                shrinkHActive = false
                shrinkHTick.stop()
            }
            trace("shrink-" + axis + "-done " + Math.round(to))
        }
    }
    function shrinkStop(axis) {
        if (axis === "w") {
            if (shrinkWActive)
                trace("shrink-w-cancel")
            shrinkWActive = false
            shrinkWTick.stop()
        } else if (shrinkHActive) {
            trace("shrink-h-cancel")
            shrinkHActive = false
            shrinkHTick.stop()
        }
    }
    // Direct window writes for the shrink axes: QWindow::resize clamps to
    // the Layout min/max the same way the shell's own open-restore does
    // (proven: saved-size restore shrinks popups), so one channel covers
    // both directions with zero scripts, zero engine load, zero late-writes.
    // The old script-per-tick stepper queued gdbus chains that landed
    // seconds late and reshaped the window after the glide finished —
    // the "resize storm" (window collapsing to 4x1 mid-snap).
    property double lastShrinkTrace: 0
    function applyShrinkGeometry(final) {
        var rep = fullRepresentationItem
        var win = (rep && rep.Window) ? rep.Window.window : null
        if (!win || !rep.gridView)
            return
        var axisW = shrinkWActive
        var axisH = shrinkHActive
        if (!axisW && !axisH)
            return
        // Pure absolute math on the axis the stepper OWNS, through the
        // chrome frozen at snap start. No per-tick chrome measurement
        // (the panel grid lags the window a layout pass — re-measuring
        // compounded the step delta and overshot every write: the +1-icon
        // runaway). The other axis keeps the LIVE window value: a
        // simultaneous sibling step lands through its own tick, and a
        // stale copy here is what used to restore a mid-flight resize.
        var wW = axisW ? Math.max(1, Math.round(glideCurW + shrinkChromeW))
                      : Math.round(win.width)
        var wH = axisH ? Math.max(1, Math.round(glideCurH + shrinkChromeH))
                      : Math.round(win.height)
        if (Math.round(win.width) === wW && Math.round(win.height) === wH)
            return
        if (Date.now() - lastShrinkTrace > 400) {
            lastShrinkTrace = Date.now()
            trace("shrinkwrite " + Math.round(win.width) + "x" + Math.round(win.height)
                + " -> " + wW + "x" + wH + (final ? " FIN" : ""))
        }
        win.width = wW
        win.height = wH
    }
    // Keep the frame on whole tiles across icon-size changes: X changed
    // underneath the current pixel size, so requantize it. Idempotent when
    // the tile is unchanged. With dynamic resizing off, the picked grid is
    // re-derived exactly through the new tile (nearest-round would let the
    // intent drift by a tile across icon-scale changes).
    function requantize() {
        if (tile < 1)
            return
        var fixed = fixedGridSize()
        if (fixed) {
            snappedW = Math.min(15, Math.max(1, fixed.cols)) * tile
            snappedH = Math.min(15, Math.max(1, fixed.rows)) * tile
        } else {
            snappedW = Math.min(15, Math.max(1, Math.round(snappedW / tile))) * tile
            snappedH = Math.min(15, Math.max(1, Math.round(snappedH / tile))) * tile
        }
        snapPause.restart()
    }
    // One synchronous evaluation of every link from grid to window at the
    // lifecycle points (open/close/lift/resize), plus an instance tag —
    // several folders share this log. Permanent diag-gated machinery.
    function geo(tag) {
        var rep = fullRepresentationItem
        var g = (rep && rep.gridView) ? rep.gridView : null
        var c = (rep && rep.containerView) ? rep.containerView : null
        var w = (rep && rep.Window) ? rep.Window.window : null
        trace(tag + " inst=a" + apps.length + "t" + tile
            + " grid=" + (g ? Math.round(g.width) + "x" + Math.round(g.height) : "?")
            + " cont=" + (c ? Math.round(c.width) + "x" + Math.round(c.height) : "?")
            + " rep=" + (rep ? Math.round(rep.width) + "x" + Math.round(rep.height) + "/" + Math.round(rep.implicitWidth) + "x" + Math.round(rep.implicitHeight) : "?")
            + (w ? " win=" + Math.round(w.x) + "," + Math.round(w.y) + " " + Math.round(w.width) + "x" + Math.round(w.height) : " win=?"))
    }
    // Dialog chrome resizes do not always move the grid synchronously, so
    // the window itself also drives the requantize throttle. The log side
    // (rsz/rsz-end) is permanent diag-gated machinery: throttled trajectory
    // lines plus one line 250ms after motion stops — that tail line is the
    // release point we compare against the snap line 1.5s later to expose
    // any post-release configure lag (the ghost size).
    property double lastRszLog: 0
    Timer {
        id: rszLogTail
        interval: 250
        repeat: false
        onTriggered: geo("rsz-end")
    }
    function rszLog() {
        // Arrived: release the clamps the moment the window reaches the
        // target instead of holding them the full ack margin — a re-grab
        // during the hold otherwise finds an immovable frame (the
        // "must try 2-3 times" report).
        if (enforcingW || enforcingH) {
            var rep0 = fullRepresentationItem
            if (rep0 && rep0.gridView
                && Math.abs(rep0.gridView.width - snappedW) <= 1
                && Math.abs(rep0.gridView.height - snappedH) <= 1) {
                enforcingW = false
                enforcingH = false
                geo("arrived")
                // Truth refresh BEFORE the arrival recenter (the M2 lock):
                // a border-drag release payload carries the PRE-re-anchor
                // position, so the seed below can claim "already centered"
                // while the window actually sits at the task-manager clamp.
                // One read-only query — its verdict re-seeds truth and the
                // self-correction path re-centers ~100-150ms later if the
                // recenter below early-returns on the stale seed.
                runStateQuery()
                trace("arrival truth query")
                // The shell re-derives the popup x on EVERY client resize
                // (each stepper write) — only a recenter AFTER the last
                // write sticks. Do it now AND let snapClear fire once more
                // (not stopped) in case a sibling axis still steps.
                lastRecenterAt = 0
                recenterIfNeeded(true)
            }
        }
        snapPause.restart()
        rszLogTail.restart()
        armDebounce.restart()
        var now = Date.now()
        if (now - lastRszLog < 150)
            return
        lastRszLog = now
        geo("rsz")
    }
    // True from the expand flip until the popup's first real placement (or
    // the sizeSettle lift): the window is created UNPLACED (QML x stays 0),
    // and QML x on panel popups only ever changes at map time — external
    // KWin moves never reach it — so the first x>0 is exactly the placement.
    property bool openPlaceArmed: false
    // Timestamp of the popup window's last rendered frame (animation-start
    // pairing, see onAfterRendering). Reset at every expand.
    property double lastRenderAt: 0
    // The pre-map tile-exact write at expand needs a chrome estimate; with
    // none at all (no live grid, no frozen chrome, no persisted config
    // chrome — only the very first open ever) it is skipped and this timer
    // runs the correction instead, when window AND grid are measurable.
    // Re-armed at placement so the write lands >=350ms AFTER the map: a
    // resize ~50ms after map raced the task manager's window-icon handling
    // badly enough to crash plasmashell twice (libtaskmanager icon_changed
    // on a QtConcurrent thread, Qt 6.11). Nothing cancels it except a grab
    // (grabCancel clears wantExact) or collapse — a late small correction
    // beats a permanent +-1px residue.
    property bool wantExact: false
    Timer {
        id: exactTimer
        interval: 350
        repeat: false
        onTriggered: {
            if (!root.wantExact || !root.expanded)
                return
            var repE = fullRepresentationItem
            var winE = (repE && repE.Window) ? repE.Window.window : null
            if (!repE || !repE.gridView || !winE || winE.width < 10)
                return
            var lw = Math.round(winE.width - repE.gridView.width)
            var lh = Math.round(winE.height - repE.gridView.height)
            if (!(lw > 0 && lw < tile && lh > 0 && lh < tile))
                return
            root.wantExact = false
            root.shrinkChromeW = lw
            root.shrinkChromeH = lh
            var ew = 0
            var eh = 0
            if (root.fixedGridSize()) {
                // Dynamic resizing off: the picked grid stays the size of
                // record; only the window write runs.
                ew = root.snappedW
                eh = root.snappedH
            } else {
                ew = Math.min(15, Math.max(1, Math.round((winE.width - lw) / tile))) * tile
                eh = Math.min(15, Math.max(1, Math.round((winE.height - lh) / tile))) * tile
                if (ew !== root.snappedW || eh !== root.snappedH) {
                    root.snappedW = ew
                    root.snappedH = eh
                }
            }
            var tew = ew + lw
            var teh = eh + lh
            if (Math.abs(Math.round(winE.width) - tew) > 1
                || Math.abs(Math.round(winE.height) - teh) > 1) {
                winE.width = tew
                winE.height = teh
                root.trace("deferred-exact " + Math.round(winE.width) + "x" + Math.round(winE.height)
                    + " -> " + tew + "x" + teh)
            }
        }
    }
    Connections {
        target: fullRepresentationItem && fullRepresentationItem.Window ? fullRepresentationItem.Window.window : null
        function onWidthChanged() {
            rszLog()
        }
        function onHeightChanged() {
            rszLog()
        }
        function onXChanged() {
            var win = target
                if (root.openPlaceArmed && win && win.x > 0) {
                    root.openPlaceArmed = false
                    trace("placed x=" + Math.round(win.x))
                    // The content animation is NOT started here: placement can
                    // precede the first PRESENTED frame, and a ramp started now
                    // plays into a window that is not presenting yet — frozen
                    // small icons for ~350ms, then a jump (the two-step open).
                    // The first rendered frame (onAfterRendering) starts it.
                    //
                    // QML win.x/y changes only HERE, at map — and at this
                    // instant it EQUALS KWin truth (rig-proven: the sampler's
                    // windowAdded geometry matched the placed value exactly,
                    // every span). Seed truth now; every later moment QML x
                    // is frozen garbage.
                    root.trueX = win.x
                    root.trueY = win.y
                    root.captureAnchor()
                    // VERIFY, never write: since the S40 policy the intent
                    // equals the shell's placement rule, so the shell's own
                    // map-time placement (computed from map-time geometry —
                    // always fresher than our flip-time intent) IS the
                    // correct spot. A write here could only move the popup
                    // toward staler data — the visible post-open nudge
                    // ("pops out, then adjusts a few pixels"). The read-only
                    // query refreshes truth; its self-correction path writes
                    // only on GROSS misplacement (>8px, fresh bounds).
                    root.runStateQuery()
                    // Border zones need one REAL KWin write per open even when
                    // this popup opens already centered (see borderArmWrite).
                    // Truth is fresh (seeded above), so the arm nudge targets
                    // the real position.
                    root.borderArmWrite()
                    // Deferred tile-exact write re-armed FROM PLACEMENT so it
                    // lands >=350ms AFTER the map (the crash window is a resize
                    // ~50ms after map; an expand-armed countdown alone could
                    // land ~200ms after a slow map).
                    if (root.wantExact)
                        exactTimer.restart()
                }
        }
        function onAfterRendering() {
            // Render-gated animation start. A LONE early render burst (seen
            // on reopen: one frame ~20ms after the flip, before the remap)
            // must NOT start the ramp — its clock then freezes with the
            // unexposed window and icons sit frozen mid-grow until the map.
            // Start only when frames flow STEADILY: a second render within
            // 120ms of the previous one. The visibility==2 flip and the
            // 900ms openFallback are the alternate starters.
            if (root.expanded && fullRepresentationItem
                && !fullRepresentationItem.openAnimStarted
                && root.lastRenderAt > 0 && Date.now() - root.lastRenderAt <= 120) {
                fullRepresentationItem.startOpenAnim()
                trace("anim start render")
            }
            root.lastRenderAt = Date.now()
        }
        function onVisibilityChanged(v) {
            if (v === 2 && root.expanded) {
                // Map-flip path (S32): the first-x placement hook cannot
                // fire on same-session reopens — QML win.x freezes at the
                // previous map's value and the shell re-places at the same
                // x, so onXChanged stays silent. Since S40 the shell's own
                // placement IS the policy target, so this path only
                // VERIFIES (read-only query; see the placement-hook
                // comment) — it never writes.
                if (root.openPlaceArmed) {
                    root.captureAnchor()
                    // Verify-only (see the placement hook above): writing
                    // here computed its target against a not-yet-relaid-out
                    // grid (garbage chrome) and a stale frozen-x truth seed —
                    // a wrong-target write ~100-300ms after map (rig S42:
                    // "recenter wrote 808" for a 3x3 whose target is 868).
                    root.runStateQuery()
                    if (root.wantExact)
                        exactTimer.restart()
                }
                // Border-arm on EVERY map flip (equal-x reopens never fire
                // onXChanged — this is their only placement-time path; on
                // fresh placements the kwinWriteThisOpen flag dedupes it
                // against the x>0 path's write).
                root.borderArmWrite()
                if (fullRepresentationItem
                    && !fullRepresentationItem.openAnimStarted) {
                    // Window exposed (the real map on first open / reopen):
                    // presentation is imminent, frames will flow.
                    fullRepresentationItem.startOpenAnim()
                    trace("anim start vis")
                }
            }
            // Ghost heal: the shell can hide the window directly (focus
            // race while a context menu opens — rig-reproduced) without the
            // expanded flip; the applet then sits "open" with no window and
            // every reset path is dead. Force the real collapse so all
            // state resets (guard, pin, snapped sync).
            // DECISION (S55 D4, user-approved): this also collapses PINNED
            // folders when the screen locks (the lock screen takes focus
            // and the popup window hides). Intended: a locked session must
            // not resurrect pinned popups on unlock.
            if (v === 0 && root.expanded) {
                trace("ghost-hide -> collapse")
                root.expanded = false
            }
        }
    }

    // -- runtime artifact directory (S55 hardening) ------------------------
    // The applet writes, executes or KWin-loads several runtime artifacts
    // (icon resolver aficonres.py, shared hook afhookS.js, query afqS.js,
    // one-shot recenter af*.js). /tmp is world-writable: on shared
    // machines another local user could pre-create or symlink those FIXED
    // names and have our code execute/load THEIR content. $XDG_RUNTIME_DIR
    // (/run/user/<uid>, mode 0700) is the correct per-user home for them.
    // The diagnostic files (/tmp/af-diag, /tmp/af-trace.log) deliberately
    // stay in /tmp: never executed, and the documented diag workflow
    // depends on those exact paths. /tmp remains the fallback.
    property string artifactDir: "/tmp"
    function detectArtifactDir() {
        var d = ""
        try {
            if (typeof Qt.getenv === "function")
                d = String(Qt.getenv("XDG_RUNTIME_DIR") || "")
        } catch (e) {}
        if (d.charAt(0) === "/") {
            artifactDir = d
            trace("artifact-dir " + d + " (qt.getenv)")
            return
        }
        // Qt.getenv unavailable on older Qt: one-shot shell resolve. A
        // dropped early engine command (startup race) just leaves the
        // working /tmp fallback in place.
        runCmd("printf '%s' \"${XDG_RUNTIME_DIR:-}\" #ad" + (traceSeq++), (out) => {
            var o = String(out || "").trim()
            if (o.charAt(0) === "/")
                artifactDir = o
            trace("artifact-dir " + artifactDir + " (shell)")
        })
    }

    // File-based trace: panel-applet console.log never reaches the journal,
    // but the exec bridge and /tmp reliably do.
    // The trailing #u<N> makes every invocation a UNIQUE source name: the
    // executable engine keys by command string, so identical concurrent
    // commands (several App Folder instances sharing one config value)
    // would silently drop each other's lines.
    property int traceSeq: 0
    // Diagnostics default OFF: every trace line is an engine fork, and
    // fork bursts saturate the executable engine — the event poll's greps
    // share it, and drops read exactly like "the animation sometimes
    // does not happen". Touch /tmp/af-diag and reopen the popup to arm.
    property bool diag: false
    function trace(msg) {
        if (!diag)
            return
        // The message goes in SINGLE quotes, outside the double-quoted
        // date part (S55 security): trace carries attacker-influenced
        // strings (KWin payloads, theme names, file paths), and $(...)/
        // backticks are live inside double quotes. shEscape neutralizes
        // everything while keeping the text verbatim in the log.
        runCmd("echo \"$(date +%H:%M:%S)\" '" + shEscape(String(msg))
            + "' >> /tmp/af-trace.log #u" + (traceSeq++))
    }

    // -- executable bridge (replaces cursor.py + bridge.py launch/IO) -----
    // The engine reports sourceName = the command string itself (NOT a
    // client key), so callbacks are keyed by exact command; concurrent
    // duplicates share a list. Read stdout synchronously in the handler,
    // then disconnect DEFERRED (synchronous disconnect truncates delivery;
    // never disconnecting floods repeats — both observed live).
    property var _pending: ({})

    Plasma5Support.DataSource {
        id: execEngine
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            const list = root._pending[sourceName]
            if (list === undefined)
                return
            delete root._pending[sourceName]
            const out = String(data["stdout"] ?? "")
            const code = data["exit code"] ?? -1
            // Null-guard: at widget teardown (remove/shutdown) the deferred
            // call can fire after the engine object is gone (rig-reproduced
            // TypeError storm in the journal).
            Qt.callLater(() => { if (execEngine) execEngine.disconnectSource(sourceName) })
            try {
                for (let i = 0; i < list.length; i++)
                    list[i](out, code)
            } catch (e) {
                console.warn("appfolder: exec callback failed for", sourceName, e)
            }
        }
    }

    function shEscape(s) {
        return String(s).replace(/'/g, "'\\''")
    }

    // Percent-encode a filesystem path for Image.source file URLs (S55):
    // '#', '?', '%', space (and non-ASCII) break URL parsing — Qt truncates
    // a file URL at '#' (fragment) and '?' (query), so icon files named
    // with them silently rendered nothing. Slashes stay literal.
    function fileUrl(p) {
        return "file://" + encodeURIComponent(String(p)).replace(/%2F/g, "/")
    }

    // Run a shell command. cb(stdout, exitCode). Fire-and-forget when omitted
    // (still disconnects after the first event so sources never accumulate).
    function runCmd(cmd, cb) {
        if (cb !== undefined) {
            if (root._pending[cmd] === undefined)
                root._pending[cmd] = []
            root._pending[cmd].push(cb)
        } else {
            root._pending[cmd] = []
        }
        execEngine.connectSource(cmd)
    }

    function launchApp(desktopPath) {
        runCmd("kioclient exec '" + shEscape(desktopPath) + "'")
    }

    function readTextFile(path, cb) {
        // Single-quoted argv (S55 security): the path can be drag-SOURCE-
        // controlled (drop.text -> localPath -> addApp), and shDQuote
        // deliberately leaves $ live inside double quotes — a crafted
        // "$(cmd)" or `cmd` filename would execute at read time. The only
        // call site (addApp) passes absolute paths needing no expansion.
        runCmd("cat '" + shEscape(path) + "'", (out, code) => cb(code === 0 ? out : null))
    }

    // -- themed icon resolution (S54d; S54e hardening: single-quoted argv,
    // instId batch suffix, bounded retry, theme-flip re-queue, miss
    // re-resolve) ---------------------------------------
    // The grid tile is a plain Image animating geometry over a constant
    // texture (S54b) — but plain Image has NO icon-theme support: every
    // image://icon URL fails with Qt's "Invalid image provider" (the
    // provider is not registered in the applet QML engine at all — journal-
    // proven 2026-09-25; it silently renders nothing), and PlasmaCore.IconItem
    // no longer exists in Plasma 6. The ONLY pixel channel that works for an
    // Image is a real file URL (rig-verified for .svg, .svgz-shaped themes
    // and .png). This block resolves .desktop Icon= names to icon FILES on
    // disk, theme-aware (kdeglobals [Icons] Theme, else the active
    // look-and-feel's defaults — e.g. Papirus here comes ONLY from the L&F,
    // kdeglobals has no [Icons] group — else hicolor/pixmaps), through ONE
    // batched executable-engine fork per new icon set. Results are cached in
    // memory per session; deliberately NOT persisted to config: one ~20ms
    // fork per widget start is cheaper than config churn and stale-theme
    // risk. While a name resolves, the tile paints nothing briefly; the
    // onAppsChanged prefetch means the usual case resolves before the first
    // popup ever opens. Known gaps, fine here and noted for exotic themes
    // at public release (S54e review #10): @2x scaled theme dirs are not
    // probed, and /usr/share/pixmaps is probed for .png/.xpm only.
    property var iconPathCache: ({})
    property string iconPathTheme: ""
    property var _iconPending: ({})
    property bool _iconResolveQueued: false
    property int _iconResolveFails: 0

    function requestIconPath(name, force) {
        // force=true re-queues a cached MISS ("") — used by the apps-load
        // prefetch so icons installed mid-session resolve on the next load
        // instead of staying blank until restart (S54e review #9). Never
        // call force for names that may hold a valid path.
        if (name === "" || root._iconPending[name] !== undefined)
            return
        if (!force && root.iconPathCache[name] !== undefined)
            return
        root._iconPending[name] = true
        if (!root._iconResolveQueued) {
            root._iconResolveQueued = true
            iconResolveTimer.restart()
        }
    }

    readonly property string _iconResolverPy: ""
        + "import os, sys\n"
        + "def cfg(path, group, key):\n"
        + "    try:\n"
        + "        ing = False\n"
        + "        with open(path, 'r', errors='replace') as f:\n"
        + "            for line in f:\n"
        + "                s = line.strip()\n"
        + "                if s.startswith('[') and s.endswith(']'):\n"
        + "                    ing = (s == '[' + group + ']')\n"
        + "                elif ing and '=' in s and s.split('=', 1)[0].strip() == key:\n"
        + "                    return s.split('=', 1)[1].strip()\n"
        + "    except Exception:\n"
        + "        pass\n"
        + "    return ''\n"
        + "kg = os.path.expanduser('~/.config/kdeglobals')\n"
        + "theme = cfg(kg, 'Icons', 'Theme')\n"
        + "if not theme:\n"
        + "    laf = cfg(kg, 'KDE', 'LookAndFeelPackage')\n"
        + "    for base in (os.path.expanduser('~/.local/share/plasma/look-and-feel'), '/usr/share/plasma/look-and-feel'):\n"
        + "        theme = cfg(os.path.join(base, laf, 'contents', 'defaults'), 'kdeglobals][Icons', 'Theme')\n"
        + "        if theme:\n"
        + "            break\n"
        + "if not theme:\n"
        + "    theme = 'breeze'\n"
        + "print('THEME\\t' + theme)\n"
        + "names = sys.argv[1:]\n"
        + "roots = [os.path.expanduser('~/.local/share/icons'), os.path.expanduser('~/.icons'), '/usr/share/icons']\n"
        + "bases = [theme] + (['hicolor'] if theme != 'hicolor' else [])\n"
        + "sizes = ['scalable', '256x256', '128x128', '96x96', '64x64', '48x48', '32x32', '24x24', '22x22', '16x16']\n"
        + "exts = [('.svg', 0), ('.svgz', 0), ('.png', 1), ('.xpm', 2)]\n"
        + "best = {}\n"
        + "def consider(n, rank, p):\n"
        + "    cur = best.get(n)\n"
        + "    if cur is None or rank < cur[0]:\n"
        + "        best[n] = (rank, p)\n"
        + "for bi, base in enumerate(bases):\n"
        + "    for rt in roots:\n"
        + "        bd = os.path.join(rt, base)\n"
        + "        if not os.path.isdir(bd):\n"
        + "            continue\n"
        + "        for si, size in enumerate(sizes):\n"
        + "            sd = os.path.join(bd, size)\n"
        + "            if not os.path.isdir(sd):\n"
        + "                continue\n"
        + "            try:\n"
        + "                ctxs = os.listdir(sd)\n"
        + "            except Exception:\n"
        + "                continue\n"
        + "            for ctx in ctxs:\n"
        + "                cd = os.path.join(sd, ctx)\n"
        + "                if not os.path.isdir(cd):\n"
        + "                    continue\n"
        + "                for n in names:\n"
        + "                    cur = best.get(n)\n"
        + "                    if cur is not None and cur[0] <= (bi, si, 0):\n"
        + "                        continue\n"
        + "                    for ext, xi in exts:\n"
        + "                        p = os.path.join(cd, n + ext)\n"
        + "                        if os.path.isfile(p):\n"
        + "                            consider(n, (bi, si, xi), p)\n"
        + "                            break\n"
        + "pd = '/usr/share/pixmaps'\n"
        + "if os.path.isdir(pd):\n"
        + "    for n in names:\n"
        + "        for ext, xi in (('.png', 1), ('.xpm', 2)):\n"
        + "            p = os.path.join(pd, n + ext)\n"
        + "            if os.path.isfile(p):\n"
        + "                consider(n, (2, 99, xi), p)\n"
        + "                break\n"
        + "for n in names:\n"
        + "    v = best.get(n)\n"
        + "    print(n + '\\t' + (v[1] if v else ''))\n"

    function _iconResolveFlush() {
        root._iconResolveQueued = false
        var names = Object.keys(root._iconPending)
        if (names.length === 0)
            return
        root._iconPending = {}
        var q = []
        for (var i = 0; i < names.length; i++)
            // Single-quote argv (S54e review #4): icon names are .desktop
            // FILE CONTENT and shDQuote deliberately preserves $ — a crafted
            // Icon=$(...) value would execute at resolve time. shEscape
            // neutralizes everything; nothing here needs $ expansion.
            q.push("'" + shEscape(names[i]) + "'")
        runCmd("cat > \"" + artifactDir + "/aficonres.py\" <<'AFIREOF'\n" + root._iconResolverPy
               + "AFIREOF\npython3 \"" + artifactDir + "/aficonres.py\" " + q.join(" ")
               + " #ir" + instId + "-" + (traceSeq++), function(out, code) {
            var theme = null
            var merged = {}
            var lines = String(out || "").split("\n")
            for (var i = 0; i < lines.length; i++) {
                var t = lines[i]
                if (t.indexOf("THEME\t") === 0) {
                    theme = t.slice(6)
                    continue
                }
                var tab = t.indexOf("\t")
                if (tab > 0)
                    merged[t.slice(0, tab)] = t.slice(tab + 1)
            }
            if (code !== 0 || theme === null) {
                // Bounded retry (S54e review #3): the batch was already
                // dequeued, so a failed fork would otherwise leave those
                // names unrequested forever (delegates completed, prefetch
                // ran). Cap 2: a persistently broken resolver must not
                // fork-loop. The rewrite+run is self-healing per batch.
                if (root._iconResolveFails < 2) {
                    root._iconResolveFails++
                    for (var r = 0; r < names.length; r++)
                        root._iconPending[names[r]] = true
                    iconRetryTimer.restart()
                }
                return
            }
            root._iconResolveFails = 0
            var stale = []
            var next = {}
            if (theme === root.iconPathTheme) {
                for (var k in root.iconPathCache)
                    next[k] = root.iconPathCache[k]
            } else {
                // Theme flip (or first run): stale-theme paths are dropped
                // by starting empty, and every previously cached name is
                // RE-QUEUED below so no surviving tile goes blank until the
                // next apps reload (S54e review #2). Misses still merge as
                // "" so a name never loops.
                for (var k3 in root.iconPathCache)
                    stale.push(k3)
            }
            root.iconPathTheme = theme
            var ok = 0
            for (var k2 in merged) {
                next[k2] = merged[k2]
                if (merged[k2] !== "")
                    ok++
            }
            for (var j = 0; j < names.length; j++)
                if (next[names[j]] === undefined)
                    next[names[j]] = ""
            root.iconPathCache = next
            for (var s = 0; s < stale.length; s++)
                root.requestIconPath(stale[s])
            trace("icon-resolve theme=" + theme + " asked=" + names.length
                  + " ok=" + ok)
        })
    }

    Timer {
        id: iconResolveTimer
        interval: 40
        running: false
        repeat: false
        onTriggered: root._iconResolveFlush()
    }

    Timer {
        id: iconRetryTimer
        interval: 500
        running: false
        repeat: false
        onTriggered: root._iconResolveFlush()
    }

    // -- grid metrics (1..10 scales, v1 mapping) ---------------------------
    readonly property int columns: 3
    property int iconScale: 6
    property int padScale: 6
    property int compactScale: 6
    readonly property int tileIcon: 24 + (iconScale - 1) * 4
    // Icon padding scale 1..10 -> 2..20px cell padding. 6 reproduces the
    // old fixed 12px, so existing folders keep their look; requantize()
    // keeps snapped frame sizes on whole multiples of the new tile.
    readonly property int tilePad: 2 * padScale
    readonly property int tile: tileIcon + 2 * tilePad

    // -- custom decoration (themeAdapt ON = shell draws the background) ----
    property bool themeAdapt: true
    property string customBg: ""
    property real customOpacity: 0.95
    property int cornerScale: 6
    property int outlineScale: 1
    function withAlpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

    // -- popup state --------------------------------------------------------
    // Pin-gated dialog sizing: pinned (transitions) clamps the dialog to
    // content; lifted (settled) the dialog sits on the snapped whole-tile
    // size and manual drags requantize to it (bigger frame = room for more
    // apps). Opens respect manual sizes, requantized to whole tiles.
    property bool sizePinned: false

    property bool showSettings: false
    // True once this settings session has a committed checked-grid pick
    // (openSettings resets it; applySelection sets it).
    property bool sizePicked: false
    // "Dynamic Resizing (beta)" — the border-drag resize + snap method.
    // OFF by default (S40c): the checked grid picker is the primary size
    // control; border drags stay opportunistic until a size is picked,
    // after which drags spring back to the picked grid.
    property bool dynamicResize: false
    // The picked grid dimensions when they are the size of record
    // (dynamic resizing off AND a pick was ever committed); null otherwise.
    function fixedGridSize() {
        if (dynamicResize)
            return null
        var c = plasmoid.configuration.folderCols || 0
        var r = plasmoid.configuration.folderRows || 0
        return (c > 0 && r > 0) ? { cols: c, rows: r } : null
    }
    property string folderIconName: "folder"
    property var allIcons: []
    property var shownIcons: []
    property string iconTheme: "breeze"
    property string iconFilter: ""
    property string iconScanTheme: ""
    readonly property int settingsW: 380
    // 700 (was 620): the checked-grid size picker + its labels need ~230px
    // more than the old column could spare; icon grid keeps >=110px.
    readonly property int settingsH: 700

    function clampScale(v) { return Math.max(1, Math.min(10, Math.round(v))) }
    // NOTE: v1 had dragHover/pickerOpen guards here for its own auto-hide
    // timer. The shell owns hiding now, so nothing consumes them — and root
    // bindings must not touch fullRepresentation ids (that subtree may not
    // exist yet when root bindings first evaluate → startup ReferenceErrors).


    onAppsChanged: {
        // The grid lives inside fullRepresentation: reach it only through
        // the shell alias (?. skips the not-yet-instantiated phase quietly;
        // the grid starts on page 0 by itself anyway).
        if (fullRepresentationItem)
            fullRepresentationItem.clampPage()
        // Prefetch icon files for every themed name (S54d): resolution is
        // one batched fork, so it lands long before the first popup opens
        // and the grid never waits on it. Cached MISSES are re-requested
        // (force) so icons installed mid-session resolve on the next
        // apps-load instead of staying blank until restart (S54e #9).
        for (var i = 0; i < apps.length; i++) {
            var ic = apps[i] ? (apps[i].icon || "") : ""
            if (ic !== "" && ic.charAt(0) !== "/")
                requestIconPath(ic, root.iconPathCache[ic] === "")
        }
        requestIconPath("application-x-executable",
                        root.iconPathCache["application-x-executable"] === "")
    }

    // -- apps model (per-instance config storage) ---------------------------
    property var apps: []

    function loadApps() {
        try {
            const v = JSON.parse(plasmoid.configuration.folderApps || "[]")
            apps = Array.isArray(v) ? v.filter(a => a && a.desktop) : []
        } catch (e) {
            apps = []
        }
    }

    function saveApps() {
        plasmoid.configuration.folderApps = JSON.stringify(apps)
        flushConfig()
    }

    function flushConfig() {
        if (typeof plasmoid.configuration.writeConfig === "function")
            plasmoid.configuration.writeConfig()
    }

    function loadUi() {
        const c = plasmoid.configuration
        iconScale = clampScale(c.iconScale || 6)
        // Padding floor 3: the shell dialog chrome adds a fixed ~8px per
        // side to the icon-to-frame gap, so at pad 1-2 the border gap
        // visibly exceeds the icon-to-icon gap (the "padding ignores the
        // border" look). 3 keeps the worst imbalance at ~2px.
        padScale = Math.max(3, clampScale(c.iconPad || 6))
        compactScale = clampScale(c.compactScale || 6)
        themeAdapt = c.themeAdapt !== false
        // Explicit opt-in: the schema default is OFF (S40c); a stored
        // true keeps dynamic resizing for folders that had it enabled.
        dynamicResize = c.dynamicResize === true
        customBg = typeof c.bgColor === "string" ? c.bgColor : ""
        // bgOpacity load-back (S55): persistUi has always WRITTEN it, but
        // it was never read — custom opacity silently reset to 0.95 on
        // every plasmashell restart. Range-guarded to the slider's span.
        customOpacity = (typeof c.bgOpacity === "number" && c.bgOpacity >= 0.2 && c.bgOpacity <= 1)
            ? c.bgOpacity : 0.95
        cornerScale = clampScale(c.cornerScale || 6)
        outlineScale = clampScale(c.outlineScale || 1)
        folderIconName = c.folderIcon || "folder"
        requantize()
        trace("loadUi icon=" + iconScale + " compact=" + compactScale)
    }

    function persistUi() {
        const c = plasmoid.configuration
        c.iconScale = iconScale
        c.iconPad = padScale
        c.compactScale = compactScale
        c.themeAdapt = themeAdapt
        c.dynamicResize = dynamicResize
        c.bgColor = customBg
        c.bgOpacity = customOpacity
        c.cornerScale = cornerScale
        c.outlineScale = outlineScale
        requantize()
        trace("persist icon=" + iconScale + " compact=" + compactScale)
        flushConfig()
    }
    // (dialog sizing: growth follows Layout minimums; the shell restores the
    // saved grid size on every open, so no explicit sizing is needed.)

    // -- .desktop field parsing (section-aware, main group only) ------------
    // Locale-aware (S55 T-RR5): prefers Name[lang_COUNTRY] / Name[lang]
    // over the bare key, per the desktop-entry spec's fallback order —
    // non-English users previously always saw the default name. Lines
    // BEFORE the [Desktop Entry] header are ignored (pre-header garbage
    // used to match a bare "Name=" there).
    function desktopField(text, field) {
        const lines = String(text).split("\n")
        var loc = ""
        try { loc = Qt.locale().name || "" } catch (e) {}
        var lang = loc.split("_")[0]
        var keys = [field + "[" + loc + "]", field + "[" + lang + "]", field]
        var found = [undefined, undefined, undefined]
        var inActions = false
        var inMain = false
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i]
            if (line[0] === "[") {
                inMain = line.indexOf("[Desktop Entry]") === 0
                inActions = line.indexOf("[Desktop Action") === 0
                continue
            }
            if (!inMain || inActions)
                continue
            for (let k = 0; k < keys.length; k++) {
                if (found[k] === undefined && line.indexOf(keys[k] + "=") === 0)
                    found[k] = line.slice(keys[k].length + 1).trim()
            }
        }
        for (let k = 0; k < keys.length; k++) {
            if (found[k] !== undefined && found[k] !== "")
                return found[k]
        }
        return ""
    }

    function localPath(url) {
        let s = String(url || "").trim().replace(/^file:\/\//, "")
        try {
            s = decodeURIComponent(s)
        } catch (e) {}
        if (s === "" || s.indexOf("/") !== 0)
            return (/\.desktop$/i.test(s) ? s : "")
        return s
    }

    function addApp(desktopPath) {
        if (!desktopPath)
            return
        for (let i = 0; i < apps.length; i++) {
            if (apps[i].desktop === desktopPath)
                return
        }
        const finish = (name, icon) => {
            // Re-check duplicates (S55 T-LE7): readTextFile is ASYNC, so a
            // second add of the same path while the first read is in
            // flight slips past the guard above — two rapid adds used to
            // yield two identical tiles.
            for (let j = 0; j < apps.length; j++) {
                if (apps[j].desktop === desktopPath)
                    return
            }
            if (!name)
                name = desktopPath.split("/").pop().replace(/\.desktop$/i, "")
            const na = apps.slice()
            na.push({ desktop: desktopPath, name: name, icon: icon })
            apps = na
            saveApps()
        }
        // Stale/bare entries are skipped AT ADD TIME (S55 D3, user
        // decision): a bare "name.desktop" has no usable launch path
        // (kioclient exec needs an absolute file), and an unreadable file
        // would become a dead tile — both launched nothing, with no
        // feedback. Entries whose file disappears LATER keep today's
        // silent launch failure (documented in README troubleshooting).
        if (desktopPath[0] !== "/") {
            trace("add-app skip (bare name): " + desktopPath)
            return
        }
        readTextFile(desktopPath, (text) => {
            if (text === null) {
                trace("add-app skip (unreadable): " + desktopPath)
                return
            }
            finish(desktopField(text, "Name"), desktopField(text, "Icon"))
        })
    }

    function handleDrop(drop) {
        for (let i = 0; i < drop.urls.length; i++)
            addApp(localPath(drop.urls[i].toString()))
        if (drop.urls.length === 0 && drop.text) {
            const t = drop.text.trim()
            if (t)
                addApp(localPath(t) || (/\.desktop$/i.test(t) ? t : ""))
        }
    }

    function removeAt(index) {
        const na = apps.slice()
        if (index < 0 || index >= na.length)
            return
        na.splice(index, 1)
        apps = na
        saveApps()
    }

    function move(from, to) {
        const na = apps.slice()
        if (from < 0 || from >= na.length)
            return
        to = Math.max(0, Math.min(na.length, to))
        if (to === from)
            return
        const item = na.splice(from, 1)[0]
        na.splice(to, 0, item)
        apps = na
        saveApps()
    }
    // -- icon inventory (theme + breeze + hicolor + local, all sizes) --------
    function detectTheme() {
        // #dt suffix (S55): unique source name per call (engine discipline,
        // same as checkDiag's #cd).
        runCmd("grep -m1 '^Theme=' $HOME/.config/kdeglobals | cut -d= -f2 #dt" + (traceSeq++), (out) => {
            const t = (out || "").trim()
            if (t)
                iconTheme = t
        })
    }

    function openSettings() {
        trace("openSettings enter icon=" + iconScale)
        // Stop any live shrink stepper (S55 T-LE3): settings pins the
        // layout to settingsW/H, and a stepper still ticking would write
        // window sizes against that pin for up to 170ms (a visible fight).
        shrinkStop("w")
        shrinkStop("h")
        // Remember the live frame so Back restores the user's size; the
        // reset-to-3x3 it replaces silently discarded manual resizing.
        preSettingsW = snappedW
        preSettingsH = snappedH
        backstop.stop()
        backstopTries = 0
        grabSeen = false
        releaseSeen = false
        sizePicked = false
        folderIconName = plasmoid.configuration.folderIcon || "folder"
        if (fullRepresentationItem) {
            fullRepresentationItem.scanIcons()
            // The checked-grid picker starts from the LIVE tile count
            // (clamped to the 10x10 grid; a folder larger than 10 tiles on
            // an axis reads as 10 there).
            var pt = Math.max(1, tile)
            fullRepresentationItem.initSizePicker(
                Math.min(10, Math.max(1, Math.round(snappedW / pt))),
                Math.min(10, Math.max(1, Math.round(snappedH / pt))))
        }
        showSettings = true
    }

    // Back-to-grid (Back button and Escape): requantize the remembered
    // frame through the CURRENT tile — icon size / padding may have changed
    // in settings, and raw pre-settings pixels would land off-grid under
    // the new tile (frame would sit between whole tiles until the next
    // snap). A committed checked-grid pick is tile-count INTENT: apply it
    // through the current tile so a slider-driven tile change in between
    // keeps the picked columns/rows exactly.
    function leaveSettings() {
        trace("back")
        showSettings = false
        var qw = 0
        var qh = 0
        if (sizePicked && plasmoid.configuration.folderCols > 0
            && plasmoid.configuration.folderRows > 0) {
            qw = Math.min(15, Math.max(1, plasmoid.configuration.folderCols)) * tile
            qh = Math.min(15, Math.max(1, plasmoid.configuration.folderRows)) * tile
        } else {
            qw = preSettingsW > 0 ? preSettingsW : columns * tile
            qh = preSettingsH > 0 ? preSettingsH : columns * tile
            qw = Math.min(15, Math.max(1, Math.round(qw / tile))) * tile
            qh = Math.min(15, Math.max(1, Math.round(qh / tile))) * tile
        }
        snappedW = qw
        snappedH = qh
        sizePinned = true
        sizeSettle.restart()
    }

    function setFolderIcon(name) {
        plasmoid.configuration.folderIcon = name || "folder"
        folderIconName = plasmoid.configuration.folderIcon
        flushConfig()
    }


    Component.onCompleted: {
        detectArtifactDir()
        loadApps()
        loadUi()
        detectTheme()
        checkDiag()
    }

    function checkDiag() {
        // #cd suffix (S55): unique source name per call per the engine
        // discipline — the identical static string from two instances
        // sharing the engine would be dropped as a duplicate.
        runCmd("test -f /tmp/af-diag && echo 1 || echo 0 #cd" + (traceSeq++), (out, code) => {
            diag = String(out || "").trim().indexOf("1") === 0
        })
    }

    // compact: explicit press-tracking toggle, mirroring the stock
    // DefaultCompactRepresentation. (Relying on a shell fallback proved
    // unreliable live: clicks silently did nothing. Owning the two lines
    // costs nothing and behaves identically.)
    // Outer Item fills the panel cell (the shell dictates that geometry and
    // overrides explicit sizes on the rep itself — which is why Widget size
    // did nothing); the inner icon keeps its own size, centered.
    compactRepresentation: Item {
        // Panel-screen bounds for the hook-at-map intent: the compact icon
        // is always placed, while the popup window is UNPLACED at the
        // expand flip (captureAnchor caches these alongside anchorCx/Cy).
        readonly property int scrL: Screen.virtualX
        readonly property int scrR: Screen.virtualX + Screen.width
        readonly property int scrT: Screen.virtualY
        readonly property int scrB: Screen.virtualY + Screen.height
        Kirigami.Icon {
            anchors.centerIn: parent
            width: 24 + (compactScale - 1) * 4
            height: 24 + (compactScale - 1) * 4
            source: Plasmoid.icon
            active: compactMouse.containsMouse
        }
        MouseArea {
            id: compactMouse
            anchors.fill: parent
            hoverEnabled: true
            property bool wasExpanded: false
            onPressed: wasExpanded = root.expanded
            onClicked: root.expanded = !wasExpanded
        }
    }

    // The popup. Shell-anchored, themed, blurred; the shell closes it on
    // outside click (standard dialog behavior — no pin override possible).
    fullRepresentation: PlasmaExtras.Representation {
        // The open animation is ARMED here only (armOpenAnim at the expand
        // flip) and STARTED at the window's first rendered frame (root's
        // onAfterRendering) — never at creation: this subtree is built while
        // the popup window is unplaced and renders nothing.
        Component.onCompleted: armOpenAnim()
        // Free at rest so the resize handles keep working; the open pin
        // clamps to whole-tile sizes. Enforcement NEVER clamps here: the
        // stepper owns the window while enforcing (direct writes), and a
        // parallel min/max clamp let KWin fight the stepper mid-glide
        // (stale-value clamps, divergence cancels, restart storms).
        Layout.minimumWidth: showSettings ? settingsW : (sizePinned ? snappedW : 1)
        Layout.minimumHeight: showSettings ? settingsH : (sizePinned ? snappedH : 1)
        Layout.maximumWidth: showSettings ? settingsW : (sizePinned ? snappedW : 9999)
        Layout.maximumHeight: showSettings ? settingsH : (sizePinned ? snappedH : 9999)

        // --- rep-local state: ids below live in this subtree; root must
        // reach them only via fullRepresentationItem (shell alias).
            property int dragSource: -1
            property int dropTarget: -1
            // Screen edges for the recenter clamp (fallback when the window
            // handle exposes no screen). Attached Screen = the popup's own
            // screen, logical coordinates.
            readonly property int screenEdgeL: Screen.virtualX
            readonly property int screenEdgeR: Screen.virtualX + Screen.width
            function closeAllMenus() {
                gridMenu.close()
                fullRep.menuEpoch++
            }
            // Render-gated open animation, driven by root: armOpenAnim()
            // at the expand flip (content parked at progress 0, invisible),
            // startOpenAnim() when the window demonstrably presents (root's
            // onVisibilityChanged/onAfterRendering hooks or the openFallback
            // timer). Starting at the flip or at placement played the ramp
            // into a window that was not presenting yet — the frozen-small-
            // icons-then-jump "two-step" open (S31 video analysis). The
            // flag lives HERE (not on fullRep): root reaches it as
            // fullRepresentationItem.openAnimStarted — the Representation is
            // what fullRepresentationItem aliases.
            property bool openAnimStarted: false
            function armOpenAnim() {
                openRamp.stop()
                if (root.slideArmed) {
                    // Slide-armed open: content fully visible from the
                    // first frame — the compositor slide owns the motion;
                    // a second content ramp composites into the S31
                    // double-alpha ghost. openAnimStarted=true parks the
                    // starters as no-ops. Unsupported hosts fall through
                    // to the rise+fade fallback (risePx rides progress).
                    fullRep.openProgress = 1
                    openAnimStarted = true
                } else {
                    // Arm the rise+fade (content parked at progress 0 —
                    // invisible and offset toward the panel); the starters
                    // launch it when the window demonstrably presents.
                    fullRep.openProgress = 0
                    openAnimStarted = false
                }
            }
            function startOpenAnim() {
                if (openAnimStarted)
                    return
                openAnimStarted = true
                // Wall-clock ramp (see openRamp): t0 set HERE, at the starter
                // (visibility flip / steady renders / 900ms fallback), so the
                // 170ms window always begins when the open actually starts.
                openRamp.t0 = Date.now()
                openRamp.restart()
            }
            // hoverArmed lives on fullRep (delegates bind to it by id), so
            // root reaches it only through this shim — fullRepresentationItem
            // is the Representation itself, which has no such property.
            function setHoverArmed(v) {
                fullRep.hoverArmed = v
            }
            // Checked-grid size picker plumbing (settingsView subtree —
            // same scoping rule as setHoverArmed: root goes through these).
            function initSizePicker(c, r) {
                sizePicker.comCols = c
                sizePicker.comRows = r
                sizePicker.selCols = c
                sizePicker.selRows = r
            }
            // Rig/test entry: commit a pick without the MouseArea (the
            // panel rig drives the applet through /tmp/aftest.cmd).
            function commitSizePick(c, r) {
                sizePicker.selCols = c
                sizePicker.selRows = r
                sizePicker.applySelection()
            }
            // Grid (not window) size changes drive snap debounce: stable
            // object, fires on dialog resizes via layout, never null.
            Connections {
                target: grid
                function onWidthChanged() {
                    snapPause.restart()
                    armDebounce.restart()
                }
                function onHeightChanged() {
                    snapPause.restart()
                    armDebounce.restart()
                }
            }
            property int gridPage: 0
            readonly property int pageSize: Math.max(1, dcols * drows)
            // Display columns: fluid to the live grid while the user
            // drags (macOS-style live reflow), but frozen to the TARGET
            // during pins, enforcement and the glide — one reflow at
            // animation start, then the frame grows around a stable
            // layout instead of icons popping at each tile crossing.
            readonly property bool layoutFrozen: root.sizePinned || root.enforcingW || root.enforcingH
                || root.shrinkWActive || root.shrinkHActive
            property int dcols: layoutFrozen ? Math.min(15, Math.max(1, Math.round(snappedW / tile))) : Math.max(1, Math.floor(grid.width / tile))
            property int drows: layoutFrozen ? Math.min(15, Math.max(1, Math.round(snappedH / tile))) : Math.max(1, Math.floor(grid.height / tile))
            property alias gridView: grid
            property alias containerView: container
            // Read-only view of the content animation state for the panel
            // rig's 16ms sampler (production code never writes it).
            readonly property real openProgressLive: fullRep.openProgress
            readonly property int pageCount: Math.max(1, Math.ceil(apps.length / pageSize))
            function bumpPage(dir) {
                if (pageCount <= 1)
                    return
                gridPage = Math.max(0, Math.min(pageCount - 1, gridPage + dir))
                grid.contentY = gridPage * grid.height
            }
        function clampPage() {
            if (gridPage > pageCount - 1) {
                gridPage = pageCount - 1
                grid.contentY = gridPage * grid.height
            }
        }
        // Map a pointer position (tile-local, from the delegate MouseArea)
        // onto a grid cell. Missing until now: every drag past the 12px
        // threshold threw ReferenceError here, dropTarget stayed -1, and
        // the release handler silently dropped nothing.
        // Returns -1 when the position is OUTSIDE the grid viewport —
        // drag-outside-to-CANCEL (S55 D1, user decision; the README has
        // always promised it). The old Math.max/min clamp pulled
        // out-of-grid releases onto the first/last cell, so dragging a
        // tile out and releasing silently reordered it to an edge cell.
        // -1 also hides the drop highlight while the tile is outside.
        function dropIndexFor(item, px, py) {
            if (apps.length === 0)
                return -1
            var vp = item.mapToItem(grid, px, py)
            if (vp.x < 0 || vp.y < 0 || vp.x >= grid.width || vp.y >= grid.height)
                return -1
            var c = Math.floor(vp.x / grid.cellWidth)
            var r = Math.floor((vp.y + grid.contentY) / grid.cellHeight)
            return Math.max(0, Math.min(apps.length - 1, r * dcols + c))
        }
            // Full-system icon inventory via one find(1): FolderListModels only
            // see a single flat dir, missing sizes, contexts and local themes.
            // Names resolve through the icon theme at use time, so pooling
            // the ACTIVE theme plus breeze + hicolor dirs is safe; cached
            // per theme, filtered locally.
            function scanIcons() {
                // S54e review #1: prefer the RESOLVER's detected theme
                // (theme-aware: kdeglobals [Icons] else the active
                // look-and-feel defaults) — the old kdeglobals grep alone
                // yields "breeze" on machines whose theme comes from the
                // L&F (Papirus here), so Papirus-only names were unpickable
                // and previews mismatched the tiles. Fallback: the old
                // detectTheme result until the resolver has run.
                const scanTheme = root.iconPathTheme !== ""
                    ? root.iconPathTheme : root.iconTheme
                if (iconScanTheme === scanTheme && allIcons.length > 0) {
                    refreshIconChoices()
                    return
                }
                // Single-quoted assignment (shEscape): the theme string is
                // config data; the $T expansions below stay double-quoted
                // on purpose.
                const cmd = "T='" + shEscape(scanTheme) + "'; find /usr/share/icons/\"$T\" /usr/share/icons/breeze"
                    + " /usr/share/icons/hicolor $HOME/.local/share/icons/\"$T\""
                    + " \\( -type f -o -type l \\)"
                    + " \\( -path '*/apps/*' -o -path '*/places/*' -o -path '*/devices/*'"
                    + " -o -path '*/actions/*' \\) \\( -iname '*.svg' -o -iname '*.png' \\)"
                    + " -printf '%f\\n' 2>/dev/null"
                    + " | sed 's/\\.[^.]*$//' | sort -u"
                runCmd(cmd, (out) => {
                    const names = String(out || "").split("\n")
                        .map(s => s.trim()).filter(s => s !== "")
                    if (names.length > 0) {
                        allIcons = names
                        iconScanTheme = scanTheme
                    } else if (allIcons.length === 0) {
                        allIcons = ["folder"]
                    }
                    refreshIconChoices()
                })
            }
            function refreshIconChoices() {
                const q = iconFilter.trim().toLowerCase()
                shownIcons = q === ""
                    ? allIcons.slice(0, 150)
                    : allIcons.filter(n => n.toLowerCase().indexOf(q) >= 0).slice(0, 150)
            }

        // Custom decoration only: adapt mode uses the shell background.
        Rectangle {
            anchors.fill: parent
            visible: !themeAdapt
            radius: (cornerScale - 1) / 9 * 48
            color: customBg === "" ? Kirigami.Theme.backgroundColor : customBg
            opacity: customOpacity
            border.width: outlineScale <= 1 ? 0 : 1 + (outlineScale - 1) / 9 * 2
            border.color: withAlpha(Kirigami.Theme.highlightColor, (outlineScale - 1) / 9)
        }

        // Open ramp — WALL-CLOCK driven (16ms Timer), not an animation.
        // The popup window's ANIMATION clock stalls around map (S45 rig:
        // panel-engine timers tick through the exact same window), and the
        // visibility-flip starter wins every open in practice (112/112
        // traced starts, S53) — so a NumberAnimation started there froze
        // mid-ramp for the stall's duration: frozen half-states, then a
        // jump when its clock woke = the "hatched"/two-step open; a long
        // stall = the "very slow" open. A Timer fires from the main event
        // loop: openProgress advances on wall time regardless of the
        // window's render clock, so a stalled presentation SKIPS ahead
        // instead of freezing — the failure mode degrades to a clean
        // end-state pop (the "most of the time good" path). Curve and
        // duration: OutCubic, 220ms (S56d: stretched from S41's 170ms
        // floor so the rise's travel reads as motion; keep >=170 under
        // compositor frame coalescing).
        Timer {
            id: openRamp
            interval: 16
            repeat: true
            triggeredOnStart: true
            property double t0: 0
            onTriggered: {
                var t = Math.min(1, (Date.now() - t0) / 220)
                fullRep.openProgress = 1 - Math.pow(1 - t, 3)
                if (t >= 1)
                    openRamp.stop()
            }
        }

        // Escape: back out of settings, otherwise close the folder. Window
        // scope, so it never steals Escape from an open context menu (a
        // popupType Window menu owns its own window while shown). Shortcut
        // is a QtQuick type (not Controls).
        Shortcut {
            sequence: "Escape"
            context: Qt.WindowShortcut
            onActivated: {
                if (root.showSettings)
                    root.leaveSettings()
                else
                    root.expanded = false
            }
        }

        Item {
            id: fullRep
            anchors.fill: parent
            property real openProgress: 0
            property int menuEpoch: 0
            // Cleared while the popup window is hidden. The delegates (and
            // their MouseAreas) SURVIVE close/reopen, and a popup that
            // hides under the cursor never delivers hover-leave — so
            // containsMouse stays stale-true across the reopen (this once
            // re-showed the app-name tooltip forever — the stuck-tooltip
            // bug; the tooltip was removed in S54b, but stale containsMouse
            // would still corrupt hoverScale restores on release/cancel).
            // Gating every hoverEnabled on this forces the MouseAreas to
            // drop their stale state at hide time; a fresh enter after
            // reopen behaves normally.
            property bool hoverArmed: true
            visible: true

            // NOTE: a fullRep-wide HoverHandler used to live here (the
            // S22 release detector). It is GONE: releases now come from
            // the KWin grab events, and a pointer handler layered over
            // every MouseArea is the prime suspect for the "right-click
            // does nothing" regression — pointer handlers participate in
            // event delivery and interfere with delegate MouseAreas on
            // some Qt builds. Button-state evidence still flows from the
            // tile MouseAreas and emptyMA below.

            Item {
                id: container
                anchors.fill: parent
                visible: !root.showSettings
                // S56d OPEN RISE: the content slides out from the panel
                // side — the delivering substitute for the stock shell
                // slide, which cannot present on this stack (see
                // applyShellSlide). The offset rides ITEM GEOMETRY via
                // anchor margins (fact 1's presenting class — a transform
                // translate would not present post-settle, S44) and pairs
                // with the opacity fade for the classic rise+fade. Top
                // panels rise from above; everything else (bottom = the
                // common case; floating/plasmawindowed default) rises from
                // below — out from under the panel.
                readonly property real risePx: (1 - fullRep.openProgress) * 30
                anchors.topMargin: plasmoid.location === PlasmaCore.Types.TopEdge ? 0 : risePx
                anchors.bottomMargin: plasmoid.location === PlasmaCore.Types.TopEdge ? risePx : 0
                // S54f: the open ramp's fade half (user decision against
                // the S54e bloom): icons at full size, this container's
                // opacity rides openProgress 0->1 over the wall-clock
                // openRamp. CAVEAT on
                // record: opacity is the load-dependently dropped damage
                // class (fact 1) — on an idle desktop it presents every
                // frame (S54a videos), under churn it can degrade to
                // empty-then-pop; that failure mode is milder than the old
                // hatched wrong-sized states. The rise (geometry) carries
                // the motion even when the fade half drops. The truly
                // bulletproof option is no animation at all (icons appear
                // at map).
                opacity: fullRep.openProgress
                GridView {
                    id: grid
                    anchors.fill: parent
                    cellWidth: root.tile
                    cellHeight: root.tile
                    clip: true
                    model: root.apps
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: false
                    reuseItems: true
                    Behavior on contentY {
                        NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
                    }
                    keyNavigationEnabled: true
                    highlightFollowsCurrentItem: true
                    focus: true

                    delegate: Item {
                        id: tileItem
                        required property var model
                        required property int index
                        width: root.tile
                        height: root.tile

                        property bool maybeDrag: false
                        property bool reorderDrag: false
                        property bool suppressClick: false
                        property real dragDX: 0
                        property real dragDY: 0
                        property point pressPos: Qt.point(0, 0)
                        // Hover feedback multiplies the icon's SIZE, not its
                        // scale transform: on this Qt stack the popup window
                        // stops presenting transform/opacity damage once the
                        // open settles (rig-proven 2026-09-21 — a scale write
                        // animates the property but never reaches the screen,
                        // on the icon itself or its parent, layer on or off,
                        // while a width/height change presents immediately).
                        property real hoverScale: 1

                        // S54d: request the icon FILE for this tile's themed
                        // name OUTSIDE any binding (a request from inside the
                        // source binding mutates resolver state the binding
                        // would then depend on = Qt binding loop). Deduped by
                        // the resolver's pending set; the onAppsChanged
                        // prefetch usually resolves this before the popup
                        // ever opens.
                        Component.onCompleted: {
                            var n = model.modelData.icon || ""
                            if (n === "")
                                n = "application-x-executable"
                            if (n.charAt(0) !== "/")
                                root.requestIconPath(n)
                        }

                        Item {
                            id: dragLayer
                            width: parent.width
                            height: parent.height
                            x: tileItem.dragDX
                            y: tileItem.dragDY
                            z: tileItem.reorderDrag ? 5 : 0
                        Image {
                            id: icon
                            anchors.centerIn: parent
                            // S54a/S54b fix: raster ONCE at a fixed size and
                            // animate only item geometry over the constant
                            // texture. Kirigami.Icon's async size-raster was
                            // the bug (S54a video, frame-measured at 57fps:
                            // item geometry animated but the painted bitmap
                            // either never re-rasterized — flame parked at
                            // the idle size through 600ms hovers — or
                            // presented wrong-sized single frames; the
                            // inflated raster NEVER appeared). S54b rig
                            // (fresh-id packages, real panel popup, pixel
                            // bbox per frame) caught the mechanism: the
                            // Kirigami/icon-engine raster path quantizes to
                            // Qt standard buckets (16/22/32/48/64/96/128)
                            // and paints the bucket 1:1 — a 44-logical icon
                            // snapped 64->96 device px, a 1.5x "size lock",
                            // no tween. The plain Image + explicit
                            // sourceSize path does not quantize: rig-measured
                            // 82/98 px idle/inflated (predicted 82.5/97.3),
                            // continuous mid-tween frames incl. the OutBack
                            // overshoot peak (99), zero wrong sizes at both
                            // 180ms and 1200ms. The fixed-size icon-pair
                            // fallback was rig-rejected (same buckets).
                            width: root.tileIcon * tileItem.hoverScale
                            height: width
                                // S54d: themed icon NAMES must resolve to real
                            // icon files — see the icon-resolution block at
                            // root (plain Image has no theme support and the
                            // image://icon provider is not registered in the
                            // applet engine; every such URL renders NOTHING).
                            // Paths from .desktop Icon= entries go straight
                            // to file://. While a name resolves (one batched
                            // fork per new icon set, prefetched at
                            // apps-load), the tile paints nothing briefly.
                            // Keep this binding PURE: no imperative source
                            // writes (the S54b onStatusChanged fallback
                            // unbound this property on its first error).
                            source: {
                                // PURE binding: reads ONLY iconPathCache (+
                                // model data). The resolution REQUEST must
                                // never happen here — it mutates pending-set
                                // state that the binding would then depend on
                                // (Qt binding loop, live-proven 2026-09-25);
                                // the delegate requests from
                                // Component.onCompleted instead.
                                var n = model.modelData.icon || ""
                                if (n === "")
                                    n = "application-x-executable"
                                if (n.charAt(0) === "/")
                                    return fileUrl(n)
                                var p = root.iconPathCache[n]
                                if (p !== undefined && p !== "")
                                    return fileUrl(p)
                                return ""
                            }
                            // FRACTIONAL animated sizes stay (S51 platform
                            // fact: integer-stepped sizes get coalesced;
                            // continuous fractional geometry presents every
                            // frame). sourceSize is a one-time load constant,
                            // never animated, so rounding it is safe. Factor
                            // 1.25 covers the drag inflate (hoverScale 1.25
                            // > hover 1.18 + OutBack overshoot); the DPR
                            // factor keeps the constant texture DOWNSCALED
                            // to the item, never upscaled (crisp on 2x).
                            sourceSize: Qt.size(
                                Math.ceil(root.tileIcon * 1.25 * Screen.devicePixelRatio),
                                Math.ceil(root.tileIcon * 1.25 * Screen.devicePixelRatio))
                            fillMode: Image.PreserveAspectFit
                        }
                        }

                        Behavior on hoverScale {
                            // Spring FEEL on a spring-SAFE curve (S53). The
                            // original was SpringAnimation on scale (spring 6
                            // / damping 0.42 / 180ms — preserved verbatim at
                            // git 9472359~1 for restoration on the SCALE
                            // channel after the Qt stack fix). Two stack facts
                            // forced the channel change (transform damage
                            // never presents, S44) and the curve change: on
                            // the size channel the spring's post-settle
                            // sub-epsilon corrections each re-rasterize the
                            // SVG icon — the sweep flicker (user-confirmed
                            // S49/S50). OutBack reproduces the spring's
                            // snappy attack and overshoot bounce but
                            // TERMINATES exactly at duration: no tail, no
                            // re-raster storm, values stay fractional
                            // (presents every frame, S48/S51). Overshoot 2.0
                            // ~ 13% of the delta: a ~1px bounce on a 48px
                            // icon, symmetric on inflate/deflate. Feel knob:
                            // overshoot (0.8 ~= the original spring's observed
                            // ~2%; 1.70158 = Qt default).
                            NumberAnimation {
                                duration: 180
                                easing.type: Easing.OutBack
                                easing.overshoot: 2.0
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 6
                            radius: 10
                            color: "transparent"
                            border.width: 2
                            border.color: Kirigami.Theme.highlightColor
                            visible: dropTarget !== -1 && dropTarget === tileItem.index
                                && dragSource !== tileItem.index
                        }

                        Connections {
                            target: fullRep
                            // (A fullRep.onVisibleChanged handler lived here
                            // until S55 — dead code: fullRep.visible is a
                            // literal true, so the signal never fired.
                            // menuEpoch is the live close-all path.)
                            function onMenuEpochChanged() {
                                removeMenu.close()
                            }
                            function onHoverArmedChanged() {
                                // ANY hoverArmed flip (disarm at collapse and
                                // re-arm at expand) invalidates hover state:
                                // containsMouse never updates while the popup
                                // is hidden, so stale-true hover state must
                                // never survive a reopen (the stuck-tooltip
                                // era, S48; the tooltip itself is gone since
                                // S54b, but hoverScale restores still read
                                // containsMouse and must not see stale it).
                                if (!fullRep.hoverArmed)
                                    tileItem.hoverScale = 1
                            }
                        }

                        // S46: a SECOND hover receptor on the tile, on the
                        // pointer-handler delivery path (passive grab — it
                        // observes without competing with the MouseArea's
                        // clicks). The 09-22 16:40 trace proved hover events
                        // reach the popup (bg enter, armed=true) while the
                        // delegates' MouseArea never fires an enter; if the
                        // MouseArea path is what is broken, this handler
                        // still tracks and DRIVES the inflate (the tooltip
                        // it once also drove was removed in S54b).
                        HoverHandler {
                            id: hh
                            onHoveredChanged: {
                                if (!fullRep.hoverArmed)
                                    return
                                if (!tileItem.reorderDrag)
                                    tileItem.hoverScale = hovered ? 1.18 : 1
                            }
                        }

                        MouseArea {
                            id: ma
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            hoverEnabled: fullRep.hoverArmed

                            onEntered: {
                                root.trace("tile enter idx=" + tileItem.index
                                           + " hs=" + tileItem.hoverScale.toFixed(2)
                                           + " w=" + icon.width.toFixed(1)
                                           + " rd=" + tileItem.reorderDrag
                                           + " armed=" + fullRep.hoverArmed)
                                if (!tileItem.reorderDrag)
                                    tileItem.hoverScale = 1.18
                            }
                            onExited: {
                                root.trace("tile exit idx=" + tileItem.index
                                           + " hs=" + tileItem.hoverScale.toFixed(2)
                                           + " w=" + icon.width.toFixed(1))
                                if (!tileItem.reorderDrag && !hh.hovered)
                                    tileItem.hoverScale = 1
                            }

                            onPressed: (mouse) => {
                                if (mouse.button === Qt.RightButton)
                                    root.trace("tile press R")
                                if (mouse.button === Qt.LeftButton) {
                                    tileItem.maybeDrag = true
                                    tileItem.pressPos = Qt.point(mouse.x, mouse.y)
                                    tileItem.hoverScale = 0.9
                                }
                            }

                            onPositionChanged: (mouse) => {
                                root.pointerWake(mouse.buttons !== 0)
                                if (!tileItem.maybeDrag)
                                    return
                                if (!tileItem.reorderDrag) {
                                    var d = Math.hypot(mouse.x - tileItem.pressPos.x,
                                                       mouse.y - tileItem.pressPos.y)
                                    if (d < 12)
                                        return
                                    tileItem.reorderDrag = true
                                    dragSource = tileItem.index
                                    tileItem.hoverScale = 1.25
                                }
                                tileItem.dragDX = mouse.x - tileItem.pressPos.x
                                tileItem.dragDY = mouse.y - tileItem.pressPos.y
                                dropTarget = dropIndexFor(tileItem, mouse.x, mouse.y)
                            }

                            onReleased: (mouse) => {
                                tileItem.maybeDrag = false
                                if (!tileItem.reorderDrag) {
                                    tileItem.hoverScale = ma.containsMouse ? 1.18 : 1
                                    return
                                }
                                tileItem.reorderDrag = false
                                var s = dragSource
                                var t = dropTarget
                                tileItem.dragDX = 0
                                tileItem.dragDY = 0
                                tileItem.hoverScale = ma.containsMouse ? 1.18 : 1
                                dragSource = -1
                                dropTarget = -1
                                tileItem.suppressClick = true
                                // No t-1 adjustment: move() splices out first,
                                // so `to` already addresses the pointed cell.
                                if (t !== -1 && t !== s)
                                    root.move(s, t)
                            }

                            onCanceled: {
                                tileItem.maybeDrag = false
                                tileItem.reorderDrag = false
                                tileItem.dragDX = 0
                                tileItem.dragDY = 0
                                if (!hh.hovered)
                                    tileItem.hoverScale = 1
                                dragSource = -1
                                dropTarget = -1
                            }

                            onClicked: (mouse) => {
                                if (tileItem.suppressClick) {
                                    tileItem.suppressClick = false
                                    return
                                }
                                if (mouse.button === Qt.LeftButton) {
                                    root.launchApp(model.modelData.desktop)
                                    root.expanded = false
                                } else {
                                    root.trace("tile click R -> tileMenu")
                                    removeMenu.openAt(tileItem, index, mouse.x, mouse.y)
                                }
                            }
                        }
                        // App-name tooltip REMOVED (S54b, user decision):
                        // the in-window QQC2.ToolTip rendered at
                        // y: ma.height + 4 and physically covered the icon
                        // row below the hovered tile. Moving it below the
                        // popup frame would mean either a caption strip
                        // inside the proven S31-S44 sizing machinery or a
                        // separate window on this popup-flaky Qt stack —
                        // removal is the zero-risk option for release.

                        QQC2.Menu {
                            id: removeMenu
                            // Native window menu: an in-window QQuickPopup
                            // is CLIPPED to the folder frame (a 1-tile frame
                            // forced the menu to scroll inside it). With
                            // popupType Window the menu is its own Qt popup
                            // window — it escapes the frame, sizes to its
                            // content, clamps to the screen, and the shell
                            // counts Qt::Popup focus as child focus, so the
                            // folder survives the menu being open (menuGuard
                            // is the belt-and-braces for that).
                            popupType: QQC2.Popup.Window
                            onAboutToShow: root.menuGuard = true
                            // aboutToHide, not only onClosed: when the folder
                            // popup window is torn down mid-menu, closed
                            // never fires and the guard latched forever —
                            // which kept hideOnWindowDeactivate false and
                            // was the "folder never closes anymore" wedge.
                            onAboutToHide: root.menuGuard = false
                            onClosed: root.menuGuard = false
                            function openAt(item, idx, px, py) {
                                trace("tileMenu open")
                                removeAction.index = idx
                                // At the cursor via the shared anchor (see
                                // menuAnchor; popup(item,x,y) drops x/y on
                                // Window-type menus).
                                var pt = item.mapToItem(grid, px, py)
                                menuAnchor.x = pt.x
                                menuAnchor.y = pt.y
                                popup(menuAnchor)
                            }
                            QQC2.MenuItem {
                                id: removeAction
                                property int index: -1
                                text: qsTr("Remove from folder")
                                onTriggered: root.removeAt(index)
                            }
                            QQC2.MenuItem {
                                text: qsTr("Add app…")
                                onTriggered: picker.open()
                            }
                            QQC2.MenuItem {
                                text: qsTr("Keep open")
                                checkable: true
                                checked: root.pinned
                                onTriggered: root.pinned = checked
                            }
                            QQC2.MenuItem {
                                text: qsTr("Folder settings…")
                                onTriggered: root.openSettings()
                            }
                        }

                        DropArea {
                            anchors.fill: parent
                            onDropped: (drop) => root.handleDrop(drop)
                        }
                    }

                    QQC2.Label {
                        anchors.centerIn: parent
                        visible: grid.count === 0
                        text: qsTr("Drop apps here")
                        color: Kirigami.Theme.disabledTextColor
                        font: Kirigami.Theme.smallFont
                    }

                    DropArea {
                        id: gridDrop
                        anchors.fill: parent
                        onDropped: (drop) => { root.handleDrop(drop) }
                    }

                    MouseArea {
                        id: emptyMA
                        anchors.fill: parent
                        acceptedButtons: Qt.RightButton
                        // NO hover on the background surface (THE hover fix,
                        // proven live 2026-09-22 S47): emptyMA is stacked
                        // ABOVE the delegates and covers the whole grid, and
                        // with hover enabled it swallowed tile hover delivery
                        // entirely on this Qt build (topmost-acceptor rule)
                        // — no tile enter, no inflate, no tooltip, for days.
                        // With it off, tiles receive hover normally. Presses
                        // (right-click menu) are unaffected: hoverEnabled
                        // only gates hover events. emptyMA still forwards
                        // pointer motion to pointerWake (onPositionChanged
                        // below) — what died with hoverEnabled was only the
                        // old bg-enter/exit SENSOR role, not the wake
                        // machinery.
                        hoverEnabled: false
                        onPressed: (mouse) => {
                            root.trace("bgma press")
                            // indexAt takes CONTENT coords: add contentY, or
                            // a paged folder (contentY > 0) resolves the hit
                            // against page 0 and an empty cell on the last
                            // page reads as occupied — the folder menu never
                            // opened there (S55).
                            if (grid.indexAt(mouse.x, mouse.y + grid.contentY) !== -1)
                                mouse.accepted = false
                        }
                        onPositionChanged: (mouse) =>
                            root.pointerWake(mouse.buttons !== 0)
                        onClicked: (mouse) => {
                            root.trace("bgma click -> gridMenu")
                            // popup(item, x, y) IGNORES x/y for popupType
                            // Window menus on Qt 6.11 (rig-proven: both that
                            // and x/y+open() land the menu at the parent
                            // item's top-left) — the menu opens AT THE CURSOR
                            // by anchoring to a 1px invisible item moved to
                            // the click point instead.
                            menuAnchor.x = mouse.x
                            menuAnchor.y = mouse.y
                            gridMenu.popup(menuAnchor)
                        }
                        onWheel: (wheel) => {
                            var d = wheel.angleDelta.y
                            if (Math.abs(d) > 20)
                                bumpPage(d < 0 ? 1 : -1)
                        }
                    }

                    // Cursor anchor for the native-window menus: popup(item,
                    // x, y) drops x/y on Window-type popups (Qt 6.11,
                    // rig-proven), but popup(item) itself positions exactly
                    // at the item — so both menus parent to this 1px item
                    // which gets moved to the click point first.
                    Item {
                        id: menuAnchor
                        width: 1
                        height: 1
                        visible: false
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 3
                        spacing: 4
                        opacity: 0.75
                        visible: pageCount > 1
                        Repeater {
                            model: pageCount
                            Rectangle {
                                width: 6
                                height: 6
                                radius: 3
                                color: index === gridPage
                                    ? Kirigami.Theme.highlightColor
                                    : Kirigami.Theme.disabledTextColor
                            }
                        }
                    }

                    QQC2.Menu {
                        id: gridMenu
                        // Native window menu — see removeMenu above.
                        popupType: QQC2.Popup.Window
                        onAboutToShow: root.menuGuard = true
                        onAboutToHide: root.menuGuard = false
                        onClosed: root.menuGuard = false
                        QQC2.MenuItem {
                            text: qsTr("Add app…")
                            onTriggered: picker.open()
                        }
                        QQC2.MenuItem {
                            text: qsTr("Keep open")
                            checkable: true
                            checked: root.pinned
                            onTriggered: root.pinned = checked
                        }
                        QQC2.MenuItem {
                            text: qsTr("Folder settings…")
                            onTriggered: root.openSettings()
                        }
                    }
                }
            }

            // -- applet-side resize surfaces (S32) ---------------------------------
            // The shell's CSD border zones are unreliable on these popups:
            // video + diag trace show most border presses get a plain ARROW
            // cursor and no grab at all, while the applet's resize pipeline
            // (grab-start event -> live drag -> release snap) works whenever
            // a grab starts (trace S32: grab-start event, live 77->85 drag,
            // clean release snap). These strips guarantee a grabbable edge
            // with a visible resize cursor. Direction facts (proven on this
            // shell): a win.height write moves the TOP edge (popup gravity
            // is bottom — the S30 shrink re-anchored y downward), a
            // win.width write grows the RIGHT edge (the shell re-anchors x
            // per write — slight wobble mid-drag, corrected by the release
            // snap + recenter). Left/bottom keep the shell zones: writes
            // would move the wrong edge there. Presses within the strips
            // mean a real grab: grabCancel stops the machinery, pointerWake
            // marks the hold, release runs the normal snap+recenter path.
            // hoverEnabled gives the cursor feedback the shell zones lack;
            // only left-button is accepted, so right-click menus and wheel
            // page-flips at the edges pass through.
            Item {
                id: resizeSurfaces
                anchors.fill: parent
                // Dynamic resizing off: no applet-side grab surfaces.
                visible: !root.showSettings && root.dynamicResize
                z: 90
                readonly property int minW: root.tile + 8
                readonly property int minH: root.tile + 8
                readonly property int maxW: 15 * root.tile + 64
                readonly property int maxH: 15 * root.tile + 64
                property real startW: 0
                property real startH: 0
                property real startX: 0
                property real startY: 0
                function begin() {
                    var win = (fullRep && fullRep.Window) ? fullRep.Window.window : null
                    if (!win || win.width < 10)
                        return false
                    startW = win.width
                    startH = win.height
                    root.grabCancel()
                    root.pointerWake(true)
                    return true
                }
                function applyHeight(dy) {
                    var win = (fullRep && fullRep.Window) ? fullRep.Window.window : null
                    if (!win)
                        return
                    win.height = Math.max(minH, Math.min(maxH, Math.round(startH - dy)))
                }
                function applyWidth(dx) {
                    var win = (fullRep && fullRep.Window) ? fullRep.Window.window : null
                    if (!win)
                        return
                    win.width = Math.max(minW, Math.min(maxW, Math.round(startW + dx)))
                }
                MouseArea {
                    // Top edge: drag up = taller (the top edge follows the
                    // cursor via the bottom-gravity height write).
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 7
                    hoverEnabled: true
                    cursorShape: Qt.SizeVerCursor
                    onPressed: (mouse) => { if (parent.begin()) startY = mouse.y }
                    onPositionChanged: (mouse) => {
                        root.pointerWake(true)
                        if (pressed)
                            parent.applyHeight(mouse.y - startY)
                    }
                    onReleased: root.pointerWake(false)
                    onCanceled: root.pointerWake(false)
                }
                MouseArea {
                    // Right edge: drag right = wider.
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 7
                    hoverEnabled: true
                    cursorShape: Qt.SizeHorCursor
                    onPressed: (mouse) => { if (parent.begin()) startX = mouse.x }
                    onPositionChanged: (mouse) => {
                        root.pointerWake(true)
                        if (pressed)
                            parent.applyWidth(mouse.x - startX)
                    }
                    onReleased: root.pointerWake(false)
                    onCanceled: root.pointerWake(false)
                }
                MouseArea {
                    // Top-right corner: both axes at once. Declared last so
                    // it wins the corner over the two edges.
                    anchors.top: parent.top
                    anchors.right: parent.right
                    width: 14
                    height: 14
                    hoverEnabled: true
                    cursorShape: Qt.SizeBDiagCursor
                    onPressed: (mouse) => {
                        if (parent.begin()) {
                            startX = mouse.x
                            startY = mouse.y
                        }
                    }
                    onPositionChanged: (mouse) => {
                        root.pointerWake(true)
                        if (pressed) {
                            parent.applyHeight(mouse.y - startY)
                            parent.applyWidth(mouse.x - startX)
                        }
                    }
                    onReleased: root.pointerWake(false)
                    onCanceled: root.pointerWake(false)
                }
            }

            // ---- folder settings page -----------------------------------
            Item {
                id: settingsView
                anchors.fill: parent
                anchors.margins: 16
                visible: root.showSettings

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        QQC2.ToolButton {
                            icon.name: "go-previous"
                            text: qsTr("Back")
                            display: QQC2.AbstractButton.IconOnly
                            onClicked: root.leaveSettings()
                        }
                        QQC2.Label {
                            text: qsTr("Folder settings")
                            font.bold: true
                            Layout.fillWidth: true
                        }
                        Kirigami.Icon {
                            Layout.preferredWidth: 32
                            Layout.preferredHeight: 32
                            source: root.folderIconName || "folder"
                        }
                    }

                    QQC2.Label { text: qsTr("Folder icon") }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        QQC2.TextField {
                            Layout.fillWidth: true
                            placeholderText: qsTr("Search icons…")
                            text: root.iconFilter
                            onTextChanged: {
                                root.iconFilter = text
                                refreshIconChoices()
                            }
                        }
                        QQC2.Button {
                            text: qsTr("Default")
                            onClicked: root.setFolderIcon("folder")
                        }
                    }

                    GridView {
                        id: iconGrid
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumHeight: 110
                        clip: true
                        cellWidth: 56
                        cellHeight: 56
                        model: root.shownIcons
                        reuseItems: true
                        cacheBuffer: 168
                        QQC2.ScrollBar.vertical: QQC2.ScrollBar {
                            policy: QQC2.ScrollBar.AsNeeded
                        }
                        delegate: Item {
                            width: 56
                            height: 56
                            required property var model
                            required property int index
                            // Fresh-hover evidence for this picker's own
                            // tooltip (the grid tiles' tooltip was removed
                            // in S54b; this one is small and obstructs
                            // nothing inside the settings pane).
                            property bool hoverOn: false
                            Kirigami.Icon {
                                anchors.centerIn: parent
                                width: 40
                                height: 40
                                source: model.modelData
                            }
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 4
                                radius: 8
                                color: "transparent"
                                border.width: 2
                                border.color: Kirigami.Theme.highlightColor
                                visible: model.modelData === root.folderIconName
                            }
                            MouseArea {
                                id: iconMA
                                anchors.fill: parent
                                hoverEnabled: fullRep.hoverArmed
                                onEntered: hoverOn = true
                                onExited: hoverOn = false
                                onClicked: root.setFolderIcon(model.modelData)
                            }
                            QQC2.ToolTip {
                                parent: iconMA
                                visible: fullRep.hoverArmed && hoverOn
                                    && iconMA.containsMouse && !iconMA.pressed
                                text: model.modelData
                                delay: 400
                                x: Math.max(0, Math.min(iconMA.width - (implicitWidth || 0), iconMA.mouseX - (implicitWidth || 0) / 2))
                                y: iconMA.height + 4
                            }
                        }
                    }

                    QQC2.Label {
                        text: root.shownIcons.length >= 150
                            ? qsTr("First 150 matches — refine the search")
                            : qsTr("%n icon(s)", "", root.shownIcons.length)
                        color: Kirigami.Theme.disabledTextColor
                        font: Kirigami.Theme.smallFont
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        QQC2.Label {
                            text: qsTr("Icon size")
                            Layout.preferredWidth: 90
                        }
                        QQC2.Slider {
                            Layout.fillWidth: true
                            from: 1
                            to: 10
                            stepSize: 1
                            value: root.iconScale
                            // Persist on RELEASE only (S55): onMoved updates
                            // the live property (instant preview), release
                            // flushes once — a config write per gesture
                            // instead of one per drag tick (all six sliders
                            // used to write on every move).
                            onMoved: root.iconScale = Math.round(value)
                            onPressedChanged: if (!pressed) { root.persistUi(); root.trace("rel icon=" + root.iconScale + " knob=" + Math.round(value)) }
                        }
                        QQC2.Label {
                            text: root.iconScale
                            Layout.preferredWidth: 16
                            horizontalAlignment: Text.AlignRight
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        QQC2.Label {
                            text: qsTr("Icon padding")
                            Layout.preferredWidth: 90
                        }
                        QQC2.Slider {
                            Layout.fillWidth: true
                            // Floor 3 (see loadUi): below it the fixed dialog
                            // chrome makes the frame gap exceed the icon gap.
                            from: 3
                            to: 10
                            stepSize: 1
                            value: root.padScale
                            onMoved: root.padScale = Math.round(value)
                            onPressedChanged: if (!pressed) root.persistUi()
                        }
                        QQC2.Label {
                            text: root.padScale
                            Layout.preferredWidth: 16
                            horizontalAlignment: Text.AlignRight
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        QQC2.Label {
                            text: qsTr("Widget size")
                            Layout.preferredWidth: 90
                        }
                        QQC2.Slider {
                            Layout.fillWidth: true
                            from: 1
                            to: 10
                            stepSize: 1
                            value: root.compactScale
                            onMoved: root.compactScale = Math.round(value)
                            onPressedChanged: if (!pressed) { root.persistUi(); root.trace("rel widget=" + root.compactScale + " knob=" + Math.round(value)) }
                        }
                        QQC2.Label {
                            text: root.compactScale
                            Layout.preferredWidth: 16
                            horizontalAlignment: Text.AlignRight
                        }
                    }

                    // ---- checked-grid folder size (S36; history in log.md) -
                    // Hover highlights the rectangle from the A1 corner to
                    // the cursor (cols x rows of tiles); click commits. The
                    // solid outline marks the committed size; hover never
                    // commits. The frame resize itself lands on Back (the
                    // popup is pinned to settingsW/H while settings shows).
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        QQC2.Label { text: qsTr("Folder size") }
                        Item { Layout.fillWidth: true }
                        QQC2.Label {
                            text: qsTr("%1 × %2 tiles (%3×%4 px)")
                                .arg(sizePicker.selCols).arg(sizePicker.selRows)
                                .arg(sizePicker.selCols * root.tile)
                                .arg(sizePicker.selRows * root.tile)
                            color: Kirigami.Theme.disabledTextColor
                            font: Kirigami.Theme.smallFont
                        }
                    }

                    Item {
                        id: sizePicker
                        Layout.alignment: Qt.AlignHCenter
                        // 10 cells of 14px + 9 gaps of 2px = 158 (pitch 16).
                        // implicit*, never width/height: the parent
                        // ColumnLayout manages this item — explicit sizes
                        // on layout-managed items are undefined behavior
                        // (and the last two qmllint warnings).
                        implicitWidth: 158
                        implicitHeight: 158
                        property int comCols: 3
                        property int comRows: 3
                        property int selCols: 3
                        property int selRows: 3
                        // Live screen cap: N tiles must fit the screen
                        // (max tile is 100px); cells beyond the cap are
                        // dead and the hover preview clamps to it. The
                        // 40px (x) / 120px (y) slack covers dialog chrome,
                        // the panel and the page dots.
                        readonly property int capCols: Math.max(1, Math.min(10,
                            Math.floor((Screen.width - 40) / Math.max(1, root.tile))))
                        readonly property int capRows: Math.max(1, Math.min(10,
                            Math.floor((Screen.height - 120) / Math.max(1, root.tile))))
                        function applySelection() {
                            if (root.tile < 1)
                                return
                            var c = Math.max(1, Math.min(capCols, selCols))
                            var r = Math.max(1, Math.min(capRows, selRows))
                            comCols = c
                            comRows = r
                            selCols = c
                            selRows = r
                            root.snappedW = Math.min(15, c) * root.tile
                            root.snappedH = Math.min(15, r) * root.tile
                            // Back's fallback path quantizes the remembered
                            // frame; keep it in sync so the pick survives a
                            // collapse straight off the settings page too.
                            root.preSettingsW = root.snappedW
                            root.preSettingsH = root.snappedH
                            root.sizePicked = true
                            plasmoid.configuration.folderCols = c
                            plasmoid.configuration.folderRows = r
                            root.flushConfig()
                            root.trace("size-pick " + c + "x" + r)
                        }
                        Grid {
                            columns: 10
                            spacing: 2
                            Repeater {
                                model: 100
                                Rectangle {
                                    width: 14
                                    height: 14
                                    radius: 2
                                    readonly property int cCol: index % 10 + 1
                                    readonly property int cRow: Math.floor(index / 10) + 1
                                    readonly property bool dead: cCol > sizePicker.capCols
                                        || cRow > sizePicker.capRows
                                    readonly property bool inSel: cCol <= sizePicker.selCols
                                        && cRow <= sizePicker.selRows
                                    color: dead ? "transparent"
                                        : inSel ? root.withAlpha(Kirigami.Theme.highlightColor, 0.35)
                                        : root.withAlpha(Kirigami.Theme.alternateBackgroundColor, 0.45)
                                    border.width: 1
                                    border.color: root.withAlpha(Kirigami.Theme.disabledTextColor,
                                        dead ? 0.12 : 0.3)
                                }
                            }
                        }
                        // Committed-size outline over the hover preview.
                        // (Parent properties must be id-qualified here:
                        // unqualified lookup only sees the object itself
                        // and the component root, NOT intermediate parents
                        // — the bare comCols/comRows version threw
                        // ReferenceError live on the panel host.)
                        Rectangle {
                            z: 2
                            width: sizePicker.comCols * 16 - 2
                            height: sizePicker.comRows * 16 - 2
                            color: "transparent"
                            radius: 3
                            border.width: 2
                            border.color: Kirigami.Theme.highlightColor
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPositionChanged: (mouse) => {
                                sizePicker.selCols = Math.max(1,
                                    Math.min(sizePicker.capCols, Math.ceil(mouse.x / 16)))
                                sizePicker.selRows = Math.max(1,
                                    Math.min(sizePicker.capRows, Math.ceil(mouse.y / 16)))
                            }
                            onExited: {
                                sizePicker.selCols = sizePicker.comCols
                                sizePicker.selRows = sizePicker.comRows
                            }
                            onClicked: sizePicker.applySelection()
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        QQC2.Switch {
                            text: qsTr("Dynamic Resizing (beta)")
                            checked: root.dynamicResize
                            onToggled: {
                                root.dynamicResize = checked
                                root.persistUi()
                                root.trace("dynres " + (checked ? "on" : "off"))
                            }
                        }
                        QQC2.Label {
                            // Short + elided: the long form overflows into
                            // the switch text on the 380px settings width.
                            text: qsTr("Off = grid only")
                            color: Kirigami.Theme.disabledTextColor
                            font: Kirigami.Theme.smallFont
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
                        }
                    }


                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        QQC2.Switch {
                            text: qsTr("Adapt to theme")
                            checked: root.themeAdapt
                            onToggled: {
                                root.themeAdapt = checked
                                root.persistUi()
                            }
                        }
                        QQC2.Label {
                            text: qsTr("Off = custom style below")
                            color: Kirigami.Theme.disabledTextColor
                            font: Kirigami.Theme.smallFont
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignRight
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        visible: !root.themeAdapt
                        QQC2.Label {
                            text: qsTr("Color")
                            Layout.preferredWidth: 80
                        }
                        Row {
                            Layout.fillWidth: true
                            spacing: 6
                            Repeater {
                                model: [Kirigami.Theme.backgroundColor,
                                        Kirigami.Theme.highlightColor,
                                        Kirigami.Theme.textColor,
                                        "#ffffff", "#1a1a1a"]
                                Rectangle {
                                    width: 28
                                    height: 28
                                    radius: 6
                                    color: modelData
                                    border.width: 2
                                    border.color: String(root.customBg).toLowerCase() === String(modelData).toLowerCase()
                                        || (root.customBg === "" && modelData === Kirigami.Theme.backgroundColor)
                                        ? Kirigami.Theme.highlightColor : "transparent"
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: {
                                            root.customBg = String(modelData)
                                            root.persistUi()
                                        }
                                    }
                                }
                            }
                            QQC2.Button {
                                text: qsTr("Custom…")
                                onClicked: bgPicker.open()
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        visible: !root.themeAdapt
                        QQC2.Label {
                            text: qsTr("Opacity")
                            Layout.preferredWidth: 80
                        }
                        QQC2.Slider {
                            Layout.fillWidth: true
                            from: 0.2
                            to: 1
                            stepSize: 0.05
                            value: root.customOpacity
                            onMoved: root.customOpacity = value
                            onPressedChanged: if (!pressed) root.persistUi()
                        }
                        QQC2.Label {
                            text: Math.round(root.customOpacity * 100) + "%"
                            Layout.preferredWidth: 40
                            horizontalAlignment: Text.AlignRight
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        visible: !root.themeAdapt
                        QQC2.Label {
                            text: qsTr("Corners")
                            Layout.preferredWidth: 80
                        }
                        QQC2.Slider {
                            Layout.fillWidth: true
                            from: 1
                            to: 10
                            stepSize: 1
                            value: root.cornerScale
                            onMoved: root.cornerScale = Math.round(value)
                            onPressedChanged: if (!pressed) root.persistUi()
                        }
                        QQC2.Label {
                            text: root.cornerScale
                            Layout.preferredWidth: 16
                            horizontalAlignment: Text.AlignRight
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        visible: !root.themeAdapt
                        QQC2.Label {
                            text: qsTr("Outline")
                            Layout.preferredWidth: 80
                        }
                        QQC2.Slider {
                            Layout.fillWidth: true
                            from: 1
                            to: 10
                            stepSize: 1
                            value: root.outlineScale
                            onMoved: root.outlineScale = Math.round(value)
                            onPressedChanged: if (!pressed) root.persistUi()
                        }
                        QQC2.Label {
                            text: root.outlineScale
                            Layout.preferredWidth: 16
                            horizontalAlignment: Text.AlignRight
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        QQC2.Switch {
                            text: qsTr("Keep open")
                            checked: root.pinned
                            onToggled: root.pinned = checked
                        }
                        Item { Layout.fillWidth: true }
                        QQC2.Button {
                            text: qsTr("Add app…")
                            onClicked: picker.open()
                        }
                        QQC2.Button {
                            text: qsTr("Reset")
                            onClicked: {
                                root.iconScale = 6
                                root.padScale = 6
                                root.compactScale = 6
                                root.themeAdapt = true
                                root.dynamicResize = false
                                root.customBg = ""
                                root.customOpacity = 0.95
                                root.cornerScale = 6
                                root.outlineScale = 1
                                // D2 (S55, user decision): Reset also clears
                                // the committed grid pick — a reset folder
                                // falls back to dynamic size derivation and
                                // must not spring back to the stale outline.
                                plasmoid.configuration.folderCols = 0
                                plasmoid.configuration.folderRows = 0
                                root.sizePicked = false
                                root.persistUi()
                                root.setFolderIcon("folder")
                            }
                        }
                    }
                }
            }

            Dialogs.FileDialog {
                id: picker
                title: qsTr("Add apps to folder")
                fileMode: Dialogs.FileDialog.OpenFiles
                nameFilters: [qsTr("Desktop files (*.desktop)"), qsTr("All files (*)")]
                currentFolder: "file:///usr/share/applications"
                onAccepted: {
                    // Multi-select: add every chosen file (skip non-files).
                    const files = picker.selectedFiles
                    for (let i = 0; i < files.length; i++) {
                        const local = root.localPath(files[i].toString())
                        if (local)
                            root.addApp(local)
                    }
                }
            }

            Dialogs.ColorDialog {
                id: bgPicker
                title: qsTr("Folder background color")
                selectedColor: root.customBg === "" ? Kirigami.Theme.backgroundColor : root.customBg
                onAccepted: {
                    root.customBg = selectedColor.toString()
                    root.persistUi()
                }
            }
        }


        onVisibleChanged: {
            trace("visible " + visible)
            if (!visible) {
            // Stop the ramp but do NOT zero openProgress: an instant
            // 1->0 jump crushed the content to a 60%-scale band at the
            // frame bottom (the close "squash"). The next open re-arms
            // from 0 anyway (armOpenAnim at the expand flip).
            openRamp.stop()
                fullRep.hoverArmed = false
                gridMenu.close()
                root.showSettings = false
                dragSource = -1
                dropTarget = -1
                closeAllMenus()
            } else {
                // Always land on the grid on open: the close-flip above is
                // unreliable on some hosts, which left reopen stuck in settings.
                root.showSettings = false
                dragSource = -1
                dropTarget = -1
                closeAllMenus()
                fullRep.hoverArmed = true
                root.loadUi()
                root.loadApps()
                // Hosts where this flip DOES fire (plasmawindowed): arm and
                // start in one go — the render gate may already have passed.
                // LATENT (S55 T-LE1, comment-only by decision): on the PANEL
                // host this signal never fires (proven since S29); if a
                // future Qt changed that, the immediate start here would
                // precede first presentation and resurrect the two-step
                // open. Re-verify the "never fires on panel host" fact after
                // any Qt stack upgrade.
                armOpenAnim()
                startOpenAnim()
            }
        }
    }
}
