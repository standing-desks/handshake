import Foundation

/// A real, ephemeral loopback website shared by WebKit integration and desktop UX tests.
@MainActor
final class BrowserFixtureServer {
    let root: URL
    private let process = Process()
    private let errors = Pipe()
    private(set) var baseURL: URL?

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a", "b", "popup"] {
            try Self.page(name).write(to: root.appending(path: name), atomically: true, encoding: .utf8)
        }
        let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        let python = developer.map { URL(filePath: $0).appending(path: "usr/bin/python3") }
        process.executableURL = python ?? URL(filePath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.server, root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
    }

    func start() async throws {
        let portFile = root.appending(path: "port")
        for _ in 0..<200 {
            let text = try? String(contentsOf: portFile, encoding: .utf8)
            if let port = text.flatMap(Int.init), let url = URL(string: "http://127.0.0.1:\(port)") {
                baseURL = url
                return
            }
            guard process.isRunning else {
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                throw FixtureError.server(String(data: data.prefix(2048), encoding: .utf8) ?? "Fixture server exited.")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        stop()
        throw FixtureError.failed
    }

    func url(_ path: String) throws -> URL {
        guard let baseURL else { throw FixtureError.failed }
        return baseURL.appending(path: path)
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private enum FixtureError: Error {
        case failed
        case server(String)
    }

    private static func page(_ name: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>Page \(name.uppercased())</title>
        <style>body{font:18px system-ui;padding:32px}button,input,a{margin:8px;padding:8px}</style>
        <h1>Page \(name.uppercased())</h1>
        <input id="note" autofocus aria-label="Page note" placeholder="Page note">
        <button onclick="document.querySelector('#result').textContent=note.value">Keep note</button>
        <a href="/b">Go to B</a><a href="/a">Go to A</a>
        <a href="/popup" target="_blank">Open popup</a>
        <button onclick="alert('Fixture alert');result.textContent='alert accepted'">Show alert</button>
        <button onclick="result.textContent=String(confirm('Fixture confirm'))">Show confirm</button>
        <button onclick="result.textContent=String(prompt('Fixture prompt','initial'))">Show prompt</button>
        <input id="upload" type="file" multiple aria-label="Choose fixture files">
        <p id="result" role="status"></p>
        <p id="cookie"></p><script>cookie.textContent=document.cookie; window.retained=0;</script>
        <div style="height:2400px">Scroll area</div><p>End of page</p>
        """
    }

    private static let server = """
        import http.server, pathlib, sys, time, socket
        root = pathlib.Path(sys.argv[1])
        counts = {}
        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=str(root), **kwargs)
            def guess_type(self, path):
                if pathlib.Path(path).name in ['a', 'b', 'popup', 'zoom']:
                    return 'text/html; charset=utf-8'
                return super().guess_type(path)
            def log_message(self, *args):
                pass
            def do_GET(self):
                path = self.path.split('?')[0]
                counts[path] = counts.get(path, 0) + 1
                with (root / 'requests').open('a') as log:
                    log.write(path + '\\n')
                if path == '/redirect':
                    self.send_response(302)
                    self.send_header('Location', '/b')
                    self.end_headers()
                    return
                if path == '/drop' and not (root / 'allow-drop').exists():
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                if path == '/slow':
                    time.sleep(3)
                if path in ['/slow', '/drop', '/cookie']:
                    body = (root / 'a').read_bytes()
                    if path == '/slow':
                        body = body.replace(b'Page A', b'Slow page')
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/html; charset=utf-8')
                    self.send_header('Set-Cookie', 'fixture=shared; Path=/; SameSite=Lax')
                    self.end_headers()
                    try:
                        self.wfile.write(body)
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return
                super().do_GET()
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        (root / 'port').write_text(str(server.server_port))
        server.serve_forever()
        """
}
