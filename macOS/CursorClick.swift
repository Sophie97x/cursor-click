import SwiftUI
import AppKit

@MainActor
final class Clicker: ObservableObject {
    @Published var pauseMilliseconds = 50
    @Published var continuous = true
    @Published var count = 10
    @Published var variation = true
    @Published var pressSpace = true
    @Published var pressLetters = true
    @Published var running = false
    @Published var message = "Ready"
    func start() {
        guard !running else { return }
        let duration = Double(max(10, min(pauseMilliseconds, 60_000))) / 1000
        let clickCount = max(1, min(count, 1000))
        let randomTiming = variation
        let includeSpace = pressSpace
        let limit = continuous ? 0 : clickCount
        let source = """
        #!/bin/zsh
        trap 'touch -- "$0.done"' EXIT
        /usr/bin/swift - \(duration) \(limit) \(randomTiming ? 1 : 0) \(includeSpace ? 1 : 0) \(pressLetters ? 1 : 0) "\(BrowserRefreshGate.pauseFile.path)" "$0.status" <<'SWIFT'
        import AppKit
        import CoreGraphics
        import Darwin
        import Carbon

        let args = Array(CommandLine.arguments.dropFirst())
        let interval = Double(args[0]) ?? 1
        let limit = Int(args[1]) ?? 0
        let vary = args[2] == "1"
        let pressSpace = args[3] == "1"
        let pressLetters = args[4] == "1"
        let gatePath = args[5]
        let statusURL = URL(fileURLWithPath: args[6])
        @Sendable func reportStop(_ reason: String) {
            print(reason)
            try? reason.write(to: statusURL, atomically: true, encoding: .utf8)
        }
        let busyPath = URL(fileURLWithPath: gatePath).deletingLastPathComponent()
            .appendingPathComponent("clicker-busy").path
        let letterKeys: [CGKeyCode] = [0, 11, 8, 2, 14, 3, 5] // A, B, C, D, E, F, G

        guard CGPreflightPostEventAccess() else {
            reportStop("Terminal needs Accessibility permission to click.")
            exit(1)
        }

        let stopped = DispatchSemaphore(value: 0)
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { stopped.signal() }
        interrupt.resume()

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
            print("Global Control-C unavailable. Press Control-C in Terminal to stop.")
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
                print("Starting in \\(second)s")
                fflush(stdout)
                if stopped.wait(timeout: .now() + 1) == .success { return }
            }

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
                    fputs("Could not create mouse events.\\n", stderr)
                    exit(1)
                }
                guard stillOnTarget(point) else {
                    guard waitForTarget() else { return }
                    continue
                }
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
                            fputs("Could not create keyboard events.\\n", stderr)
                            exit(1)
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
            print("Stopped after \\(completed) clicks.")
        }

        DispatchQueue.global(qos: .userInitiated).async {
            runClicker()
            exit(0)
        }
        NSApplication.shared.run()
        SWIFT
        """
        do {
            let scriptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("CursorClick-\(UUID().uuidString).command")
            try source.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                message = "Could not find Terminal."
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            running = true
            NSWorkspace.shared.open([scriptURL], withApplicationAt: terminalURL,
                                    configuration: configuration) { _, error in
                if let error {
                    try? error.localizedDescription.write(to: scriptURL.appendingPathExtension("status"),
                                                          atomically: true, encoding: .utf8)
                    _ = FileManager.default.createFile(atPath: scriptURL.appendingPathExtension("done").path,
                                                       contents: nil)
                }
            }
            message = "Press Control-C anywhere to stop."
            let doneURL = scriptURL.appendingPathExtension("done")
            Task {
                while !FileManager.default.fileExists(atPath: doneURL.path) {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                try? FileManager.default.removeItem(at: doneURL)
                try? FileManager.default.removeItem(at: scriptURL)
                running = false
                let statusURL = scriptURL.appendingPathExtension("status")
                message = (try? String(contentsOf: statusURL, encoding: .utf8)) ?? "Stopped."
                try? FileManager.default.removeItem(at: statusURL)
            }
        } catch {
            message = "Could not start Terminal clicker. \(error.localizedDescription)"
        }
    }

    func stop() {
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: terminalURL, configuration: NSWorkspace.OpenConfiguration())
        }
        message = "Press Control-C in Terminal to stop."
    }
}

