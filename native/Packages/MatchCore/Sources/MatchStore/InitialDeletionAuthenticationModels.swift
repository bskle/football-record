import Foundation

public struct InitialDeletionRequestV1: Codable, Sendable, Equatable {
    public let creationID: String
    public let originalScope: CloudScopeV1
    public let cloud, local, health: ClientDeletionChoiceV4
    public let healthConfirmed: Bool
    public let confirmedAt: Int64
    public init(creationID: String, originalScope: CloudScopeV1, cloud: ClientDeletionChoiceV4,
        local: ClientDeletionChoiceV4, health: ClientDeletionChoiceV4, healthConfirmed: Bool, confirmedAt: Int64) throws {
        try AuthorityWire.identifier(creationID)
        _ = try CloudScopeV1(accountID: originalScope.accountID, cloudSpaceID: originalScope.cloudSpaceID,
            zoneID: originalScope.zoneID, activationEpoch: originalScope.activationEpoch)
        guard cloud == .keep, local == .delete, health == .keep, !healthConfirmed else { throw AuthorityError.unavailable }
        guard (0...253_402_300_799).contains(confirmedAt) else { throw AuthorityError.invalidWire }
        self.creationID = creationID; self.originalScope = originalScope
        self.cloud = cloud; self.local = local; self.health = health
        self.healthConfirmed = healthConfirmed; self.confirmedAt = confirmedAt
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: InitialDeletionKeyV1.self)
        guard Set(c.allKeys.map(\.stringValue)) == Set(["creationID", "originalScope", "cloud", "local", "health", "healthConfirmed", "confirmedAt"]) else { throw AuthorityError.invalidWire }
        try self.init(creationID: c.decode(String.self, forKey: .key("creationID")),
            originalScope: c.decode(CloudScopeV1.self, forKey: .key("originalScope")),
            cloud: c.decode(ClientDeletionChoiceV4.self, forKey: .key("cloud")),
            local: c.decode(ClientDeletionChoiceV4.self, forKey: .key("local")),
            health: c.decode(ClientDeletionChoiceV4.self, forKey: .key("health")),
            healthConfirmed: c.decode(Bool.self, forKey: .key("healthConfirmed")),
            confirmedAt: c.decode(Int64.self, forKey: .key("confirmedAt")))
    }
}
public enum InitialDeletionPhaseV1: String, Codable, Sendable { case preparing, associated, reserved, consumed }
public enum InitialDeletionResolutionV1: String, Codable, Sendable { case notDispatched, knownAbandoned, knownExpired, knownRevoked }
public enum InitialDeletionIssueV1: Error, Sendable, Equatable {
    case capacity, unresolved, parentExists, alreadyReserved, missingReauthentication, stopped, recursiveStop
}
public struct InitialDeletionAttemptV1: Sendable {
    public let authRequestID, challengeRequestID: String
    public let authentication: AuthAttemptV4?
    public let resolution: InitialDeletionResolutionV1?
}
public struct InitialDeletionAssociationV1: Sendable {
    public let creationID, authRequestID, requestDigest: String
    public let receipt: VerifiedAuthorityReceiptV1
    /// Opaque server handle, not a signed grant or a local expiry assertion.
    public let opaqueReauthenticationID: String?
}
public struct InitialDeletionContextV1: Sendable {
    public let request: InitialDeletionRequestV1
    public let originalAuthentication: VerifiedLocalAuthenticationEvidenceV4
    public let phase: InitialDeletionPhaseV1
    public let attempts: [InitialDeletionAttemptV1]
    public let association: InitialDeletionAssociationV1?
    public let reservation: InitialDeletionReservationV1?
}
public struct InitialDeletionReservationV1: Sendable {
    public let request: InitialDeletionRequestV1
    public let identityGeneration: Int64
    public let originalAuthRequestID, originalAuthReceiptDigest: String
    public let initialAuthRequestID, initialAuthRequestDigest, initialAuthReceiptDigest: String
    public let opaqueReauthenticationID: String
}
public enum InitialDeletionAuthenticationOutcomeV1: Sendable {
    case associated(InitialDeletionAssociationV1), closed(InitialDeletionResolutionV1), unresolved
}
public protocol InitialDeletionAuthenticationRepositoryV1: Sendable {
    func syncRepositoryIdentity() async -> SyncRepositoryIdentity
    func initialDeletionContextV4(creationID: String, expectedIdentityGeneration: Int64) async throws -> InitialDeletionContextV1?
    func prepareInitialDeletionAuthenticationV4(request: InitialDeletionRequestV1, expectedSource: VerifiedLocalAuthenticationEvidenceV4, authRequestID: String, challengeRequestID: String) async throws -> InitialDeletionContextV1
    func saveInitialDeletionAttemptV4(creationID: String, authentication: AuthAttemptV4, expectedIdentityGeneration: Int64) async throws
    func acceptInitialDeletionAuthenticationV4(creationID: String, authRequestID: String, receipt: VerifiedAuthorityReceiptV1, opaqueReauthenticationID: String?, expectedIdentityGeneration: Int64) async throws
    func closePreparedInitialDeletionAttemptV4(creationID: String, authRequestID: String, expectedIdentityGeneration: Int64) async throws
    func resolveInitialDeletionAttemptV4(creationID: String, authRequestID: String, resolution: InitialDeletionResolutionV1, expectedIdentityGeneration: Int64) async throws
    func reserveInitialDeletionV4(creationID: String, expectedIdentityGeneration: Int64) async throws -> InitialDeletionReservationV1
}

