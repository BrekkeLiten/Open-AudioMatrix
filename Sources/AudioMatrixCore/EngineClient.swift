import Darwin
import Foundation

public enum EngineClient {
    nonisolated(unsafe) private static var verifiedEngineProtocol = false

    public static func send(_ command: EngineCommand) throws -> EngineResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw EngineClientError.connectFailed(errno)
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        EnginePaths.socketPath.withCString { cstr in
            _ = strncpy(&addr.sun_path.0, cstr, MemoryLayout.size(ofValue: addr.sun_path) - 1)
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw EngineClientError.connectFailed(errno)
        }

        let payload = try JSONEncoder().encode(command)
        try payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            let written = write(fd, base, payload.count)
            guard written == payload.count else {
                throw EngineClientError.writeFailed
            }
        }

        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        let bytesRead = read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else {
            throw EngineClientError.readFailed
        }

        let data = Data(buffer.prefix(bytesRead))
        let trimmed: Data
        if let newline = data.lastIndex(of: 0x0A) {
            trimmed = data.prefix(upTo: newline)
        } else {
            trimmed = data
        }

        return try JSONDecoder().decode(EngineResponse.self, from: trimmed)
    }

    public static func isEngineRunning() -> Bool {
        (try? send(.ping))?.ok == true
    }

    public static func ensureEngineRunning() throws {
        if isEngineRunning() {
            if verifiedEngineProtocol { return }
            if engineSupportsCurrentProtocol() {
                verifiedEngineProtocol = true
                return
            }
            try restartEngine()
            verifiedEngineProtocol = true
            return
        }

        try launchEngine()
        verifiedEngineProtocol = true
    }

    private static func engineSupportsCurrentProtocol() -> Bool {
        guard let response = try? send(.applyRouteChanges(add: [], remove: [])) else { return false }
        return response.ok
    }

    private static func restartEngine() throws {
        _ = try? send(.shutdown)
        for _ in 0..<30 {
            if !isEngineRunning() { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try launchEngine()
    }

    private static func launchEngine() throws {
        let candidates = engineBinaryCandidates()
        guard let executableURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw EngineClientError.engineBinaryNotFound
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = []
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        for _ in 0..<30 {
            if isEngineRunning() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw EngineClientError.engineStartTimeout
    }

    private static func engineBinaryCandidates() -> [URL] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let env = ProcessInfo.processInfo.environment
        var urls: [URL] = []

        if let override = env["OPENAUDIOMATRIX_ENGINE_PATH"] {
            urls.append(URL(fileURLWithPath: override))
        }

        // Engine bundled next to the app's main executable (Contents/MacOS/AudioMatrixEngine).
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            urls.append(executableDir.appendingPathComponent("AudioMatrixEngine"))
        }

        urls.append(contentsOf: [
            cwd.appendingPathComponent(".build/debug/AudioMatrixEngine"),
            cwd.appendingPathComponent(".build/release/AudioMatrixEngine"),
            // Engine sitting next to the .app (dev/dist layout).
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("AudioMatrixEngine"),
            URL(fileURLWithPath: "/usr/local/bin/AudioMatrixEngine"),
        ])
        return urls
    }
}

public enum EngineClientError: Error, CustomStringConvertible {
    case connectFailed(Int32)
    case writeFailed
    case readFailed
    case engineStartTimeout
    case engineBinaryNotFound

    public var description: String {
        switch self {
        case .connectFailed(let code):
            "Could not connect to engine at \(EnginePaths.socketPath): \(String(cString: strerror(code)))"
        case .writeFailed:
            "Failed to write command to engine"
        case .readFailed:
            "Failed to read response from engine"
        case .engineStartTimeout:
            "Timed out waiting for AudioMatrixEngine to start"
        case .engineBinaryNotFound:
            "Could not find AudioMatrixEngine binary. Build with `swift build` or set OPENAUDIOMATRIX_ENGINE_PATH."
        }
    }
}
