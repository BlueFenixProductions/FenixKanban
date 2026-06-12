import Foundation

// MARK: - ParseError

enum ParseError: Error, Equatable {
    case unknownCommand(String)
    case missingArgument(String)
    case missingCredentials(String)
    case unknownFlag(String)
}

// MARK: - Command

enum Command: Equatable {
    case boards
    case cards(boardID: String)
    case get(path: String)
    case post(path: String, body: String?)
    case put(path: String, body: String?)
    case delete(path: String)
    case capture(path: String, outFile: String)

    /// Parse `argv[1...]` (drop the executable name) into a `Command`.
    static func parse(_ args: [String]) -> Result<Command, ParseError> {
        guard !args.isEmpty else {
            return .failure(.missingArgument("subcommand"))
        }

        let sub = args[0]

        switch sub {
        case "boards":
            return .success(.boards)

        case "cards":
            guard args.count >= 2 else {
                return .failure(.missingArgument("<boardID>"))
            }
            return .success(.cards(boardID: args[1]))

        case "get":
            guard args.count >= 2 else {
                return .failure(.missingArgument("<path>"))
            }
            return .success(.get(path: args[1]))

        case "post":
            guard args.count >= 2 else {
                return .failure(.missingArgument("<path>"))
            }
            let body = extractBody(from: Array(args.dropFirst(2)))
            if case .failure(let e) = body { return .failure(e) }
            return .success(.post(path: args[1], body: try? body.get()))

        case "put":
            guard args.count >= 2 else {
                return .failure(.missingArgument("<path>"))
            }
            let body = extractBody(from: Array(args.dropFirst(2)))
            if case .failure(let e) = body { return .failure(e) }
            return .success(.put(path: args[1], body: try? body.get()))

        case "delete":
            guard args.count >= 2 else {
                return .failure(.missingArgument("<path>"))
            }
            return .success(.delete(path: args[1]))

        case "capture":
            guard args.count >= 2 else {
                return .failure(.missingArgument("<path>"))
            }
            let path = args[1]
            guard let outIdx = args.firstIndex(of: "--out"), outIdx + 1 < args.count else {
                return .failure(.missingArgument("--out <file>"))
            }
            return .success(.capture(path: path, outFile: args[outIdx + 1]))

        default:
            return .failure(.unknownCommand(sub))
        }
    }

    // MARK: - Helpers

    /// Extract `--body '<json>'` from remaining arguments. Returns `nil` if
    /// `--body` is absent (valid for some verbs). Returns `.failure` if the
    /// flag appears without a value, or an unknown flag is encountered.
    private static func extractBody(from args: [String]) -> Result<String?, ParseError> {
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--body" {
                guard i + 1 < args.count else {
                    return .failure(.missingArgument("--body <json>"))
                }
                return .success(args[i + 1])
            } else if arg.hasPrefix("--") {
                return .failure(.unknownFlag(arg))
            }
            i += 1
        }
        return .success(nil)
    }
}

// MARK: - Credentials

struct FizzyctlCredentials {
    let token: String
    let account: String
    let baseURL: URL

    static let usageHint = """
        fizzyctl: missing credentials.
        Set FIZZY_TOKEN, FIZZY_ACCOUNT, and optionally FIZZY_BASE_URL (default https://fizzy.bluefenix.net).
        """

    /// Load from environment (or .env file in cwd for any unset vars).
    /// Returns nil if any required credential is missing.
    static func load(env: [String: String] = ProcessInfo.processInfo.environment,
                     dotEnvPath: String? = nil) -> FizzyctlCredentials? {
        var merged = env

        // Parse .env for any vars not already set
        let envPath = dotEnvPath ?? ".env"
        if let content = try? String(contentsOfFile: envPath, encoding: .utf8) {
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let val = String(parts[1]).trimmingCharacters(in: .whitespaces)
                // Only set if not already in env
                if merged[key] == nil {
                    merged[key] = val
                }
            }
        }

        guard let token = merged["FIZZY_TOKEN"], !token.isEmpty,
              let account = merged["FIZZY_ACCOUNT"], !account.isEmpty else {
            return nil
        }

        let baseURLString = merged["FIZZY_BASE_URL"] ?? "https://fizzy.bluefenix.net"
        guard let baseURL = URL(string: baseURLString) else {
            return nil
        }

        return FizzyctlCredentials(token: token, account: account, baseURL: baseURL)
    }
}
