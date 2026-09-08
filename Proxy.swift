import Foundation
import Network

// sherpa-onnx's websocket server has no --host flag and binds 0.0.0.0.
// We listen on 127.0.0.1 and forward, so the speech port is loopback-only.
final class LoopbackProxy {
    private var listener: NWListener?
    private let dest: NWEndpoint.Port

    init?(port: UInt16, destPort: UInt16) {
        guard let pub = NWEndpoint.Port(rawValue: port),
              let dest = NWEndpoint.Port(rawValue: destPort) else { return nil }
        self.dest = dest
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: pub) else { return nil }
        listener.newConnectionHandler = { [weak self] conn in self?.bridge(conn) }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    private func bridge(_ down: NWConnection) {
        let up = NWConnection(host: "127.0.0.1", port: dest, using: .tcp)
        pump(down, into: up)
        pump(up, into: down)
        down.start(queue: .global(qos: .userInitiated))
        up.start(queue: .global(qos: .userInitiated))
    }

    private func pump(_ a: NWConnection, into b: NWConnection) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, err in
            if let data, !data.isEmpty {
                b.send(content: data, completion: .contentProcessed { _ in
                    if !complete && err == nil { self?.pump(a, into: b) }
                })
            }
            if complete || err != nil { a.cancel(); b.cancel() }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
