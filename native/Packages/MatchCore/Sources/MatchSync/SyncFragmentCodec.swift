import Foundation
import MatchStore

/// Shared wire validation lives below the service so Store never depends on MatchSync.
public enum SyncFragmentCodec {
    public static func encode(_ canonicalMessage: Data, kind: SyncMessageKind) throws -> [Data] {
        try SyncFragment.fragments(bytes: canonicalMessage, kind: kind).map { try $0.canonicalBytes() }
    }
}
