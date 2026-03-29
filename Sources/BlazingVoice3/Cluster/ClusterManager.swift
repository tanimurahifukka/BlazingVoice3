import Foundation
import Network

struct ClusterNode: Sendable {
    let id: String
    let host: String
    let port: Int
    let backend: String
    let model: String
    var slots: Int
    let isLocal: Bool
    var isHealthy: Bool
    var lastSeen: Date
    var consecutiveFailures: Int

    var totalMemory: UInt64 = 0
    var rssBytes: UInt64 = 0
    var freeMemory: UInt64 = 0
    var memoryPressure: String = "unknown"

    var baseURL: String { "http://\(host):\(port)" }
}

/// Manages Bonjour-based LAN peer discovery for BlazingVoice3 cluster mode.
final class ClusterManager: @unchecked Sendable {
    private let httpPort: Int
    private let backend: String
    private let model: String
    private let slots: Int

    private let lock = NSLock()
    private var nodes: [String: ClusterNode] = [:]
    private var serviceToNodeIds: [String: Set<String>] = [:]

    let router: BandwidthRouter

    private var listener: NWListener?
    private var browser: NWBrowser?

    private let serviceType = "_blazingvoice._tcp"

    init(httpPort: Int, backend: String, model: String, slots: Int, spilloverThreshold: Double = 0.8) {
        self.httpPort = httpPort
        self.backend = backend
        self.model = model
        self.slots = slots
        self.router = BandwidthRouter(spilloverThreshold: spilloverThreshold, localSlots: slots)
    }

    func start() {
        let localIP = Self.getLocalIPv4() ?? "127.0.0.1"
        let localId = "\(localIP):\(httpPort)"
        let localNode = ClusterNode(
            id: localId, host: localIP, port: httpPort,
            backend: backend, model: model, slots: slots,
            isLocal: true, isHealthy: true, lastSeen: Date(),
            consecutiveFailures: 0
        )
        lock.lock()
        nodes[localId] = localNode
        lock.unlock()

        let initialLocal: Double = backend == "llama" ? 70.0 : 40.0
        router.registerNode(id: localId, isLocal: true, initialBandwidth: initialLocal)

        startListener()
        startBrowser()
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
    }

    // MARK: - Local IP

