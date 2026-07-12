//
//  LocalHTTPServer.swift
//  TaskTether
//
//  Created by Hazim Sami on 10/03/2026.
//

import Foundation
import Network

class LocalHTTPServer {

    private var listener: NWListener?
    private var onCode: ((String) -> Void)?

    // Starts listening on an EPHEMERAL port chosen by the system — never a
    // fixed one. A fixed port (previously 8080) collides with anything else
    // on the machine (Homebrew nginx defaults to 8080, dev servers love it),
    // and the OAuth redirect then delivers the auth code to the wrong
    // process. Google desktop OAuth clients accept any localhost port, so
    // the caller builds the redirect URI from the port reported by onReady.
    //
    // onReady is called exactly once: with the bound port on success, or
    // nil when the listener could not start.
    func start(onCode: @escaping (String) -> Void, onReady: @escaping (UInt16?) -> Void) {
        self.onCode = onCode

        do {
            listener = try NWListener(using: .tcp, on: .any)
        } catch {
            #if DEBUG
            print("Failed to create listener: \(error)")
            #endif
            onReady(nil)
            return
        }

        // Bind failures do NOT throw above — they surface asynchronously
        // here. Without this handler the sign-in button spins forever with
        // no explanation.
        var reported = false
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard !reported else { return }
                reported = true
                let port = self?.listener?.port?.rawValue
                #if DEBUG
                print("Local HTTP server started on port \(port.map(String.init) ?? "?")")
                #endif
                onReady(port)
            case .failed(let error):
                #if DEBUG
                print("Listener failed: \(error)")
                #endif
                self?.stop()
                guard !reported else { return }
                reported = true
                onReady(nil)
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.handleConnection(connection)
        }

        listener?.start(queue: .global())
    }

    func stop() {
        listener?.cancel()
        listener = nil
        #if DEBUG
        print("Local HTTP server stopped")
        #endif
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let data = data, let request = String(data: data, encoding: .utf8) else { return }

            // Parse the auth code from the GET request line
            // e.g. GET /?code=4/0AX4XfWh...&scope=... HTTP/1.1
            if let code = self?.extractCode(from: request) {
                // Send a success response to the browser
                let html = """
                <html>
                <head>
                    <style>
                        body { font-family: -apple-system, sans-serif; display: flex;
                               align-items: center; justify-content: center;
                               height: 100vh; margin: 0; background: #f5f5f7; }
                        .card { text-align: center; padding: 40px; background: white;
                                border-radius: 12px; box-shadow: 0 2px 20px rgba(0,0,0,0.1); }
                        h1 { color: #1a1a2e; font-size: 24px; margin-bottom: 8px; }
                        p { color: #8e8e93; font-size: 16px; }
                    </style>
                </head>
                <body>
                    <div class="card">
                        <h1>TaskTether Connected</h1>
                        <p>You can close this tab and return to TaskTether.</p>
                    </div>
                </body>
                </html>
                """

                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"

                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })

                self?.onCode?(code)
                self?.stop()
            }
        }
    }

    private func extractCode(from request: String) -> String? {
        // GET /?code=XXXX&... HTTP/1.1
        guard let line = request.components(separatedBy: "\r\n").first,
              let range = line.range(of: "code=") else { return nil }

        let after = String(line[range.upperBound...])
        let code = after.components(separatedBy: "&").first?
                        .components(separatedBy: " ").first
        return code
    }
}