struct ClickerView: View {
    @StateObject private var clicker = Clicker()
    private let mint = Color(red: 0.65, green: 0.98, blue: 0.79)
    private let panel = Color(red: 0.11, green: 0.15, blue: 0.14)

    private var runStatus: String {
        clicker.running ? "Running in Terminal" : "Ready"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "cursorarrow.click")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(mint)
                    .frame(width: 50, height: 50)
                    .background(mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto Clicker").font(.system(size: 29, weight: .semibold))
                    Text("Stops if the target window changes")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 15) {
                Stepper(value: $clicker.pauseMilliseconds, in: 10...60_000, step: 10) {
                    HStack {
                        Text("Pause between clicks")
                        Spacer()
                        Text((Double(clicker.pauseMilliseconds) / 1000).formatted(.number.precision(.fractionLength(2))) + " s")
                            .monospacedDigit().foregroundStyle(mint)
                    }
                }
                Divider()
                Toggle("Run until stopped", isOn: $clicker.continuous)
                    .toggleStyle(.switch)
                    .tint(mint)
                if !clicker.continuous {
                    Stepper(value: $clicker.count, in: 1...1000, step: 1) {
                        HStack {
                            Text("Click count")
                            Spacer()
                            Text(clicker.count.formatted()).monospacedDigit().foregroundStyle(mint)
                        }
                    }
                }
                Divider()
                Toggle("Vary click timing", isOn: $clicker.variation)
                    .toggleStyle(.switch)
                    .tint(mint)
                Divider()
                Toggle("Type A–G after each click", isOn: $clicker.pressLetters)
                    .toggleStyle(.switch)
                    .tint(mint)
                Toggle("Press Space with each click", isOn: $clicker.pressSpace)
                    .toggleStyle(.switch)
                    .tint(mint)
            }
            .padding(16)
            .background(panel, in: RoundedRectangle(cornerRadius: 16))
            .disabled(clicker.running)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle().fill(clicker.running ? mint : .secondary).frame(width: 7, height: 7)
                    Text(clicker.message)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if clicker.running {
                        Text(runStatus)
                            .foregroundStyle(mint)
                    }
                }
            }
            .foregroundStyle(.secondary)
            .font(.system(size: 12))

            Button {
                if clicker.running { clicker.stop() } else { clicker.start() }
            } label: {
                Label(clicker.running ? "Stop in Terminal" : "Start clicking",
                      systemImage: clicker.running ? "stop.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .foregroundStyle(Color.black)
                    .background(
                        clicker.running ? Color(red: 0.99, green: 0.67, blue: 0.60) : mint,
                        in: RoundedRectangle(cornerRadius: 11)
                    )
            }
            .buttonStyle(.plain)

        }
        .padding(24)
        .frame(width: 410)
        .background(Color(red: 0.06, green: 0.09, blue: 0.08))
        .preferredColorScheme(.dark)
    }
}

private struct DashboardView: View {
    @StateObject private var clickerPanel = ClickerPanel()

    var body: some View {
        HStack(spacing: 0) {
            BrowserAutomationView()
            if clickerPanel.isVisible {
                Divider()
            }
            ScrollView {
                ClickerView()
            }
            .frame(width: clickerPanel.isVisible ? 410 : 0)
            .clipped()
            .accessibilityHidden(!clickerPanel.isVisible)
            .allowsHitTesting(clickerPanel.isVisible)
        }
        .toolbar {
            Button {
                clickerPanel.isVisible.toggle()
            } label: {
                Label(clickerPanel.isVisible ? "Hide Auto Clicker" : "Show Auto Clicker",
                      systemImage: "cursorarrow.click")
            }
        }
        .preferredColorScheme(.dark)
    }
}

private final class ClickerPanel: ObservableObject {
    @Published var isVisible = true
}

@main
struct CursorClickApp: App {
    var body: some Scene {
        Window("Cursor Click", id: "main") {
            DashboardView()
        }
        .defaultSize(width: 1280, height: 760)
    }
}
