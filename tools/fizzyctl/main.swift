import Foundation

// fizzyctl — thin I/O shell for live Fizzy API probes.
//
// Usage:
//   fizzyctl boards
//   fizzyctl cards <boardID>
//   fizzyctl get <path>
//   fizzyctl post <path> [--body '<json>']
//   fizzyctl put <path>  [--body '<json>']
//   fizzyctl delete <path>
//   fizzyctl capture <path> --out <file>
//
// Credentials: FIZZY_TOKEN, FIZZY_ACCOUNT, FIZZY_BASE_URL (env or .env in cwd).
// Exit 2: missing credentials. Exit 1: HTTP/decode error.

// MARK: - Helpers (declared before top-level execution so they're in scope)

enum RawError: Error {
    case badURL(String)
    case notHTTP
    case httpError(Int, String)
}

/// Build an absolute URL for a path the same way FizzyClient does:
/// account-slug prefix except for /my/ paths.
func buildURL(path: String, creds: FizzyctlCredentials) throws -> URL {
    let normalizedAccount = creds.account.hasPrefix("/")
        ? String(creds.account.dropFirst())
        : creds.account
    let prefix = path.hasPrefix("/my/") ? "" : "/\(normalizedAccount)"
    let combined = "\(prefix)\(path)"
    guard let url = URL(string: combined, relativeTo: creds.baseURL)?.absoluteURL else {
        throw RawError.badURL(combined)
    }
    return url
}

/// Parse `Link: <url>; rel="next"` and validate same-origin.
func nextPageURL(from linkHeader: String?, base: URL) -> URL? {
    guard let linkHeader else { return nil }
    for segment in linkHeader.split(separator: ",") {
        let parts = segment.split(separator: ";")
        guard let target = parts.first?.trimmingCharacters(in: .whitespaces),
              target.hasPrefix("<"), target.hasSuffix(">") else { continue }
        let isNext = parts.dropFirst().contains {
            $0.trimmingCharacters(in: .whitespaces) == "rel=\"next\""
        }
        guard isNext, let next = URL(string: String(target.dropFirst().dropLast())) else { continue }
        guard next.scheme == base.scheme,
              next.host?.lowercased() == base.host?.lowercased(),
              next.port == base.port else { return nil }
        return next
    }
    return nil
}

/// Pretty-print JSON data to stdout; fall back to raw output on parse failure.
func printJSON(_ data: Data) {
    if let obj = try? JSONSerialization.jsonObject(with: data),
       let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: pretty, encoding: .utf8) {
        print(str)
    } else if let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

/// GET a path; pretty-print JSON to stdout; headers to stderr.
func rawGET(path: String, creds: FizzyctlCredentials) async throws {
    let url = try buildURL(path: path, creds: creds)
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else { throw RawError.notHTTP }

    let interestingHeaders = ["ETag", "Link", "Retry-After"]
    for h in interestingHeaders {
        if let v = http.value(forHTTPHeaderField: h) {
            fputs("\(h): \(v)\n", stderr)
        }
    }
    fputs("HTTP \(http.statusCode)\n", stderr)

    printJSON(data)

    if !(200...299).contains(http.statusCode) {
        throw RawError.httpError(http.statusCode, "")
    }
}

/// POST / PUT / DELETE a path with optional JSON body.
func rawMethod(_ method: String, path: String, bodyStr: String?, creds: FizzyctlCredentials) async throws {
    let url = try buildURL(path: path, creds: creds)
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    if let bodyStr {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(bodyStr.utf8)
    }

    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else { throw RawError.notHTTP }

    let interestingHeaders = ["ETag", "Link", "Retry-After", "Location"]
    for h in interestingHeaders {
        if let v = http.value(forHTTPHeaderField: h) {
            fputs("\(h): \(v)\n", stderr)
        }
    }
    fputs("HTTP \(http.statusCode)\n", stderr)

    if !data.isEmpty {
        printJSON(data)
    }

    if !(200...299).contains(http.statusCode) {
        throw RawError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }
}

