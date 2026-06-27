import Foundation

extension PersistenceController {
    /// Gates a dev-only CloudKit schema-initialization run (issue #20) and is guarded off under XCTest.
    static func shouldInitializeCloudKitSchema(arguments: [String], environment: [String: String]) -> Bool {
        return arguments.contains("-dev-init-cloudkit-schema") && environment["XCTestConfigurationFilePath"] == nil
    }
}
