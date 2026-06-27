import Testing
@testable import FenixKanban

@Suite("CloudKit dev schema-init gate (#20)")
struct CloudKitSchemaInitGateTests {

    @Test("flag present, not under test → true")
    func flagPresentNotUnderTest() {
        let arguments = ["-dev-init-cloudkit-schema"]
        let environment: [String: String] = [:]
        #expect(PersistenceController.shouldInitializeCloudKitSchema(arguments: arguments, environment: environment) == true)
    }

    @Test("flag absent → false")
    func flagAbsent() {
        let arguments: [String] = []
        let environment: [String: String] = [:]
        #expect(PersistenceController.shouldInitializeCloudKitSchema(arguments: arguments, environment: environment) == false)
    }

    @Test("under XCTest even with flag → false")
    func underXCTestEvenWithFlag() {
        let arguments = ["-dev-init-cloudkit-schema"]
        let environment = ["XCTestConfigurationFilePath": "/tmp/x"]
        #expect(PersistenceController.shouldInitializeCloudKitSchema(arguments: arguments, environment: environment) == false)
    }
}
