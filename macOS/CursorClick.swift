import SwiftUI
import AppKit
import Darwin

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
    @Published private(set) var needsAccessibility = false
    @Published private(set) var countdown: Int?
    private var stopRequest: URL?
    private let countdownPanel = CountdownPanel()

    func start() {
        guard !running else { return }
        guard let helper = Bundle.main.url(forResource: "TerminalClicker", withExtension: "swift"),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            message = "Could not find Terminal or its clicker helper."
            return
        }

        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("CursorClick-\(UUID().uuidString)")
        let command = directory.appendingPathComponent("Start Clicker.command")
        let statusFile = directory.appendingPathComponent("status")
        let countdownFile = statusFile.appendingPathExtension("countdown")
        let done = directory.appendingPathComponent("done")
        let stop = directory.appendingPathComponent("stop")
        let duration = Double(max(10, min(pauseMilliseconds, 60_000))) / 1000
        let limit = continuous ? 0 : max(1, min(count, 1000))
        let arguments = [
            helper.path, String(duration), String(limit),
            variation ? "1" : "0", pressSpace ? "1" : "0", pressLetters ? "1" : "0",
            BrowserRefreshGate.pauseFile.path, statusFile.path, stop.path,
            String(ProcessInfo.processInfo.processIdentifier)
        ].map(Self.shellQuote).joined(separator: " ")
        let script = """
        #!/bin/zsh
        done_file=\(Self.shellQuote(done.path))
        trap 'result=$?; /usr/bin/printf "%s" "$result" > "$done_file.tmp"; /bin/mv -f "$done_file.tmp" "$done_file"' EXIT
        /usr/bin/swift \(arguments)
        """
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
            try script.write(to: command, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        } catch {
            try? files.removeItem(at: directory)
            message = "Could not prepare Terminal clicker. \(error.localizedDescription)"
            return
        }

        stopRequest = stop
        running = true
        needsAccessibility = false
        message = "Starting the Terminal runner…"
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([command], withApplicationAt: terminal, configuration: configuration) { _, error in
            guard let error else { return }
            try? error.localizedDescription.write(to: statusFile, atomically: true, encoding: .utf8)
            try? "1".write(to: done, atomically: true, encoding: .utf8)
        }

        Task { [weak self] in
            while !Task.isCancelled {
                if let result = try? String(contentsOf: done, encoding: .utf8) {
                    let status = try? String(contentsOf: statusFile, encoding: .utf8)
                    self?.finish(status: status, exitCode: Int32(result))
                    try? files.removeItem(at: directory)
                    return
                }
                guard self != nil else {
                    _ = files.createFile(atPath: stop.path, contents: nil)
                    return
                }
                if !files.fileExists(atPath: stop.path),
                   let progress = try? String(contentsOf: countdownFile, encoding: .utf8),
                   let seconds = Int(progress) {
                    self?.updateCountdown(seconds)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        guard let stopRequest else { return }
        do {
            try "".write(to: stopRequest, atomically: true, encoding: .utf8)
            hideCountdown()
            message = "Stopping…"
        } catch {
            message = "Use Control-C in Terminal to stop."
        }
    }

    private func finish(status: String?, exitCode: Int32?) {
        hideCountdown()
        stopRequest = nil
        running = false
        needsAccessibility = exitCode == EX_NOPERM
        message = status ?? (exitCode == 0 ? "Stopped." : "Terminal clicker stopped. See Terminal for details.")
    }

    private func updateCountdown(_ seconds: Int) {
        if seconds == 0 {
            hideCountdown()
            message = "Use Control-C or Stop clicking to stop."
        } else if seconds != countdown {
            message = "Move the pointer over the target window."
            countdown = seconds
            countdownPanel.show(seconds)
        }
    }

    private func hideCountdown() {
        countdown = nil
        countdownPanel.hide()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
private final class CountdownPanel {
    private var panel: NSPanel?
    private var badge: NSHostingView<CountdownBadge>?

    func show(_ seconds: Int) {
        if let badge {
            badge.rootView = CountdownBadge(seconds: seconds)
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main else { return }
        let size = NSSize(width: 220, height: 62)
        let rect = NSRect(x: screen.visibleFrame.midX - size.width / 2,
                          y: screen.visibleFrame.maxY - size.height - 16,
                          width: size.width, height: size.height)
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        let badge = NSHostingView(rootView: CountdownBadge(seconds: seconds))
        badge.setFrameSize(size)
        panel.contentView = badge
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        self.badge = badge
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        badge = nil
    }
}

private struct CountdownBadge: View {
    let seconds: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.click")
            Text("Clicking in \(seconds)s")
                .monospacedDigit()
        }
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(Color(red: 0.65, green: 0.98, blue: 0.79))
        .frame(width: 220, height: 62)
        .background(Color(red: 0.06, green: 0.14, blue: 0.12), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ClickerView: View {
    @StateObject private var clicker = Clicker()
    private let mint = Color(red: 0.65, green: 0.98, blue: 0.79)
    private let panel = Color(red: 0.11, green: 0.15, blue: 0.14)

    private var runStatus: String {
        if let seconds = clicker.countdown { return "Starting in \(seconds)s" }
        return clicker.running ? "Running" : "Ready"
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

            if clicker.needsAccessibility,
               let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                Link("Open Accessibility Settings", destination: settingsURL)
            }

            Button {
                if clicker.running { clicker.stop() } else { clicker.start() }
            } label: {
                Label(clicker.running ? "Stop clicking" : "Start clicking",
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