/// GET a path and write the raw body verbatim to a file.
func captureToFile(path: String, outFile: String, creds: FizzyctlCredentials) async throws {
    let url = try buildURL(path: path, creds: creds)
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else { throw RawError.notHTTP }

    fputs("HTTP \(http.statusCode)\n", stderr)
    if !(200...299).contains(http.statusCode) {
        throw RawError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    try data.write(to: URL(fileURLWithPath: outFile))
    fputs("Wrote \(data.count) bytes to \(outFile)\n", stderr)
}

/// Fetch columns for a board via GET /:account/boards/:id/columns.
/// FizzyClient wraps single-column GET but not the list endpoint.
func fetchColumnList(boardID: String, creds: FizzyctlCredentials) async throws -> [FizzyColumn] {
    let url = try buildURL(path: "/boards/\(boardID)/columns", creds: creds)
    var columns: [FizzyColumn] = []
    var nextURL: URL? = url

    while let pageURL = nextURL {
        var req = URLRequest(url: pageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RawError.notHTTP }
        guard http.statusCode == 200 else {
            throw RawError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let page = try decoder.decode([FizzyColumn].self, from: data)
        columns += page
        nextURL = nextPageURL(from: http.value(forHTTPHeaderField: "Link"), base: creds.baseURL)
    }
    return columns
}

/// Dispatch a parsed command against the Fizzy API.
func run(command: Command, client: FizzyClient, creds: FizzyctlCredentials) async throws {
    switch command {

    case .boards:
        let boards = try await client.boards()
        for b in boards {
            print("\(b.id)\t\(b.name)")
        }

    case .cards(let boardID):
        let columns = try await fetchColumnList(boardID: boardID, creds: creds)
        for col in columns {
            let cards = try await client.cards(boardID: boardID, columnID: col.id)
            for card in cards {
                let closed = card.closed == true ? " [closed]" : ""
                print("\(col.name)\t#\(card.number)\t\(card.title)\(closed)")
            }
        }

    case .get(let path):
        try await rawGET(path: path, creds: creds)

    case .post(let path, let bodyStr):
        try await rawMethod("POST", path: path, bodyStr: bodyStr, creds: creds)

    case .put(let path, let bodyStr):
        try await rawMethod("PUT", path: path, bodyStr: bodyStr, creds: creds)

    case .delete(let path):
        try await rawMethod("DELETE", path: path, bodyStr: nil, creds: creds)

    case .capture(let path, let outFile):
        try await captureToFile(path: path, outFile: outFile, creds: creds)
    }
}

// MARK: - Entry point (top-level execution)

let usageText = """
Usage: fizzyctl <subcommand> [args]

Subcommands:
  boards                         List boards (id, name)
  cards <boardID>                Cards per column (column/number/title)
  get <path>                     Raw GET; JSON to stdout, headers to stderr
  post <path> [--body '<json>']  Raw POST
  put <path>  [--body '<json>']  Raw PUT
  delete <path>                  Raw DELETE
  capture <path> --out <file>    GET and write body to file

Credentials (env or .env in cwd):
  FIZZY_TOKEN      API token
  FIZZY_ACCOUNT    Account slug (e.g. /897362094)
  FIZZY_BASE_URL   Base URL (default: https://fizzy.bluefenix.net)

"""

let args = Array(CommandLine.arguments.dropFirst())

let command: Command
switch Command.parse(args) {
case .success(let cmd):
    command = cmd
case .failure(let err):
    switch err {
    case .unknownCommand(let name):
        fputs("fizzyctl: unknown subcommand '\(name)'\n", stderr)
        fputs(usageText, stderr)
        exit(1)
    case .missingArgument(let what):
        fputs("fizzyctl: missing \(what)\n", stderr)
        fputs(usageText, stderr)
        exit(1)
    case .missingCredentials(let what):
        fputs("fizzyctl: missing \(what)\n", stderr)
        fputs(FizzyctlCredentials.usageHint + "\n", stderr)
        exit(2)
    case .unknownFlag(let flag):
        fputs("fizzyctl: unknown flag '\(flag)'\n", stderr)
        fputs(usageText, stderr)
        exit(1)
    }
}

guard let creds = FizzyctlCredentials.load() else {
    fputs(FizzyctlCredentials.usageHint + "\n", stderr)
    exit(2)
}

let client = FizzyClient(
    baseURL: creds.baseURL,
    accessToken: creds.token,
    accountSlug: creds.account
)

// Run async work from synchronous entry point via semaphore.
let sema = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

Task {
    do {
        try await run(command: command, client: client, creds: creds)
    } catch {
        fputs("fizzyctl: \(error)\n", stderr)
        exitCode = 1
    }
    sema.signal()
}

sema.wait()
exit(exitCode)
