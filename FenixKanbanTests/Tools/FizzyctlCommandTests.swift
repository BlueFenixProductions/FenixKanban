import Testing
import Foundation

// Note: FizzyctlCommand.swift is compiled into FenixKanbanTests directly
// via an explicit source entry in project.yml (not via @testable import,
// since fizzyctl is a separate tool target with no test host).

@Suite("FizzyctlCommand — parse/route/error cases")
struct FizzyctlCommandTests {

    // MARK: - boards

    @Test("boards: no args → .boards")
    func boardsCommand() {
        let result = Command.parse(["boards"])
        #expect(result == .success(.boards))
    }

    // MARK: - cards

    @Test("cards: with boardID → .cards(boardID:)")
    func cardsCommand() {
        let result = Command.parse(["cards", "abc123"])
        #expect(result == .success(.cards(boardID: "abc123")))
    }

    @Test("cards: missing boardID → missingArgument")
    func cardsMissingBoardID() {
        let result = Command.parse(["cards"])
        #expect(result == .failure(.missingArgument("<boardID>")))
    }

    // MARK: - get

    @Test("get: with path → .get(path:)")
    func getCommand() {
        let result = Command.parse(["get", "/boards"])
        #expect(result == .success(.get(path: "/boards")))
    }

    @Test("get: missing path → missingArgument")
    func getMissingPath() {
        let result = Command.parse(["get"])
        #expect(result == .failure(.missingArgument("<path>")))
    }

    // MARK: - post

    @Test("post: path only → body nil")
    func postNoBody() {
        let result = Command.parse(["post", "/boards"])
        #expect(result == .success(.post(path: "/boards", body: nil)))
    }

    @Test("post: with --body → body extracted")
    func postWithBody() {
        let result = Command.parse(["post", "/boards", "--body", #"{"name":"x"}"#])
        #expect(result == .success(.post(path: "/boards", body: #"{"name":"x"}"#)))
    }

    @Test("post: --body flag with no value → missingArgument")
    func postBodyNoValue() {
        let result = Command.parse(["post", "/boards", "--body"])
        #expect(result == .failure(.missingArgument("--body <json>")))
    }

    @Test("post: unknown flag → unknownFlag")
    func postUnknownFlag() {
        let result = Command.parse(["post", "/boards", "--verbose"])
        #expect(result == .failure(.unknownFlag("--verbose")))
    }

    @Test("post: missing path → missingArgument")
    func postMissingPath() {
        let result = Command.parse(["post"])
        #expect(result == .failure(.missingArgument("<path>")))
    }

    // MARK: - put

    @Test("put: path only → body nil")
    func putNoBody() {
        let result = Command.parse(["put", "/cards/1"])
        #expect(result == .success(.put(path: "/cards/1", body: nil)))
    }

    @Test("put: with --body → body extracted")
    func putWithBody() {
        let result = Command.parse(["put", "/cards/1", "--body", #"{"title":"t"}"#])
        #expect(result == .success(.put(path: "/cards/1", body: #"{"title":"t"}"#)))
    }

    @Test("put: missing path → missingArgument")
    func putMissingPath() {
        let result = Command.parse(["put"])
        #expect(result == .failure(.missingArgument("<path>")))
    }

    // MARK: - delete

    @Test("delete: with path → .delete(path:)")
    func deleteCommand() {
        let result = Command.parse(["delete", "/cards/42"])
        #expect(result == .success(.delete(path: "/cards/42")))
    }

    @Test("delete: missing path → missingArgument")
    func deleteMissingPath() {
        let result = Command.parse(["delete"])
        #expect(result == .failure(.missingArgument("<path>")))
    }

    // MARK: - capture

    @Test("capture: path + --out file → .capture")
    func captureCommand() {
        let result = Command.parse(["capture", "/boards", "--out", "boards.json"])
        #expect(result == .success(.capture(path: "/boards", outFile: "boards.json")))
    }

    @Test("capture: missing --out → missingArgument")
    func captureMissingOut() {
        let result = Command.parse(["capture", "/boards"])
        #expect(result == .failure(.missingArgument("--out <file>")))
    }

    @Test("capture: --out without value → missingArgument")
    func captureOutNoValue() {
        let result = Command.parse(["capture", "/boards", "--out"])
        #expect(result == .failure(.missingArgument("--out <file>")))
    }

    @Test("capture: missing path → missingArgument")
    func captureMissingPath() {
        let result = Command.parse(["capture"])
        #expect(result == .failure(.missingArgument("<path>")))
    }

    // MARK: - unknown command

    @Test("unknown subcommand → unknownCommand")
    func unknownCommand() {
        let result = Command.parse(["whoops"])
        #expect(result == .failure(.unknownCommand("whoops")))
    }

    @Test("empty args → missingArgument for subcommand")
    func emptyArgs() {
        let result = Command.parse([])
        #expect(result == .failure(.missingArgument("subcommand")))
    }

    // MARK: - FizzyctlCredentials

    @Test("credentials: all set from env")
    func credsFromEnv() {
        let env = [
            "FIZZY_TOKEN": "tok123",
            "FIZZY_ACCOUNT": "/897362094",
            "FIZZY_BASE_URL": "https://example.com"
        ]
        let creds = FizzyctlCredentials.load(env: env, dotEnvPath: "/dev/null")
        #expect(creds?.token == "tok123")
        #expect(creds?.account == "/897362094")
        #expect(creds?.baseURL == URL(string: "https://example.com")!)
    }

    @Test("credentials: missing token → nil")
    func credsMissingToken() {
        let env = ["FIZZY_ACCOUNT": "/abc"]
        let creds = FizzyctlCredentials.load(env: env, dotEnvPath: "/dev/null")
        #expect(creds == nil)
    }

    @Test("credentials: missing account → nil")
    func credsMissingAccount() {
        let env = ["FIZZY_TOKEN": "tok"]
        let creds = FizzyctlCredentials.load(env: env, dotEnvPath: "/dev/null")
        #expect(creds == nil)
    }

    @Test("credentials: default baseURL when FIZZY_BASE_URL unset")
    func credsDefaultBaseURL() {
        let env = ["FIZZY_TOKEN": "tok", "FIZZY_ACCOUNT": "/abc"]
        let creds = FizzyctlCredentials.load(env: env, dotEnvPath: "/dev/null")
        #expect(creds?.baseURL == URL(string: "https://fizzy.bluefenix.net")!)
    }
}
