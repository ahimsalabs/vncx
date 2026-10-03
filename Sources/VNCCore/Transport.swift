import Foundation
import Network

/// A blocking, buffered byte stream on top of NWConnection. The RFB client runs on its own thread
/// and reads synchronously; Network.framework does name resolution (MagicDNS, Bonjour, IPv6) for us.
package final class Transport: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "vncx.transport")
    private let readSignal = DispatchSemaphore(value: 0)

    private var storage: UnsafeMutableRawPointer
    private var capacity: Int
    private var head = 0
    private var tail = 0

    // Guarded by `queue` while a receive is in flight; read on the reader thread after the semaphore.
    private var pendingChunk: Data?
    private var pendingError: Error?
    private var closedByPeer = false
    private let stateLock = NSLock()
    private var cancelled = false

    package private(set) var bytesReceived: UInt64 = 0

    package init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 15
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let params = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(to: endpoint, using: params)
        capacity = 1 << 20
        storage = .allocate(byteCount: capacity, alignment: 16)
    }

    /// An in-memory transport for tests: reads come from `bytes`, then the stream reports closed.
    package init(bytes: [UInt8]) {
        connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        capacity = max(bytes.count, 16)
        storage = .allocate(byteCount: capacity, alignment: 16)
        bytes.withUnsafeBytes { storage.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        tail = bytes.count
        closedByPeer = true
    }

    deinit { storage.deallocate() }

    /// Blocks until the TCP connection is established or fails.
    package func open() throws {
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ready.signal()
            case .waiting(let err):
                // .waiting means "no route right now"; treat as failure so the UI can report it.
                failure = Transport.error(err)
                ready.signal()
            case .failed(let err):
                failure = Transport.error(err)
                ready.signal()
                self?.readSignal.signal()
            case .cancelled:
                ready.signal()
                self?.readSignal.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        ready.wait()
        if isCancelled { throw RFBError.cancelled }
        if let failure {
            connection.cancel()
            throw failure
        }
    }

    package var isCancelled: Bool { stateLock.withLock { cancelled } }

    package func close() {
        stateLock.withLock { cancelled = true }
        connection.cancel()
        readSignal.signal()
    }

    package var remoteDescription: String {
        if case .hostPort(let h, let p) = connection.currentPath?.remoteEndpoint { return "\(h):\(p)" }
        return "\(connection.endpoint)"
    }

    // MARK: Reading

    package var buffered: Int { tail - head }

    /// Ensures at least `n` bytes are buffered contiguously and returns a pointer to them (valid until the next read).
    @inline(__always)
    package func peek(_ n: Int) throws -> UnsafeRawPointer {
        if tail - head < n { try fill(n) }
        return UnsafeRawPointer(storage + head)
    }

    @inline(__always)
    package func consume(_ n: Int) { head += n }

    /// Calls `body` with exactly `n` contiguous bytes, then consumes them.
    @inline(__always)
    package func withBytes<R>(_ n: Int, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        let p = try peek(n)
        defer { head += n }
        return try body(UnsafeRawBufferPointer(start: p, count: n))
    }

    package func bytes(_ n: Int) throws -> [UInt8] {
        try withBytes(n) { Array($0.bindMemory(to: UInt8.self)) }
    }

    package func skip(_ n: Int) throws {
        var remaining = n
        while remaining > 0 {
            let step = min(remaining, 1 << 16)
            _ = try peek(step); head += step; remaining -= step
        }
    }

    @inline(__always) package func u8() throws -> UInt8 {
        let v = try peek(1).load(as: UInt8.self); head += 1; return v
    }
    @inline(__always) package func u16() throws -> UInt16 {
        let p = try peek(2).assumingMemoryBound(to: UInt8.self); head += 2
        return UInt16(p[0]) << 8 | UInt16(p[1])
    }
    @inline(__always) package func u32() throws -> UInt32 {
        let p = try peek(4).assumingMemoryBound(to: UInt8.self); head += 4
        return UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
    }
    @inline(__always) package func s32() throws -> Int32 { Int32(bitPattern: try u32()) }

    private func fill(_ n: Int) throws {
        // Compact, then grow if needed.
        if head > 0 {
            let live = tail - head
            if live > 0 { memmove(storage, storage + head, live) }
            head = 0; tail = live
        }
        if capacity < n {
            var newCap = capacity
            while newCap < n { newCap *= 2 }
            let newStorage = UnsafeMutableRawPointer.allocate(byteCount: newCap, alignment: 16)
            newStorage.copyMemory(from: storage, byteCount: tail)
            storage.deallocate()
            storage = newStorage
            capacity = newCap
        }
        while tail < n {
            let chunk = try receiveChunk(max: capacity - tail)
            chunk.withUnsafeBytes { src in
                (storage + tail).copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
            tail += chunk.count
            bytesReceived += UInt64(chunk.count)
        }
    }

    private func receiveChunk(max: Int) throws -> Data {
        if isCancelled { throw RFBError.cancelled }
        if closedByPeer { throw RFBError.closed }
        connection.receive(minimumIncompleteLength: 1, maximumLength: max) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.pendingChunk = data }
            if let error { self.pendingError = error }
            if isComplete { self.closedByPeer = true }
            self.readSignal.signal()
        }
        readSignal.wait()
        if isCancelled { throw RFBError.cancelled }
        if let chunk = pendingChunk { pendingChunk = nil; return chunk }
        if let err = pendingError { pendingError = nil; throw RFBError.connection(Transport.describe(err)) }
        throw RFBError.closed
    }

    // MARK: Writing

    package func send(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .idempotent)
    }

    static func error(_ err: NWError) -> RFBError {
        if case .posix(.ECONNREFUSED) = err { return .refused }
        return .connection(describe(err))
    }

    package static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "Connection refused. Is screen sharing / the VNC server enabled?"
            case .ETIMEDOUT: return "The connection timed out."
            case .EHOSTUNREACH, .ENETUNREACH: return "The host is unreachable."
            default: return error.localizedDescription
            }
        case .dns(let code):
            return "Could not resolve the host name (DNS error \(code))."
        default:
            return error.localizedDescription
        }
    }

    package static func describe(_ error: Error) -> String {
        if let nw = error as? NWError { return describe(nw) }
        return error.localizedDescription
    }
}
