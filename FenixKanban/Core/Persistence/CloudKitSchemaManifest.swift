import CoreData

/// CloudKit schema-surface regression guard for issue #20: schema-additive changes must be deployed to the CloudKit Dashboard
/// before a CloudKit-enabled release, and this manifest trips a test when the surface diverges.
enum CloudKitSchemaManifest {
    static func surface(of model: NSManagedObjectModel) -> [String: [String]] {
        var result: [String: [String]] = [:]

        for entity in model.entities {
            guard let entityName = entity.name else { continue }

            var tokens: [String] = []

            // Process attributes
            for attribute in entity.attributesByName {
                let token = "a:\(attribute.key):\(attribute.value.attributeType.rawValue)"
                tokens.append(token)
            }

            // Process relationships
            for relationship in entity.relationshipsByName {
                let destinationEntityName = relationship.value.destinationEntity?.name ?? "?"
                let token = "r:\(relationship.key):\(destinationEntityName)"
                tokens.append(token)
            }

            // Sort tokens
            result[entityName] = tokens.sorted()
        }

        return result
    }

    // Pinned snapshot of the CloudKit-synced schema surface (model v9).
    // If a test trips on this, a schema-additive change shipped — run
    // initializeCloudKitSchema() + deploy to the CloudKit Dashboard before
    // any CloudKit-enabled release, then update this snapshot. See issue #20.
    static let expected: [String: [String]] = [
        "Board": [
            "a:colorHex:700",
            "a:createdAt:900",
            "a:id:1100",
            "a:modifiedAt:900",
            "a:name:700",
            "a:sortOrder:200",
            "r:columns:Column",
        ],
        "CachedComment": [
            "a:body:700",
            "a:cardFizzyNumber:300",
            "a:createdAt:900",
            "a:creatorName:700",
            "a:fizzyCommentID:700",
            "a:pendingWrite:800",
        ],
        "Card": [
            "a:assigneesData:1000",
            "a:cardDescription:700",
            "a:closedAt:900",
            "a:createdAt:900",
            "a:dueDate:900",
            "a:id:1100",
            "a:isCompleted:800",
            "a:isGolden:800",
            "a:isPinned:800",
            "a:isWatched:800",
            "a:lifecycleStatusRaw:700",
            "a:modifiedAt:900",
            "a:sortOrder:200",
            "a:title:700",
            "r:column:Column",
            "r:labels:Label",
            "r:steps:CardStep",
        ],
        "CardStep": [
            "a:completed:800",
            "a:content:700",
            "a:fizzyStepID:700",
            "a:pendingWrite:800",
            "a:sortOrder:200",
            "r:card:Card",
        ],
        "CardTombstone": [
            "a:deletedAt:900",
            "a:fizzyNumber:300",
        ],
        "Column": [
            "a:colorHex:700",
            "a:createdAt:900",
            "a:fizzyColumnID:700",
            "a:id:1100",
            "a:modifiedAt:900",
            "a:name:700",
            "a:sortOrder:200",
            "r:board:Board",
            "r:cards:Card",
        ],
        "ColumnTombstone": [
            "a:boardID:700",
            "a:deletedAt:900",
            "a:fizzyColumnID:700",
        ],
        "Label": [
            "a:colorHex:700",
            "a:createdAt:900",
            "a:id:1100",
            "a:name:700",
            "r:cards:Card",
        ],
    ]
}
