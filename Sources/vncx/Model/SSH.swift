// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import VNCCore
import Foundation
import Darwin

/// Per-connection SSH options.
struct SSHSettings: Codable, Hashable {
    var enabled = false
    /// Anything `ssh` accepts: `host`, `user@host`, or an alias from ~/.ssh/config. Empty means the VNC host.
    var destination = ""
    /// Carry the VNC connection through an SSH tunnel to `tunnelHost:port` on the far side.
    var tunnel = false
    var tunnelHost = "localhost"
    /// Shell command run on the remote when the VNC server doesn't answer. `{port}` is replaced by the VNC port.
    var startCommand = ""
    /// Where dropped files go, relative to the remote home directory.
    var uploadDirectory = "Downloads"

    static let wayvncPreset = #"pgrep -x wayvnc >/dev/null || { export XDG_RUNTIME_DIR=/run/user/$(id -u); export WAYLAND_DISPLAY=$(ls $XDG_RUNTIME_DIR | grep -m1 '^wayland-[0-9]*$'); nohup wayvnc --desktop 0.0.0.0 {port} </dev/null >/dev/null 2>&1 & sleep 1; }"#
    static let tigervncPreset = #"pgrep -x Xvnc >/dev/null || vncserver :$(({port} - 5900)) </dev/null >/dev/null 2>&1"#

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        destination = (try? c.decode(String.self, forKey: .destination)) ?? ""
        tunnel = (try? c.decode(Bool.self, forKey: .tunnel)) ?? false
        tunnelHost = (try? c.decode(String.self, forKey: .tunnelHost)) ?? "localhost"
        startCommand = (try? c.decode(String.self, forKey: .startCommand)) ?? ""
        uploadDirectory = (try? c.decode(String.self, forKey: .uploadDirectory)) ?? "Downloads"
    }
}

enum SSHError: LocalizedError {
    case failed(String)
    case timedOut(String)
    var errorDescription: String? {
        switch self {
        case .failed(let s): return s
        case .timedOut(let s): return s
        }
    }
}

/// Runs the system `ssh` non-interactively. Authentication must work without a prompt (keys, agent, or config);
/// there is no terminal for a password or host-key question.
enum SSH {
    static let executable = URL(fileURLWithPath: "/usr/bin/ssh")

    static func baseArguments(_ destination: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
         "-o", "ServerAliveCountMax=3", destination]
    }

    /// Runs a command on the remote host and returns its output, or throws with ssh's error text.
    static func run(_ destination: String, command: String, timeout: TimeInterval = 30,
                    completion: @escaping (Result<String, Error>) -> Void) {
        let p = Process()
        p.executableURL = executable
        // Feed the script to `sh -s` so it runs as POSIX sh whatever the remote login shell is (fish, zsh, …).
        p.arguments = baseArguments(destination) + ["--", "sh", "-s"]
        let out = Pipe(), err = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input
        var finished = false
        let lock = NSLock()
        p.terminationHandler = { proc in
            let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let first = lock.withLock { () -> Bool in defer { finished = true }; return !finished }
            guard first else { return }
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 { completion(.success(o)) }
                else { completion(.failure(SSHError.failed(describe(e, status: proc.terminationStatus)))) }
            }
        }
        do { try p.run() } catch { completion(.failure(error)); return }
        input.fileHandleForWriting.write(Data((command + "\n").utf8))
        try? input.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            let first = lock.withLock { () -> Bool in defer { finished = true }; return !finished }
            guard first else { return }
            p.terminate()
            DispatchQueue.main.async { completion(.failure(SSHError.timedOut("ssh \(destination) timed out after \(Int(timeout))s."))) }
        }
    }

    static func describe(_ stderr: String, status: Int32) -> String {
        let lines = stderr.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("Warning: Permanently added") }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("Permission denied") {
            return "SSH login failed. vncx can't type passwords, so it needs a key or agent that works without a prompt.\n\(text)"
        }
        if text.contains("Host key verification failed") {
            return "SSH doesn't know this host's key yet. Connect once with ssh in Terminal to accept it.\n\(text)"
        }
        return text.isEmpty ? "ssh exited with status \(status)." : text
    }
}

extension SSH {
    /// Copies local files (and folders) into `directory` on the remote host with scp.
    static func upload(_ files: [URL], to destination: String, directory: String,
                       completion: @escaping (Result<Void, Error>) -> Void) {
        let dir = directory.trimmingCharacters(in: .whitespaces)
        // Create the folder first (scp won't), then copy. Paths are relative to the remote home directory.
        run(destination, command: "mkdir -p -- '\(dir.replacingOccurrences(of: "'", with: "'\\''"))'", timeout: 30) { result in
            if case .failure(let e) = result { completion(.failure(e)); return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            p.arguments = ["-r", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"] + files.map(\.path)
                + ["\(destination):\(dir.isEmpty ? "." : dir)/"]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                DispatchQueue.main.async {
                    if proc.terminationStatus == 0 { completion(.success(())) }
                    else { completion(.failure(SSHError.failed(describe(e, status: proc.terminationStatus)))) }
                }
            }
            do { try p.run() } catch { completion(.failure(error)) }
        }
    }
}

/// A running `ssh -N -L` port forward. Keeps the process alive until `close()`.
final class SSHTunnel {
    let localPort: UInt16
    private let process: Process
    private let errPipe = Pipe()
    /// vncx holds the write end; when it closes (close(), or vncx exiting for any reason) the wrapper kills ssh.
    private let lifeline = Pipe()

    var isRunning: Bool { process.isRunning }

    /// Starts the tunnel and calls back on the main queue once the local port accepts connections.
    static func open(destination: String, remoteHost: String, remotePort: Int,
                     completion: @escaping (Result<SSHTunnel, Error>) -> Void) {
        let port = freeLocalPort()
        let tunnel = SSHTunnel(destination: destination, localPort: port, remoteHost: remoteHost, remotePort: remotePort)
        do { try tunnel.process.run() } catch { completion(.failure(error)); return }
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if !tunnel.process.isRunning {
                    let e = String(decoding: tunnel.errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    DispatchQueue.main.async {
                        completion(.failure(SSHError.failed("SSH tunnel failed: " + SSH.describe(e, status: tunnel.process.terminationStatus))))
                    }
                    return
                }
                if canConnect(port) { DispatchQueue.main.async { completion(.success(tunnel)) }; return }
                usleep(100_000)
            }
            tunnel.close()
            DispatchQueue.main.async { completion(.failure(SSHError.timedOut("The SSH tunnel to \(destination) didn't come up in time."))) }
        }
    }

    private init(destination: String, localPort: UInt16, remoteHost: String, remotePort: Int) {
        self.localPort = localPort
        process = Process()
        // Run ssh under a tiny shell that kills it once our lifeline pipe reaches EOF, so tunnels never outlive vncx.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // (Background jobs get /dev/null as stdin, so the lifeline is duplicated to fd 3 first.)
        let script = #"exec 3<&0; /usr/bin/ssh "$@" </dev/null & p=$!; { read _ <&3; kill $p 2>/dev/null; } & w=$!; wait $p; s=$?; kill $w 2>/dev/null; exit $s"#
        process.arguments = ["-c", script, "vncx-ssh-tunnel", "-N", "-o", "ExitOnForwardFailure=yes",
                             "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)"] + SSH.baseArguments(destination)
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = lifeline
    }

    func close() {
        try? lifeline.fileHandleForWriting.close()
    }

    deinit { close() }

    private static func freeLocalPort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: addr.sin_port)
    }

    private static func canConnect(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
