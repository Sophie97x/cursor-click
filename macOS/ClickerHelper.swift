import AppKit
import CoreGraphics
import Darwin
import Carbon

func runClickerHelper(_ args: [String]) {
    guard args.count == 9, let ownerPID = pid_t(args[8]), ownerPID > 1 else { exit(2) }
    let interval = Double(args[0]) ?? 1
    let limit = Int(args[1]) ?? 0
    let vary = args[2] == "1"
    let pressSpace = args[3] == "1"
    let pressLetters = args[4] == "1"
    let gatePath = args[5]
    let statusURL = URL(fileURLWithPath: args[6])
    let stopRequestPath = args[7]
    let countdownURL = statusURL.appendingPathExtension("countdown")
    @Sendable func reportCountdown(_ second: Int) {
        try? String(second).write(to: countdownURL, atomically: true, encoding: .utf8)
    }
    @Sendable func reportStop(_ reason: String) {
        print(reason)
        try? reason.write(to: statusURL, atomically: true, encoding: .utf8)
    }
    let busyPath = URL(fileURLWithPath: gatePath).deletingLastPathComponent()
        .appendingPathComponent("clicker-busy").path
    let letterKeys: [CGKeyCode] = [0, 11, 8, 2, 14, 3, 5] // A, B, C, D, E, F, G

    guard CGPreflightPostEventAccess() else {
        reportStop("Allow Terminal in System Settings → Privacy & Security → Accessibility, then restart the clicker.")
        exit(EX_NOPERM)
    }

    let stopped = DispatchSemaphore(value: 0)
    let stopSignals = [SIGINT, SIGHUP].map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler { stopped.signal() }
        source.resume()
        return source
    }
    defer { stopSignals.forEach { $0.cancel() } }

    NSApplication.shared.setActivationPolicy(.accessory)
    var stopHotKey: EventHotKeyRef?
    var hotKeyEvent = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                   eventKind: UInt32(kEventHotKeyPressed))
    let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
        guard let context else { return OSStatus(eventNotHandledErr) }
        Unmanaged<DispatchSemaphore>.fromOpaque(context).takeUnretainedValue().signal()
        return noErr
    }, 1, &hotKeyEvent, Unmanaged.passUnretained(stopped).toOpaque(), nil)
    if handlerStatus == noErr {
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey),
                            EventHotKeyID(signature: 0x43757273, id: 1),
                            GetApplicationEventTarget(), 0, &stopHotKey)
    }
    if stopHotKey == nil {
        print("Global Control-C unavailable. Use Stop clicking or press Control-C in Terminal.")
    }

    struct WindowTarget: Equatable {
        let id: UInt32
        let pid: pid_t
    }

    @Sendable func windowTarget(at point: CGPoint, requireFocus: Bool = true) -> WindowTarget? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.contains(point),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownerPID,
                  let owner = NSRunningApplication(processIdentifier: pid),
                  owner.bundleIdentifier != "com.apple.Terminal",
                  owner.bundleIdentifier != "local.cursorclick.app",
                  !requireFocus || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let id = window[kCGWindowNumber as String] as? UInt32 else { return nil }
            return WindowTarget(id: id, pid: pid)
        }
        return nil
    }

    func runClicker() {
        print("Move the pointer over the visible target window. Starting in 5 seconds. Press Control-C to stop.")
        fflush(stdout)
        for second in stride(from: 5, through: 1, by: -1) {
            reportCountdown(second)
            print("Starting in \(second)s")
            fflush(stdout)
            if stopped.wait(timeout: .now() + 1) == .success { return }
        }
        reportCountdown(0)

        guard let initial = CGEvent(source: nil)?.location,
              let target = windowTarget(at: initial, requireFocus: false) else {
            reportStop("Stopped: no eligible window was under the pointer at the end of the countdown.")
            return
        }

        func stillOnTarget(_ point: CGPoint? = CGEvent(source: nil)?.location) -> Bool {
            if let point, windowTarget(at: point) == target { return true }
            return false
        }

        func waitForTarget() -> Bool {
            for _ in 0..<15 {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
                      let windows = CGWindowListCopyWindowInfo(
                        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
                      ) as? [[String: Any]],
                      windows.contains(where: {
                          ($0[kCGWindowNumber as String] as? UInt32) == target.id &&
                          ($0[kCGWindowOwnerPID as String] as? pid_t) == target.pid
                      }) else {
                    reportStop("Stopped: the target window closed, was minimized, or lost focus.")
                    return false
                }
                if stillOnTarget() { return true }
                if stopped.wait(timeout: .now() + 0.05) == .success { return false }
            }
            reportStop("Stopped: the target window stayed covered or the pointer moved off it.")
            return false
        }

        if !stillOnTarget() {
            DispatchQueue.main.sync {
                _ = NSRunningApplication(processIdentifier: target.pid)?.activate()
            }
            for _ in 0..<20 {
                if stillOnTarget() { break }
                if stopped.wait(timeout: .now() + 0.05) == .success { return }
            }
            guard stillOnTarget() else {
                reportStop("Stopped: the selected window could not be brought to the front.")
                return
            }
        }

        var completed = 0
        var nextDelay = 0.0
        var pausedForRefresh = false
        while stopped.wait(timeout: .now() + nextDelay) == .timedOut {
            nextDelay = 0
            let busy = open(busyPath, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard busy >= 0 else {
                reportStop("Stopped: the browser refresh input guard was unavailable.")
                return
            }
            close(busy)
            defer { unlink(busyPath) }
            if FileManager.default.fileExists(atPath: gatePath) {
                if (try? String(contentsOfFile: gatePath, encoding: .utf8)) == "failed" {
                    reportStop("Stopped: browser tabs failed to refresh.")
                    return
                }
                if !pausedForRefresh { print("Paused for browser tab refresh.") }
                pausedForRefresh = true
                nextDelay = 0.1
                continue
            }
            if pausedForRefresh { print("Browser tab refresh finished.") }
            pausedForRefresh = false
            guard let point = CGEvent(source: nil)?.location,
                  let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                     mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                   mouseCursorPosition: point, mouseButton: .left) else {
                reportStop("Stopped: could not create mouse events.")
                return
            }
            guard stillOnTarget(point) else {
                guard waitForTarget() else { return }
                continue
            }
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            down.post(tap: .cghidEventTap)
            let sendSpace = pressSpace && stillOnTarget()
            if sendSpace,
               let spaceDown = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true) {
                spaceDown.post(tap: .cghidEventTap)
            }
            let hold = min(interval / 2, vary ? Double.random(in: 0.04...0.09) : 0.06)
            let stopDuringPress = stopped.wait(timeout: .now() + hold) == .success
            up.post(tap: .cghidEventTap)
            if sendSpace,
               let spaceUp = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false) {
                spaceUp.post(tap: .cghidEventTap)
            }
            completed += 1
            if stopDuringPress { break }
            guard stillOnTarget() else {
                guard waitForTarget() else { return }
                if limit > 0 && completed >= limit { break }
                continue
            }
            if pressLetters {
                for key in letterKeys {
                    if stopped.wait(timeout: .now()) == .success { return }
                    guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
                          let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else {
                        reportStop("Stopped: could not create keyboard events.")
                        return
                    }
                    guard stillOnTarget() else {
                        guard waitForTarget() else { return }
                        break
                    }
                    keyDown.post(tap: .cghidEventTap)
                    let stoppedDuringKey = stopped.wait(timeout: .now() + 0.02) == .success
                    keyUp.post(tap: .cghidEventTap)
                    if stoppedDuringKey { return }
                    if key != letterKeys.last,
                       stopped.wait(timeout: .now() + 0.02) == .success { return }
                }
            }
            if limit > 0 && completed >= limit { break }
            nextDelay = vary ? interval * Double.random(in: 0.85...1.15) : interval
        }
        reportStop("Sent \(completed) clicks.")
    }

    let stopTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    stopTimer.schedule(deadline: .now(), repeating: .milliseconds(100))
    stopTimer.setEventHandler {
        if FileManager.default.fileExists(atPath: stopRequestPath) ||
            (kill(ownerPID, 0) != 0 && errno == ESRCH) {
            stopped.signal()
        }
    }
    stopTimer.resume()
    defer { stopTimer.cancel() }
    DispatchQueue.global(qos: .userInitiated).async {
        runClicker()
        exit(0)
    }
    NSApplication.shared.run()
}
