import Foundation

enum TokscaleError: LocalizedError {
    case binaryNotFound
    case timedOut(TimeInterval)
    case exited(Int32, String)
    case emptyOutput
    case undecodable(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "tokscale not found — run `make vendor` or set NOTCHMON_TOKSCALE"
        case .timedOut(let seconds):
            return "tokscale timed out after \(Int(seconds))s"
        case .exited(let code, let stderr):
            return "tokscale exited \(code): \(stderr.prefix(200))"
        case .emptyOutput:
            return "tokscale produced no output"
        case .undecodable(let detail):
            return "could not decode tokscale JSON: \(detail)"
        }
    }
}

/// Runs the vendored `tokscale` CLI and decodes its JSON.
///
/// An actor rather than a plain enum of statics: two overlapping refreshes must
/// not both spawn the scan, which is the expensive one — the store's poll timer
/// and a manual "Refresh now" can easily land together.
actor Tokscale {
    static let shared = Tokscale()

    private var cachedBinary: URL?

    // MARK: Locating the binary

    /// Search order, most explicit first. The vendored copy is checked before
    /// `PATH` so a global `npm i -g tokscale` of a different major version can
    /// never silently change what the notch reports.
    private func binary() throws -> URL {
        if let cached = cachedBinary { return cached }

        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["NOTCHMON_TOKSCALE"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        // Inside the built .app.
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("tokscale"))
        }
        // Running straight out of `swift run`, from the repo's vendor dir.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Usage
            .deletingLastPathComponent()  // NotchMon
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
        candidates.append(
            repo.appendingPathComponent("vendor/node_modules/@tokscale/cli-darwin-arm64/bin/tokscale")
        )
        candidates.append(
            repo.appendingPathComponent("vendor/node_modules/@tokscale/cli-darwin-x64/bin/tokscale")
        )
        candidates.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".notchmon/tokscale")
        )
        for path in ["/opt/homebrew/bin/tokscale", "/usr/local/bin/tokscale"] {
            candidates.append(URL(fileURLWithPath: path))
        }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            cachedBinary = candidate
            Log.usage.info("using tokscale at \(candidate.path, privacy: .public)")
            return candidate
        }
        throw TokscaleError.binaryNotFound
    }

    // MARK: Running

    /// Spawns tokscale and returns its stdout.
    ///
    /// Both pipes are drained on their own queues rather than read after
    /// `waitUntilExit`: a scan over a large `~/.claude/projects` can outrun the
    /// 64K pipe buffer, and a child blocked writing into a full pipe would
    /// never exit for us to read.
    private func run(_ arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = try binary()
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        // tokscale renders a spinner and colour when it thinks it has a TTY;
        // under a pipe it should not, but saying so costs nothing.
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        var stdout = Data()
        var stderr = Data()
        let lock = NSLock()
        let drained = DispatchGroup()

        for (pipe, isOut) in [(out, true), (err, false)] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isOut { stdout = data } else { stderr = data }
                lock.unlock()
                drained.leave()
            }
        }

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            // SIGTERM is a request; a wedged scan gets a second to honour it
            // before the pipes are closed out from under it.
            Thread.sleep(forTimeInterval: 1.0)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw TokscaleError.timedOut(timeout)
        }
        process.waitUntilExit()
        drained.wait()

        lock.lock()
        let capturedOut = stdout
        let capturedErr = stderr
        lock.unlock()

        guard process.terminationStatus == 0 else {
            let message = String(data: capturedErr, encoding: .utf8) ?? ""
            throw TokscaleError.exited(process.terminationStatus, message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !capturedOut.isEmpty else { throw TokscaleError.emptyOutput }
        return capturedOut
    }

    /// tokscale prefixes JSON with a progress line often enough that trusting
    /// the whole of stdout is not safe — so the payload is taken from the first
    /// `{` or `[` onward.
    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let start = data.firstIndex(where: { $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "[") })
        let payload = start.map { data[$0...] } ?? data[...]
        do {
            return try JSONDecoder().decode(T.self, from: Data(payload))
        } catch {
            let preview = String(data: Data(payload.prefix(300)), encoding: .utf8) ?? "<binary>"
            throw TokscaleError.undecodable("\(error) — \(preview)")
        }
    }

    // MARK: Queries

    /// Subscription quotas: the percentages the rings are drawn from.
    func quotas(timeout: TimeInterval = 45) throws -> [ProviderUsage] {
        let data = try run(["usage", "--json"], timeout: timeout)
        return try decode([ProviderUsage].self, from: data)
    }

    /// Today's token and cost scan, grouped so the expanded panel can list it
    /// per tool without a second pass.
    func todayScan(clients: String, timeout: TimeInterval = 90) throws -> ScanReport {
        var arguments = ["--json", "--group-by", "client,model", "--today", "--no-spinner"]
        if !clients.isEmpty {
            arguments.append(contentsOf: ["--client", clients])
        }
        let data = try run(arguments, timeout: timeout)
        return try decode(ScanReport.self, from: data)
    }

    /// A year of daily totals, for the activity grid.
    ///
    /// `graph` is tokscale's own contribution export, and it already buckets
    /// each day into an intensity 0…4. Taking its buckets rather than deriving
    /// our own is what keeps this grid agreeing with every other tool reading
    /// the same sessions.
    func graph(clients: String, timeout: TimeInterval = 90) throws -> GraphReport {
        var arguments = ["graph", "--no-spinner"]
        if !clients.isEmpty { arguments.append(contentsOf: ["--client", clients]) }
        return try decode(GraphReport.self, from: run(arguments, timeout: timeout))
    }

    /// Today's spend per project.
    ///
    /// `--merge-worktrees` folds git worktrees into the repository they belong
    /// to: three worktrees of one project are one project as far as "what ate
    /// the quota" is concerned. It is optional because it is the only part of
    /// this app that touches the filesystem — it has to resolve each workspace
    /// path to find its repository — and a sandboxed-out read of a protected
    /// folder does not fail, it *waits*. See `UsageStore.refreshScan`.
    func projectScan(
        clients: String,
        mergeWorktrees: Bool = true,
        timeout: TimeInterval = 90
    ) throws -> ProjectReport {
        var arguments = [
            "--json", "--group-by", "workspace,model", "--today",
            "--no-spinner"
        ]
        if mergeWorktrees { arguments.append("--merge-worktrees") }
        if !clients.isEmpty { arguments.append(contentsOf: ["--client", clients]) }
        return try decode(ProjectReport.self, from: run(arguments, timeout: timeout))
    }

    /// When each client was last active, from `tokscale hourly`.
    ///
    /// The scan has no timestamps at all — a session is a bag of token counts —
    /// but the hourly report lists which clients touched each hour, and the
    /// last hour a client appears in is exactly "when did I last use it". A
    /// week back is enough to order the strip and cheap enough to ask for.
    func recentActivity(timeout: TimeInterval = 60) throws -> [String: Date] {
        struct Entry: Decodable { let hour: String; let clients: [String] }
        struct Report: Decodable { let entries: [Entry] }
        let data = try run(["hourly", "--json", "--week"], timeout: timeout)
        let report = try decode(Report.self, from: data)
        // tokscale prints hours in local time, without a zone.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var latest: [String: Date] = [:]
        for entry in report.entries {
            guard let when = formatter.date(from: entry.hour) else { continue }
            for client in entry.clients where (latest[client] ?? .distantPast) < when {
                latest[client] = when
            }
        }
        return latest
    }

    /// The client ids this binary understands, parsed out of `--help`.
    ///
    /// Asked once and cached by the caller: passing a `--client` value tokscale
    /// does not know is a hard error, and the supported set grows with every
    /// release, so it has to be read from the binary rather than hardcoded.
    func supportedClients() throws -> [String] {
        let data = try run(["--help"], timeout: 15)
        guard let help = String(data: data, encoding: .utf8) else { return [] }
        guard let clientRange = help.range(of: "--client") else { return [] }
        let after = help[clientRange.lowerBound...]
        guard let open = after.range(of: "[possible values:"),
              let close = after[open.upperBound...].firstIndex(of: "]")
        else { return [] }
        return after[open.upperBound..<close]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
