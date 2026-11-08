import Foundation
import Network

/// Owns the NWListener (Bonjour-advertised RemotePairing host) and every
/// live client<->box relay pair.
final class RelayManager: ObservableObject {
    static let identifier = "057491AE-882D-3954-A3EB-0BA600EDFB13"
    static let boxHost = "100.124.67.46"
    static let port: UInt16 = 49153
    static let serviceType = "_remotepairing-pairable-host._tcp"

    @Published var logLines: [String] = []
    @Published var isRunning = false

    private let queue = DispatchQueue(label: "com.naiwa.pokirelay.network")
    private var listener: NWListener?
    private var relays: [ObjectIdentifier: ConnectionRelay] = [:]

    // MARK: - Logging

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        print(line)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logLines.append(line)
            if self.logLines.count > 500 {
                self.logLines.removeFirst(self.logLines.count - 500)
            }
        }
    }

    // MARK: - Start / Stop

    func start(authtag: String) {
        guard listener == nil else {
            log("Already running")
            return
        }
        let txtRecord = NWTXTRecord([
            "name": "NaiwaBox",
            "identifier": Self.identifier,
            "authTag": authtag,
            "model": "Mac17,7",
            "flags": "1",
            "ver": "26",
            "minVer": "17"
        ])
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.service = NWListener.Service(
                name: Self.identifier,
                type: Self.serviceType,
                domain: "local.",
                txtRecord: txtRecord
            )
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.log("Listener ready: advertising '\(Self.identifier)' (\(Self.serviceType)) on port \(Self.port)")
                case .waiting(let error):
                    self.log("Listener waiting: \(error)")
                case .failed(let error):
                    self.log("Listener failed: \(error)")
                    self.stop()
                case .cancelled:
                    self.log("Listener cancelled")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleIncoming(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
            DispatchQueue.main.async { self.isRunning = true }
            log("Started. authTag=\(authtag.isEmpty ? "<empty>" : authtag)")
        } catch {
            log("Failed to create listener: \(error)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            let current = Array(self.relays.values)
            self.relays.removeAll()
            current.forEach { $0.teardown() }
            self.listener?.cancel()
            self.listener = nil
        }
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
        }
        log("Stopped")
    }

    // MARK: - Incoming connections

    private func handleIncoming(_ client: NWConnection) {
        log("Incoming connection: \(client.endpoint)")
        let upstream = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(Self.boxHost),
                          port: NWEndpoint.Port(rawValue: Self.port)!),
            using: .tcp
        )
        let relay = ConnectionRelay(
            client: client,
            upstream: upstream,
            logger: { [weak self] message in self?.log(message) },
            onTeardown: { [weak self] relay in
                self?.relays.removeValue(forKey: ObjectIdentifier(relay))
            }
        )
        relays[ObjectIdentifier(relay)] = relay
        relay.start(queue: queue)
    }
}

/// One client connection paired with one upstream connection to the box.
/// Pumps bytes in both directions once both sides are ready; tears both
/// down on the first completion or error.
final class ConnectionRelay {
    private let client: NWConnection
    private let upstream: NWConnection
    private let logger: (String) -> Void
    private let onTeardown: (ConnectionRelay) -> Void

    private var clientReady = false
    private var upstreamReady = false
    private var pumping = false
    private var tornDown = false

    init(client: NWConnection,
         upstream: NWConnection,
         logger: @escaping (String) -> Void,
         onTeardown: @escaping (ConnectionRelay) -> Void) {
        self.client = client
        self.upstream = upstream
        self.logger = logger
        self.onTeardown = onTeardown
    }

    func start(queue: DispatchQueue) {
        client.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.clientReady = true
                self.logger("Client side ready")
                self.beginPumpingIfReady()
            case .waiting(let error):
                self.logger("Client side waiting: \(error)")
            case .failed(let error):
                self.logger("Client connection failed: \(error)")
                self.teardown()
            case .cancelled:
                self.teardown()
            default:
                break
            }
        }
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.upstreamReady = true
                self.logger("Upstream (box) side ready")
                self.beginPumpingIfReady()
            case .waiting(let error):
                self.logger("Upstream side waiting: \(error)")
            case .failed(let error):
                self.logger("Upstream connection failed: \(error)")
                self.teardown()
            case .cancelled:
                self.teardown()
            default:
                break
            }
        }
        client.start(queue: queue)
        upstream.start(queue: queue)
    }

    private func beginPumpingIfReady() {
        guard clientReady, upstreamReady, !pumping, !tornDown else { return }
        pumping = true
        logger("Both sides ready, relaying data")
        forward(from: client, to: upstream)
        forward(from: upstream, to: client)
    }

    private func forward(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.tornDown else { return }
            if let error {
                self.logger("Receive error: \(error)")
                self.teardown()
                return
            }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self, !self.tornDown else { return }
                    if let sendError {
                        self.logger("Send error: \(sendError)")
                        self.teardown()
                    }
                })
                self.forward(from: source, to: destination)
            } else if isComplete {
                self.logger("Peer closed the connection")
                self.teardown()
            } else {
                self.forward(from: source, to: destination)
            }
        }
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        client.cancel()
        upstream.cancel()
        logger("Connection torn down")
        onTeardown(self)
    }
}
