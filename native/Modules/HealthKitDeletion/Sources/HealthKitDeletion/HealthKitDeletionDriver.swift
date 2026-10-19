import Foundation
#if os(iOS) || os(watchOS)
import HealthKit
#endif

/// SDK execution must be explicitly enabled by the separately accepted integration.
/// Initializing this value never creates a HealthStore or asks for authorization.
public struct HealthKitDeletionDriver: HealthDeletionDriver {
    private let executionEnabled: Bool
    public init(executionEnabled: Bool = false) { self.executionEnabled=executionEnabled }
    public func delete(_ attempt: HealthDeletionDriverAttempt,completion: @escaping @Sendable (HealthDeletionDriverOutcome) -> Void) {
        guard executionEnabled else { completion(.failure(.unavailable));return }
        #if os(iOS) || os(watchOS)
        do {
            guard try attempt.request.selectionDigest() == attempt.selectionDigest else { throw HealthDeletionIssue.identityConflict }
            let source=HKSource.default()
            let plan=try HealthDeletionPredicatePlan(request:attempt.request,currentSourceBundleID:source.bundleIdentifier)
            guard HKHealthStore.isHealthDataAvailable() else { throw HealthDeletionIssue.unavailable }
            let store=HKHealthStore(),type=HKObjectType.workoutType()
            // This status describes sharing/write authorization only, never read permission.
            switch store.authorizationStatus(for:type) {
            case .sharingAuthorized: break
            case .sharingDenied: throw HealthDeletionIssue.authorizationDenied
            default: throw HealthDeletionIssue.authorizationNotDetermined
            }
            let branches=plan.targets.map { target in
                NSCompoundPredicate(andPredicateWithSubpredicates:[
                    HKQuery.predicateForObject(with:target.workoutUUID),
                    HKQuery.predicateForObjects(withMetadataKey:"app.football-record.match-id",allowedValues:[target.matchID]),
                    HKQuery.predicateForObjects(withMetadataKey:"app.football-record.recording-device-id",allowedValues:[target.recordingDeviceID]),
                    HKQuery.predicateForObjects(withMetadataKey:"app.football-record.segment-token",allowedValues:[target.segmentToken])
                ])
            }
            let predicate=NSCompoundPredicate(andPredicateWithSubpredicates:[
                HKQuery.predicateForObjects(from:source),NSCompoundPredicate(orPredicateWithSubpredicates:branches)
            ])
            // No read query, broad fallback predicate or requestAuthorization call exists.
            store.deleteObjects(of:type,predicate:predicate) { success,count,error in
                _=store // Keep the store alive through the actual callback.
                if let error {
                    let ns=error as NSError
                    if ns.domain == HKErrorDomain,ns.code == HKError.Code.errorAuthorizationDenied.rawValue { completion(.failure(.authorizationDenied)) }
                    else if ns.domain == HKErrorDomain,ns.code == HKError.Code.errorAuthorizationNotDetermined.rawValue { completion(.failure(.authorizationNotDetermined)) }
                    else { completion(.failure(.unavailable)) }
                } else if success { completion(.success(deletedObjectCount:count)) }
                else { completion(.failure(.invalidResponse)) }
            }
        } catch { completion(.failure((error as? HealthDeletionIssue) ?? .invalidRequest)) }
        #else
        completion(.failure(.unavailable))
        #endif
    }
}