struct InitialDeletionKeyV1: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    static func key(_ value: String) -> Self { Self(stringValue: value)! }
}
enum InitialDeletionWireV1 {
    static let prefix = "initial-delete-auth"
    static let namespace = "initial-delete-auth-v1:"
    static let maximumPayload = 65_536
    static let maximumTotal = 2 * 1024 * 1024
    static func same(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
    static func digest(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw AuthorityError.invalidWire }
    }
    static func generation(_ value: Int64) throws {
        guard (0...9_007_199_254_740_991).contains(value) else { throw AuthorityError.invalidWire }
    }
    static func container(_ decoder: any Decoder, kind: String, fields: Set<String>) throws -> KeyedDecodingContainer<InitialDeletionKeyV1> {
        let c = try decoder.container(keyedBy: InitialDeletionKeyV1.self)
        guard Set(c.allKeys.map(\.stringValue)).isSubset(of: fields.union(["version", "purpose", "recordType"])),
            try c.decode(Int.self, forKey: .key("version")) == 1,
            try c.decode(String.self, forKey: .key("purpose")) == "initialDelete.v1",
            try c.decode(String.self, forKey: .key("recordType")) == kind else { throw AuthorityError.invalidWire }
        return c
    }
    static func key(_ kind: String, _ authID: String) -> String { namespace + kind + ":" + AuthorityWire.hash(Data(authID.utf8)) }
}
struct StoredInitialDeletionSourceV1: Codable, Equatable {
    let binding: AccountBindingV4
    let identityGeneration: Int64
    let currentAuthRequestID: String
    let attempt: AuthAttemptV4
    let admissionGeneration: Int64
    let receiptRaw: Data
    init(_ source: VerifiedLocalAuthenticationEvidenceV4) {
        binding = source.binding; identityGeneration = source.identityGeneration
        currentAuthRequestID = source.currentAuthRequestID; attempt = source.attempt
        admissionGeneration = source.admissionGeneration; receiptRaw = source.receipt.raw
    }
    private enum CodingKeys: String, CodingKey { case binding, identityGeneration, currentAuthRequestID, attempt, admissionGeneration, receiptRaw }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        binding = try c.decode(AccountBindingV4.self, forKey: .binding)
        identityGeneration = try c.decode(Int64.self, forKey: .identityGeneration)
        currentAuthRequestID = try c.decode(String.self, forKey: .currentAuthRequestID)
        attempt = try c.decode(AuthAttemptV4.self, forKey: .attempt)
        admissionGeneration = try c.decode(Int64.self, forKey: .admissionGeneration)
        receiptRaw = try c.decode(Data.self, forKey: .receiptRaw)
        try validate()
    }
    func validate() throws {
        try InitialDeletionWireV1.generation(identityGeneration)
        try AuthorityWire.identifier(currentAuthRequestID)
        _ = try AccountBindingV4(accountID: binding.accountID, cloudSpaceID: binding.cloudSpaceID, deviceID: binding.deviceID,
            activationEpoch: binding.activationEpoch, role: binding.role, environment: binding.environment, suspended: binding.suspended)
        guard binding.role == .phone, !binding.suspended, identityGeneration == admissionGeneration,
            InitialDeletionWireV1.same(attempt.requestID, currentAuthRequestID),
            InitialDeletionWireV1.same(binding.deviceID, attempt.deviceID), InitialDeletionWireV1.same(binding.cloudSpaceID, attempt.cloudSpaceID),
            binding.environment == attempt.environment, receiptRaw.count <= 32_768 else { throw AuthorityError.intentMismatch }
    }
    func matches(_ source: VerifiedLocalAuthenticationEvidenceV4) throws -> Bool {
        try Canonical.data(self) == Canonical.data(Self(source))
    }
}
struct StoredInitialDeletionHeadV1: Codable, Equatable {
    let version = 1, purpose = "initialDelete.v1", recordType = "head"
    let request: InitialDeletionRequestV1
    let source: StoredInitialDeletionSourceV1
    var phase: InitialDeletionPhaseV1
    var selectedAuthRequestID: String?
    var parentIntentDigest: String?
    init(request: InitialDeletionRequestV1, source: StoredInitialDeletionSourceV1, phase: InitialDeletionPhaseV1 = .preparing,
        selectedAuthRequestID: String? = nil, parentIntentDigest: String? = nil) {
        self.request = request; self.source = source; self.phase = phase
        self.selectedAuthRequestID = selectedAuthRequestID; self.parentIntentDigest = parentIntentDigest
    }
    init(from decoder: any Decoder) throws {
        let c = try InitialDeletionWireV1.container(decoder, kind: "head", fields: ["request", "source", "phase", "selectedAuthRequestID", "parentIntentDigest"])
        self.init(request: try c.decode(InitialDeletionRequestV1.self, forKey: .key("request")), source: try c.decode(StoredInitialDeletionSourceV1.self, forKey: .key("source")),
            phase: try c.decode(InitialDeletionPhaseV1.self, forKey: .key("phase")), selectedAuthRequestID: try c.decodeIfPresent(String.self, forKey: .key("selectedAuthRequestID")),
            parentIntentDigest: try c.decodeIfPresent(String.self, forKey: .key("parentIntentDigest")))
        try validate()
    }
    func validate() throws {
        try source.validate()
        guard request.originalScope.accountID == source.binding.accountID, request.originalScope.cloudSpaceID == source.binding.cloudSpaceID,
            request.originalScope.activationEpoch == source.binding.activationEpoch else { throw AuthorityError.intentMismatch }
        if let selectedAuthRequestID { try AuthorityWire.identifier(selectedAuthRequestID) }
        if let parentIntentDigest { try InitialDeletionWireV1.digest(parentIntentDigest) }
        switch phase {
        case .preparing: guard selectedAuthRequestID == nil, parentIntentDigest == nil else { throw AuthorityError.invalidWire }
        case .associated, .reserved: guard selectedAuthRequestID != nil, parentIntentDigest == nil else { throw AuthorityError.invalidWire }
        case .consumed: guard selectedAuthRequestID != nil, parentIntentDigest != nil else { throw AuthorityError.invalidWire }
        }
    }
}
struct StoredInitialDeletionAttemptV1: Codable, Equatable {
    let version = 1, purpose = "initialDelete.v1", recordType = "attempt"
    let creationID: String
    let ordinal: Int
    let authRequestID, challengeRequestID: String
    var authentication: AuthAttemptV4?
    init(creationID: String, ordinal: Int, authRequestID: String, challengeRequestID: String, authentication: AuthAttemptV4? = nil) {
        self.creationID = creationID; self.ordinal = ordinal; self.authRequestID = authRequestID
        self.challengeRequestID = challengeRequestID; self.authentication = authentication
    }
    init(from decoder: any Decoder) throws {
        let c = try InitialDeletionWireV1.container(decoder, kind: "attempt", fields: ["creationID", "ordinal", "authRequestID", "challengeRequestID", "authentication"])
        self.init(creationID: try c.decode(String.self, forKey: .key("creationID")), ordinal: try c.decode(Int.self, forKey: .key("ordinal")),
            authRequestID: try c.decode(String.self, forKey: .key("authRequestID")), challengeRequestID: try c.decode(String.self, forKey: .key("challengeRequestID")),
            authentication: try c.decodeIfPresent(AuthAttemptV4.self, forKey: .key("authentication")))
        try validate()
    }
    func validate() throws {
        for id in [creationID, authRequestID, challengeRequestID] { try AuthorityWire.identifier(id) }
        guard (0..<16).contains(ordinal), authentication == nil || authentication?.requestID == authRequestID else { throw AuthorityError.invalidWire }
    }
}
struct StoredInitialDeletionResultV1: Codable, Equatable {
    let version = 1, purpose = "initialDelete.v1", recordType = "result"
    let creationID, authRequestID, requestDigest: String
    let receiptRaw: Data
    let opaqueReauthenticationID: String?
    init(creationID: String, authRequestID: String, requestDigest: String, receiptRaw: Data, opaqueReauthenticationID: String?) {
        self.creationID = creationID; self.authRequestID = authRequestID; self.requestDigest = requestDigest
        self.receiptRaw = receiptRaw; self.opaqueReauthenticationID = opaqueReauthenticationID
    }
    init(from decoder: any Decoder) throws {
        let c = try InitialDeletionWireV1.container(decoder, kind: "result", fields: ["creationID", "authRequestID", "requestDigest", "receiptRaw", "opaqueReauthenticationID"])
        self.init(creationID: try c.decode(String.self, forKey: .key("creationID")), authRequestID: try c.decode(String.self, forKey: .key("authRequestID")),
            requestDigest: try c.decode(String.self, forKey: .key("requestDigest")), receiptRaw: try c.decode(Data.self, forKey: .key("receiptRaw")),
            opaqueReauthenticationID: try c.decodeIfPresent(String.self, forKey: .key("opaqueReauthenticationID")))
        try validate()
    }
    func validate() throws {
        try AuthorityWire.identifier(creationID); try AuthorityWire.identifier(authRequestID); try InitialDeletionWireV1.digest(requestDigest)
        if let opaqueReauthenticationID { try AuthorityWire.identifier(opaqueReauthenticationID) }
        guard receiptRaw.count <= 32_768 else { throw InitialDeletionIssueV1.capacity }
    }
}
struct StoredInitialDeletionResolutionV1: Codable, Equatable {
    let version = 1, purpose = "initialDelete.v1", recordType = "resolution"
    let creationID, authRequestID: String
    let resolution: InitialDeletionResolutionV1
    init(creationID: String, authRequestID: String, resolution: InitialDeletionResolutionV1) { self.creationID = creationID; self.authRequestID = authRequestID; self.resolution = resolution }
    init(from decoder: any Decoder) throws {
        let c = try InitialDeletionWireV1.container(decoder, kind: "resolution", fields: ["creationID", "authRequestID", "resolution"])
        self.init(creationID: try c.decode(String.self, forKey: .key("creationID")), authRequestID: try c.decode(String.self, forKey: .key("authRequestID")), resolution: try c.decode(InitialDeletionResolutionV1.self, forKey: .key("resolution")))
        try AuthorityWire.identifier(creationID); try AuthorityWire.identifier(authRequestID)
    }
}
struct StoredInitialDeletionTerminalV1: Codable, Equatable {
    let version = 1, purpose = "initialDelete.v1", recordType = "terminal"
    let request: InitialDeletionRequestV1
    let sourceAuthRequestID, sourceReceiptDigest: String
    let sourceGeneration: Int64
    let selectedAuthRequestID, selectedRequestDigest, selectedReceiptDigest, parentIntentDigest, backendReceiptDigest: String
    init(request: InitialDeletionRequestV1, sourceAuthRequestID: String, sourceReceiptDigest: String, sourceGeneration: Int64,
        selectedAuthRequestID: String, selectedRequestDigest: String, selectedReceiptDigest: String, parentIntentDigest: String, backendReceiptDigest: String) {
        self.request = request; self.sourceAuthRequestID = sourceAuthRequestID; self.sourceReceiptDigest = sourceReceiptDigest; self.sourceGeneration = sourceGeneration
        self.selectedAuthRequestID = selectedAuthRequestID; self.selectedRequestDigest = selectedRequestDigest; self.selectedReceiptDigest = selectedReceiptDigest
        self.parentIntentDigest = parentIntentDigest; self.backendReceiptDigest = backendReceiptDigest
    }
    init(from decoder: any Decoder) throws {
        let c = try InitialDeletionWireV1.container(decoder, kind: "terminal", fields: ["request", "sourceAuthRequestID", "sourceReceiptDigest", "sourceGeneration", "selectedAuthRequestID", "selectedRequestDigest", "selectedReceiptDigest", "parentIntentDigest", "backendReceiptDigest"])
        self.init(request: try c.decode(InitialDeletionRequestV1.self, forKey: .key("request")), sourceAuthRequestID: try c.decode(String.self, forKey: .key("sourceAuthRequestID")), sourceReceiptDigest: try c.decode(String.self, forKey: .key("sourceReceiptDigest")), sourceGeneration: try c.decode(Int64.self, forKey: .key("sourceGeneration")), selectedAuthRequestID: try c.decode(String.self, forKey: .key("selectedAuthRequestID")), selectedRequestDigest: try c.decode(String.self, forKey: .key("selectedRequestDigest")), selectedReceiptDigest: try c.decode(String.self, forKey: .key("selectedReceiptDigest")), parentIntentDigest: try c.decode(String.self, forKey: .key("parentIntentDigest")), backendReceiptDigest: try c.decode(String.self, forKey: .key("backendReceiptDigest")))
        try AuthorityWire.identifier(sourceAuthRequestID); try AuthorityWire.identifier(selectedAuthRequestID)
        try InitialDeletionWireV1.generation(sourceGeneration)
        for digest in [sourceReceiptDigest, selectedRequestDigest, selectedReceiptDigest, parentIntentDigest, backendReceiptDigest] { try InitialDeletionWireV1.digest(digest) }
        guard Set([request.creationID, sourceAuthRequestID, selectedAuthRequestID]).count == 3 else { throw AuthorityError.conflict }
    }
}

/// Minted only by the original Saga SQL transaction; never Codable or exported.
struct InitialDeletionSagaConsumptionV1 {
    let creationID, sourceDigest, selectedAuthRequestID, intentDigest: String
}
