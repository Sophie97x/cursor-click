import SwiftUI
import WebKit

enum BrowserRefreshGate {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    static let pauseFile = directory.appendingPathComponent("clicker-pause")
}

struct BrowserAutomationView: View {
    @StateObject private var service = DashboardService()

    var body: some View {
        Group {
            if let dashboard = service.dashboard {
                DashboardWebView(url: dashboard)
            } else if let error = service.error {
                VStack(spacing: 12) {
                    Text(error)
                    Button("Retry") { Task { await service.start() } }
                }
                .padding()
            } else {
                ProgressView("Starting Browser Automation…")
            }
        }
        .frame(minWidth: 650, minHeight: 480)
        .task { await service.start() }
        .onDisappear(perform: service.stop)
    }

}

@MainActor
private final class DashboardService: ObservableObject {
    private var process: Process?
    private var lifetime: FileHandle?
    private var startupDirectory: URL?
    @Published private(set) var dashboard: URL?
    @Published private(set) var error: String?

    func start() async {
        guard process == nil else { return }
        error = nil
        let files = FileManager.default
        let nodePaths = ["/opt/homebrew/opt/node@24/bin/node", "/opt/homebrew/bin/node",
                         "/usr/local/bin/node"]
        guard let node = nodePaths.first(where: { files.isExecutableFile(atPath: $0) }),
              let script = Bundle.main.url(forResource: "desktop", withExtension: "js",
                                           subdirectory: "BrowserAutomation") else {
            error = "Browser Automation needs Node.js and its bundled dashboard."
            return
        }

        let directory = BrowserRefreshGate.directory
        let readyFile = directory.appendingPathComponent("dashboard-url")
        let input = Pipe()
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: node)
        helper.arguments = [script.path, readyFile.path, BrowserRefreshGate.pauseFile.path]
        helper.standardInput = input
        helper.environment = ProcessInfo.processInfo.environment
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        helper.environment?["PLAYWRIGHT_BROWSERS_PATH"] =
            caches.appendingPathComponent("local.cursorclick.app/Chromium").path

        startupDirectory = directory
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
            try helper.run()
            process = helper
            lifetime = input.fileHandleForWriting
            for _ in 0..<100 {
                guard process === helper else { return }
                guard helper.isRunning else { break }
                if let value = try? String(contentsOf: readyFile, encoding: .utf8),
                   let url = URL(string: value), url.scheme == "http",
                   url.host == "localhost", url.port != nil {
                    dashboard = url
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch is CancellationError {
            return
        } catch {
            stop()
            self.error = error.localizedDescription
            return
        }
        stop()
        error = "Browser Automation could not start."
    }

    func stop() {
        try? lifetime?.close()
        lifetime = nil
        process = nil
        dashboard = nil
        if let startupDirectory {
            try? FileManager.default.removeItem(at: startupDirectory)
            self.startupDirectory = nil
        }
    }
}

private struct DashboardWebView: NSViewRepresentable {
    let url: URL
    private static let progressHandler = "browserLaunchProgress"

    func makeCoordinator() -> Coordinator { Coordinator(dashboardURL: url) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: Self.progressHandler)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: progressHandler)
        coordinator.hideProgress()
    }

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        private let dashboardURL: URL
        private let progressPanel = FloatingStatusPanel<BrowserLaunchBadge>(width: 302, height: 78)
        private var dismissTask: Task<Void, Never>?

        init(dashboardURL: URL) {
            self.dashboardURL = dashboardURL
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            let origin = message.frameInfo.securityOrigin
            guard message.name == DashboardWebView.progressHandler, message.frameInfo.isMainFrame,
                  origin.protocol == dashboardURL.scheme, origin.host == dashboardURL.host,
                  origin.port == dashboardURL.port else { return }
            if message.body is NSNull {
                hideProgress()
                return
            }
            guard let values = message.body as? [String: Any],
                  let requested = values["requested"] as? Int, (1...40).contains(requested),
                  let completed = values["completed"] as? Int, (0...requested).contains(completed),
                  let failed = values["failed"] as? Int, (0...completed).contains(failed),
                  let inProgress = values["inProgress"] as? Bool,
                  inProgress || progressPanel.isVisible else { return }
            dismissTask?.cancel()
            progressPanel.show(BrowserLaunchBadge(requested: requested, completed: completed,
                                                  failed: failed, inProgress: inProgress))
            if !inProgress {
                dismissTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled { self?.hideProgress() }
                }
            }
        }

        func hideProgress() {
            dismissTask?.cancel()
            dismissTask = nil
            progressPanel.hide()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            hideProgress()
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}

private struct BrowserLaunchBadge: View {
    let requested: Int
    let completed: Int
    let failed: Int
    let inProgress: Bool
    private let mint = Color(red: 0.65, green: 0.98, blue: 0.79)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(inProgress ? "Starting Chrome" : failed == 0 ? "Chrome ready" : "Chrome launch finished",
                      systemImage: "macwindow")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                Text("\(completed - failed)/\(requested) ready")
                    .monospacedDigit()
            }
            ProgressView(value: Double(completed), total: Double(requested))
                .tint(mint)
                .accessibilityLabel("Chrome launch progress")
            if failed > 0 {
                Text("\(failed) failed")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(mint)
        .padding(.horizontal, 16)
        .frame(width: 302, height: 78)
        .background(Color(red: 0.06, green: 0.14, blue: 0.12), in: RoundedRectangle(cornerRadius: 16))
    }
}
