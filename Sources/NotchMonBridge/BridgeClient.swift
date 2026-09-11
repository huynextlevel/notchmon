import Foundation

/// Sends one event to the app and gets out of the way.
///
/// **Every path here is bounded, and that is the whole design.** This code runs
/// inside the agent's own process tree, and the agent waits for it. A hook that
/// blocks blocks the person's work — so a missing app, a dead app, a full
/// buffer and a half-open socket all have to end in a fast return rather than
/// in a wait. Nothing here retries.
public enum BridgeClient {
    /// Generous for a local socket and short enough that nobody notices it.
    public static let timeout = timeval(tv_sec: 0, tv_usec: 250_000)

    @discardableResult
    public static func send(_ event: HookEvent, to path: String = Bridge.socketPath) -> Bool {
        guard path.utf8.count <= Bridge.maxPathLength else { return false }
        guard var payload = try? JSONEncoder.bridge.encode(event) else { return false }
        payload.append(0x0A)  // newline-framed: the server reads a line at a time

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var send = timeout
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send, socklen_t(MemoryLayout<timeval>.size))
        var recv = timeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { raw in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(raw).assumingMemoryBound(to: CChar.self),
                        src, Bridge.maxPathLength)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        // Not an error worth reporting: the app simply is not running, which is
        // the ordinary case for anyone who has the hooks installed and the app
        // quit.
        guard connected == 0 else { return false }

        return payload.withUnsafeBytes { buffer -> Bool in
            var sent = 0
            while sent < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                // A short write that cannot make progress is a stalled reader.
                // Dropping the event is correct; waiting is not.
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }
}

extension JSONEncoder {
    /// One encoder configuration, shared, so a date written by the hook is a
    /// date the app can read.
    public static let bridge: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, target in
            var container = target.singleValueContainer()
            try container.encode(BridgeDate.precise.string(from: date))
        }
        return encoder
    }()
}

/// Whole seconds are not enough, and this was measured rather than reasoned
/// about.
///
/// `JSONEncoder.dateEncodingStrategy = .iso8601` writes `2026-09-09T20:25:31Z`
/// — no fraction. Two agents that stop within the same second therefore arrive
/// carrying the *same* instant, "which one has waited longest" has no answer,
/// and the tie falls through to session id, which is alphabetical and means
/// nothing. Seen on the real strip: the session that stopped second was the one
/// the lozenge named.
public enum BridgeDate {
    public static let precise: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole = ISO8601DateFormatter()

    /// Reads both spellings. The hook and the app ship in one bundle and cannot
    /// normally disagree, but a decode that fails is an event dropped in
    /// silence — a session that simply never appears — and that is too quiet a
    /// failure to leave to an assumption about deployment.
    public static func parse(_ text: String) -> Date? {
        precise.date(from: text) ?? whole.date(from: text)
    }
}

extension JSONDecoder {
    public static let bridge: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { source in
            let text = try source.singleValueContainer().decode(String.self)
            guard let date = BridgeDate.parse(text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: source.codingPath, debugDescription: "not a date: \(text)"))
            }
            return date
        }
        return decoder
    }()
}
