import SwiftUI
import AppKit
import CoreGraphics
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
    private var helper: Process?
    private var stopHandle: FileHandle?
    private var countdownTask: Task<Void, Never>?
    private let countdownPanel = CountdownPanel()

    func start() {
        guard !running, let executable = Bundle.main.executableURL else { return }
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            needsAccessibility = true
            message = "Allow Cursor Click to send clicks, then try again."
            return
        }
        needsAccessibility = false
        let statusFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorClick-\(UUID().uuidString).status")
        let countdownFile = statusFile.appendingPathExtension("countdown")
        let duration = Double(max(10, min(pauseMilliseconds, 60_000))) / 1000
        let limit = continuous ? 0 : max(1, min(count, 1000))
        let input = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--clicker-helper", String(duration), String(limit),
            variation ? "1" : "0", pressSpace ? "1" : "0", pressLetters ? "1" : "0",
            BrowserRefreshGate.pauseFile.path, statusFile.path
        ]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let status = try? String(contentsOf: statusFile, encoding: .utf8)
            try? FileManager.default.removeItem(at: statusFile)
            try? FileManager.default.removeItem(at: countdownFile)
            Task { @MainActor in
                guard let self, self.helper === finished else { return }
                self.hideCountdown()
                self.helper = nil
                self.stopHandle = nil
                self.running = false
                self.needsAccessibility = finished.terminationStatus == EX_NOPERM || !CGPreflightPostEventAccess()
                self.message = status ?? (finished.terminationStatus == 0 ? "Stopped." : "The clicker could not run.")
            }
        }
        do {
            try process.run()
            helper = process
            stopHandle = input.fileHandleForWriting
            running = true
            message = "Move the pointer over the target window."
            countdownTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if let progress = try? String(contentsOf: countdownFile, encoding: .utf8),
                       let seconds = Int(progress), seconds != self.countdown {
                        if seconds == 0 {
                            self.hideCountdown()
                            self.message = "Use Control-C or Stop clicking to stop."
                            return
                        }
                        self.countdown = seconds
                        self.countdownPanel.show(seconds)
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        } catch {
            message = "Could not start clicker. \(error.localizedDescription)"
        }
    }

    func stop() {
        hideCountdown()
        try? stopHandle?.close()
        stopHandle = nil
        message = "Stopping…"
    }

    private func hideCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        countdownPanel.hide()
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
enum CursorClickEntry {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.dropFirst().first == "--clicker-helper" {
            runClickerHelper(Array(arguments.dropFirst(2)))
        } else {
            CursorClickApp.main()
        }
    }
}

struct CursorClickApp: App {
    var body: some Scene {
        Window("Cursor Click", id: "main") {
            DashboardView()
        }
        .defaultSize(width: 1280, height: 760)
    }
}
