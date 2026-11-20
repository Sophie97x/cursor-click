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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate {
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
