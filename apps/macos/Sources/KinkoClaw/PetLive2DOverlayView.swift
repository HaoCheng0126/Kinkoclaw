import AppKit
import SwiftUI
import WebKit

struct PetLive2DOverlayView: NSViewRepresentable {
    let pack: PetPackManifest
    let presenceState: PetPresenceState
    let connectionStatus: PetGatewayConnectionStatus
    let statusMessage: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        guard let rootURL = StageRuntimeSupport.resolveRootURL() else {
            return container
        }

        let config = context.coordinator.makeConfiguration(rootURL: rootURL)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.enclosingScrollView?.drawsBackground = false

        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.attach(webView)
        context.coordinator.loadPetStage()
        context.coordinator.update(
            pack: self.pack,
            presenceState: self.presenceState,
            connectionStatus: self.connectionStatus,
            statusMessage: self.statusMessage)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            pack: self.pack,
            presenceState: self.presenceState,
            connectionStatus: self.connectionStatus,
            statusMessage: self.statusMessage)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private enum MessageNames {
            static let bridge = "kinkoClawPetStageBridge"
        }

        private struct BootstrapPayload: Encodable {
            let connectionStatus: String
            let statusMessage: String
            let presenceState: String
            let pack: PetPackManifest
            let messages: [String]
            let streamingAssistantText: String
            let fallbackChatAvailable: Bool
        }

        private struct StatusPayload: Encodable {
            let connectionStatus: String
            let statusMessage: String
            let presenceState: String
        }

        private struct StageEnvelope<Value: Encodable>: Encodable {
            let type: String
            let payload: Value
        }

        private struct Snapshot: Equatable {
            let pack: PetPackManifest
            let presenceState: PetPresenceState
            let connectionStatus: String
            let statusMessage: String
        }

        private weak var webView: WKWebView?
        private var webViewReady = false
        private var latestSnapshot: Snapshot?
        private var stageSchemeHandler: StageBundleSchemeHandler?

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func makeConfiguration(rootURL: URL) -> WKWebViewConfiguration {
            let controller = WKUserContentController()
            controller.add(self, name: MessageNames.bridge)
            controller.addUserScript(
                WKUserScript(
                    source: """
                    (() => {
                      if (window.KinkoClawNativeBridge) return;
                      window.KinkoClawNativeBridge = {
                        postMessage(payload) {
                          try {
                            window.webkit?.messageHandlers?.\(MessageNames.bridge)?.postMessage(payload);
                          } catch (error) {
                            console.error("KinkoClaw pet bridge failed", error);
                          }
                        }
                      };
                    })();
                    """,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true))

            let config = WKWebViewConfiguration()
            config.userContentController = controller
            let schemeHandler = StageBundleSchemeHandler(rootURL: rootURL)
            self.stageSchemeHandler = schemeHandler
            config.setURLSchemeHandler(schemeHandler, forURLScheme: StageRuntimeSupport.scheme)
            return config
        }

        func loadPetStage() {
            guard let webView, let stageURL = StageRuntimeSupport.stageURL(mode: "pet") else { return }
            self.webViewReady = false
            webView.load(URLRequest(url: stageURL))
        }

        func webView(_: WKWebView, didFinish _: WKNavigation!) {}

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == MessageNames.bridge,
                  let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String
            else {
                return
            }

            if type == "stage.ready" {
                self.webViewReady = true
                if let snapshot = self.latestSnapshot, let webView = self.webView {
                    self.publishBootstrap(snapshot, to: webView)
                    self.publishStatus(snapshot, to: webView)
                }
            }
        }

        func update(
            pack: PetPackManifest,
            presenceState: PetPresenceState,
            connectionStatus: PetGatewayConnectionStatus,
            statusMessage: String)
        {
            let snapshot = Snapshot(
                pack: pack,
                presenceState: presenceState,
                connectionStatus: Self.connectionStatusID(connectionStatus),
                statusMessage: statusMessage)
            let previous = self.latestSnapshot
            self.latestSnapshot = snapshot

            guard self.webViewReady, let webView else { return }
            if previous?.pack != snapshot.pack {
                self.publishBootstrap(snapshot, to: webView)
            } else {
                self.publishStatus(snapshot, to: webView)
            }
        }

        private func publishBootstrap(_ snapshot: Snapshot, to webView: WKWebView) {
            let payload = BootstrapPayload(
                connectionStatus: snapshot.connectionStatus,
                statusMessage: snapshot.statusMessage,
                presenceState: snapshot.presenceState.rawValue,
                pack: snapshot.pack,
                messages: [],
                streamingAssistantText: "",
                fallbackChatAvailable: false)
            self.publish("stage.bootstrap", payload: payload, to: webView)
        }

        private func publishStatus(_ snapshot: Snapshot, to webView: WKWebView) {
            self.publish(
                "stage.status",
                payload: StatusPayload(
                    connectionStatus: snapshot.connectionStatus,
                    statusMessage: snapshot.statusMessage,
                    presenceState: snapshot.presenceState.rawValue),
                to: webView)
        }

        private func publish<T: Encodable>(_ type: String, payload: T, to webView: WKWebView) {
            do {
                let raw = try Self.encode(StageEnvelope(type: type, payload: payload))
                webView.evaluateJavaScript("window.__KINKOCLAW_STAGE_RECEIVE__?.(\(raw));", completionHandler: nil)
            } catch {
                NSLog("KinkoClaw pet overlay publish failed: %@", error.localizedDescription)
            }
        }

        private static func encode<T: Encodable>(_ value: T) throws -> String {
            let data = try JSONEncoder().encode(value)
            guard let raw = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "KinkoClaw.PetLive2DOverlay", code: -1)
            }
            return raw
        }

        private static func connectionStatusID(_ status: PetGatewayConnectionStatus) -> String {
            switch status {
            case .disconnected:
                return "disconnected"
            case .connecting:
                return "connecting"
            case .connected:
                return "connected"
            case .error:
                return "error"
            }
        }
    }
}