    static func getLocalIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var result: String?
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: addr.ifa_name)
            guard name != "lo0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr.ifa_addr, socklen_t(addr.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)
                if name == "en0" { return ip }
                if result == nil { result = ip }
            }
        }
        return result
    }

    // MARK: - Bonjour

    private func startListener() {
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: .any)

            let localIP = Self.getLocalIPv4() ?? "unknown"

            let txtRecord = NWTXTRecord([
                "port": "\(httpPort)",
                "host": localIP,
                "backend": backend,
                "model": model,
                "slots": "\(slots)",
            ])

            listener.service = NWListener.Service(
                name: nil,
                type: serviceType,
                txtRecord: txtRecord
            )

            listener.newConnectionHandler = { connection in
                connection.stateUpdateHandler = { state in
                    if case .ready = state { connection.cancel() }
                    else if case .failed = state { connection.cancel() }
                }
                connection.start(queue: .global(qos: .background))
            }

            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port {
                    print("[Cluster] Bonjour advertising on port \(port) (HTTP: \(self.httpPort))")
                }
            }

            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            print("[Cluster] Failed to create listener: \(error)")
        }
    }

    private func startBrowser() {
        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: "local."),
            using: .tcp
        )

        browser.browseResultsChangedHandler = { results, changes in
            for change in changes {
                switch change {
                case .added(let result):
                    self.handlePeerAdded(result)
                case .removed(let result):
                    self.handlePeerRemoved(result)
                default:
                    break
                }
            }
        }

        browser.stateUpdateHandler = { state in
            if case .ready = state {
                print("[Cluster] Browsing for peers...")
            }
        }

        browser.start(queue: .global(qos: .utility))
        self.browser = browser
    }

    private func handlePeerAdded(_ result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let path = connection.currentPath,
                   let endpoint = path.remoteEndpoint,
                   case .hostPort(let host, _) = endpoint {
                    var rawHost = "\(host)"
                    if let pctIdx = rawHost.firstIndex(of: "%") {
                        rawHost = String(rawHost[rawHost.startIndex..<pctIdx])
                    }
                    self.discoverNode(host: rawHost, serviceName: name)
                }
                connection.cancel()
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    private func discoverNode(host: String, serviceName: String) {
        let portsToTry = Array(Set([httpPort, 8080]))

        for tryPort in portsToTry {
            guard let url = URL(string: "http://\(host):\(tryPort)/health") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5

            let sem = DispatchSemaphore(value: 0)
            var success = false

            let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
                defer { sem.signal() }
                guard let self, error == nil,
                      let httpResp = response as? HTTPURLResponse,
                      httpResp.statusCode == 200 else { return }

                success = true
                let isLocal = self.isLocalAddress(host) && tryPort == self.httpPort
                let nodeId = "\(host):\(tryPort)"

                let node = ClusterNode(
                    id: nodeId, host: host, port: tryPort,
                    backend: self.backend, model: "",
                    slots: 0, isLocal: isLocal, isHealthy: true,
                    lastSeen: Date(), consecutiveFailures: 0
                )

                self.lock.lock()
                self.nodes[nodeId] = node
                self.serviceToNodeIds[serviceName, default: []].insert(nodeId)
                self.lock.unlock()
                if !isLocal {
                    self.router.registerNode(id: nodeId, isLocal: false, initialBandwidth: 30.0)
                }
                print("[Cluster] Peer added: \(nodeId) (name: \(serviceName))")
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 6)
            if success { return }
        }
    }

    func addExplicitPeer(_ address: String) {
        let parts = address.split(separator: ":")
        let host = String(parts[0])
        let port = parts.count > 1 ? Int(parts[1]) ?? 8080 : 8080

        if isLocalAddress(host) && port == httpPort { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self,
                  let url = URL(string: "http://\(host):\(port)/health") else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10

            let sem = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
                defer { sem.signal() }
                guard let self, error == nil,
                      let httpResp = response as? HTTPURLResponse,
                      httpResp.statusCode == 200 else { return }

                let nodeId = "\(host):\(port)"
                let node = ClusterNode(
                    id: nodeId, host: host, port: port,
                    backend: "", model: "", slots: 0,
                    isLocal: false, isHealthy: true,
                    lastSeen: Date(), consecutiveFailures: 0
                )

                self.lock.lock()
                self.nodes[nodeId] = node
                self.lock.unlock()
                self.router.registerNode(id: nodeId, isLocal: false, initialBandwidth: 30.0)
                print("[Cluster] Explicit peer added: \(nodeId)")
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 12)
        }
    }

    private func handlePeerRemoved(_ result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }
        lock.lock()
        let nodeIds = serviceToNodeIds.removeValue(forKey: name) ?? []
        for nodeId in nodeIds {
            nodes.removeValue(forKey: nodeId)
        }
        lock.unlock()

        for nodeId in nodeIds {
            router.removeNode(id: nodeId)
        }
        print("[Cluster] Service removed: \(name)")
    }

    private func isLocalAddress(_ host: String) -> Bool {
        if host == "127.0.0.1" || host == "::1" || host == "localhost" {
            return true
        }
        if let localIP = Self.getLocalIPv4(), host == localIP {
            return true
        }
        return false
    }

    // MARK: - Node Selection

    func nextNode(excluding: Set<String> = []) -> ClusterNode? {
        guard let selectedId = router.selectNode(excluding: excluding) else { return nil }
        lock.lock()
        let node = nodes[selectedId]
        lock.unlock()
        return node
    }

    func markFailed(nodeId: String) {
        lock.lock()
        if var node = nodes[nodeId] {
            node.consecutiveFailures += 1
            if node.consecutiveFailures >= 3 {
                node.isHealthy = false
            }
            nodes[nodeId] = node
        }
        lock.unlock()
        router.recordFailure(nodeId: nodeId)
    }

    func markHealthy(nodeId: String) {
        lock.lock()
        if var node = nodes[nodeId] {
            node.consecutiveFailures = 0
            node.isHealthy = true
            node.lastSeen = Date()
            nodes[nodeId] = node
        }
        lock.unlock()
    }

    func allNodes() -> [ClusterNode] {
        lock.lock()
        defer { lock.unlock() }
        return Array(nodes.values).sorted { $0.id < $1.id }
    }
}
