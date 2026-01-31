import SwiftUI
import WebKit

/// WKWebView wrapper for rendering Markdown with browser-identical font rendering
struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let isDarkMode = colorScheme == .dark

        // Only reload if content or theme changed
        if context.coordinator.lastMarkdown == markdown &&
           context.coordinator.lastIsDarkMode == isDarkMode {
            return
        }

        context.coordinator.lastMarkdown = markdown
        context.coordinator.lastIsDarkMode = isDarkMode

        let html = buildHTML(markdown: markdown, isDarkMode: isDarkMode)
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func buildHTML(markdown: String, isDarkMode: Bool) -> String {
        // Escape for JavaScript template literal
        let escaped = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "</script>", with: "<\\/script>")  // Prevent script tag breakage

        // Load marked.js from bundle
        let markedJS = loadBundleResource(name: "marked.min", type: "js")
            ?? "console.error('marked.js not found');"

        // Load github-markdown.css from bundle
        let githubCSS = loadBundleResource(name: "github-markdown", type: "css") ?? ""

        let theme = isDarkMode ? "dark" : "light"

        return """
        <!DOCTYPE html>
        <html data-theme="\(theme)">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <script>\(markedJS)</script>
            <style>
                \(githubCSS)

                /* Override background to transparent for native integration */
                body {
                    margin: 0;
                    padding: 0;
                    background: transparent;
                }
                .markdown-body {
                    background-color: transparent;
                    padding: 16px;
                }
            </style>
        </head>
        <body>
            <article class="markdown-body">
                <div id="content"></div>
            </article>
            <script>
                marked.setOptions({
                    breaks: true,
                    gfm: true
                });
                document.getElementById('content').innerHTML = marked.parse(`\(escaped)`);
            </script>
        </body>
        </html>
        """
    }

    private func loadBundleResource(name: String, type: String) -> String? {
        guard let path = Bundle.main.path(forResource: name, ofType: type),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return content
    }

    class Coordinator {
        var lastMarkdown: String?
        var lastIsDarkMode: Bool?
    }
}
