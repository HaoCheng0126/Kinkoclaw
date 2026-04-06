import Foundation
import UniformTypeIdentifiers
import WebKit

enum StageRuntimeSupport {
    static let scheme = "kinkoclaw-stage"

    static func resolveRootURL(bundle: Bundle = .module) -> URL? {
        if let indexURL = bundle.url(forResource: "index", withExtension: "html", subdirectory: "StageRuntime") {
            return indexURL.deletingLastPathComponent()
        }
        if let indexURL = bundle.url(forResource: "index", withExtension: "html", subdirectory: "Stage") {
            return indexURL.deletingLastPathComponent()
        }
        return nil
    }

    static func stageURL(mode: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "stage"
        components.path = "/index.html"
        if let mode, !mode.isEmpty {
            components.queryItems = [URLQueryItem(name: "mode", value: mode)]
        }
        return components.url
    }
}

final class StageBundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        super.init()
    }

    func webView(_: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
            return
        }

        let relativePath = requestURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetURL = self.rootURL.appendingPathComponent(relativePath.isEmpty ? "index.html" : relativePath)

        do {
            let data = try Data(contentsOf: targetURL)
            let mimeType = Self.mimeType(for: targetURL)
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: Self.textEncoding(for: mimeType))
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_: WKWebView, stop _: any WKURLSchemeTask) {}

    private static func mimeType(for fileURL: URL) -> String {
        if let type = UTType(filenameExtension: fileURL.pathExtension),
           let mime = type.preferredMIMEType
        {
            return mime
        }

        switch fileURL.pathExtension.lowercased() {
        case "js", "mjs":
            return "text/javascript"
        case "css":
            return "text/css"
        case "json":
            return "application/json"
        case "png":
            return "image/png"
        case "svg":
            return "image/svg+xml"
        case "html":
            return "text/html"
        default:
            return "application/octet-stream"
        }
    }

    private static func textEncoding(for mimeType: String) -> String? {
        switch mimeType {
        case "text/html", "text/css", "text/javascript", "application/json", "image/svg+xml":
            return "utf-8"
        default:
            return nil
        }
    }
}
