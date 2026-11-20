#if os(macOS)
import Foundation

/// SSH's request/reply adapter over the shared local transport.
final class SSHAgentSocketServer: Sendable {
    private let server: LocalSocketServer

    init(
        path: String,
        handler: SSHAgentRequestHandler,
        maximumConnections: Int = LocalSocketServer.defaultMaximumConnections
    ) {
        server = LocalSocketServer(
            path: path,
            framing: .init(
                byteOrder: .bigEndian,
                maximumInboundLength: SSHAgentRequestHandler.maximumMessageLength,
                maximumOutboundLength: SSHAgentRequestHandler.maximumMessageLength
            ),
            maximumConnections: maximumConnections
        ) { ConnectionHandler(connection: $0, handler: handler) }
    }

    func start() throws { try server.start() }
    func stop() { server.stop() }

    private struct ConnectionHandler: LocalSocketConnectionHandler {
        let connection: LocalSocketServer.Connection
        let handler: SSHAgentRequestHandler

        func receive(_ frame: Data) { connection.send(handler.response(to: frame)) }
        func connectionClosed() {}
    }
}
#endif
