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
    /// RED stub — always returns .failure so tests fail predictably.
    static func parse(_ args: [String]) -> Result<Command, ParseError> {
        return .failure(.unknownCommand("not implemented"))
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

    static func load(env: [String: String] = ProcessInfo.processInfo.environment,
                     dotEnvPath: String? = nil) -> FizzyctlCredentials? {
        return nil
    }
}
