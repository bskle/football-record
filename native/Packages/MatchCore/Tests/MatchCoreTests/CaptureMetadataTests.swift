import Foundation
import XCTest
@testable import MatchCore

final class CaptureMetadataTests: XCTestCase {
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    var binding: CaptureBinding { get throws { try CaptureBinding(matchID: "match", recordingDeviceID: "watch") } }

    func roundTrip<T: Codable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(T.self, from: encoder.encode(value))
    }
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: Data(json.utf8))
    }
    func assertInvalid<T>(_ expected: CaptureMetadataError, _ operation: @autoclosure () throws -> T,
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? CaptureMetadataError, expected, file: file, line: line)
        }
    }
    func segment(_ id: String = "segment", binding: CaptureBinding? = nil,
                 workoutID: String = "workout") throws -> CaptureSegment {
        try CaptureSegment(id: id, binding: binding ?? self.binding, workoutID: workoutID,
                           window: CaptureWindow(start: epoch, end: epoch.addingTimeInterval(30)))
    }
    func gap(_ id: String = "gap", binding: CaptureBinding? = nil) throws -> CaptureGap {
        try CaptureGap(id: id, binding: binding ?? self.binding, window: CaptureWindow(start: nil, end: nil))
    }

    func testRecoveryKeepsOriginalIdentityAcrossWorkoutsAndGap() throws {
        let first = try segment("first", workoutID: "original-workout")
        let recovered = try CaptureSegment(id: "recovered", binding: binding, workoutID: "new-workout",
            window: CaptureWindow(start: epoch.addingTimeInterval(65), end: nil))
        let missing = try CaptureGap(id: "recovery-gap", binding: binding,
            window: CaptureWindow(start: epoch.addingTimeInterval(30), end: epoch.addingTimeInterval(65)))
        let metadata = try CaptureMetadata(binding: binding, segments: [first, recovered], gaps: [missing])
        let restored = try roundTrip(metadata)
        XCTAssertEqual(restored, metadata)
        XCTAssertEqual(restored.binding.matchID, "match")
        XCTAssertEqual(restored.binding.recordingDeviceID, "watch")
        XCTAssertEqual(restored.segments.map(\.workoutID), ["original-workout", "new-workout"])
        XCTAssertEqual(restored.gaps.first?.window, missing.window)
        XCTAssertNil(restored.segments.last?.window.end)
    }

    func testUnknownAndOneSidedBoundariesStayUnknownThroughCoding() throws {
        for (start, end) in [(nil, nil), (nil, epoch), (epoch, nil), (epoch, epoch)] as [(Date?, Date?)] {
            let window = try CaptureWindow(start: start, end: end)
            let segment = try CaptureSegment(id: "observed", binding: binding, workoutID: "known-workout", window: window)
            let gap = try CaptureGap(id: "missing", binding: binding, window: window)
            let decoded = try roundTrip(CaptureMetadata(binding: binding, segments: [segment], gaps: [gap]))
            XCTAssertEqual(decoded.segments[0].window.start, start)
            XCTAssertEqual(decoded.segments[0].window.end, end)
            XCTAssertEqual(decoded.gaps[0].window.start, start)
            XCTAssertEqual(decoded.gaps[0].window.end, end)
        }
    }

    func testContainerRejectsForeignMatchOrDeviceOnSegmentsAndGaps() throws {
        for foreign in [try CaptureBinding(matchID: "other-match", recordingDeviceID: "watch"),
                        try CaptureBinding(matchID: "match", recordingDeviceID: "other-watch")] {
            assertInvalid(.mismatchedBinding, try CaptureMetadata(binding: binding,
                segments: [segment(binding: foreign)], gaps: []))
            assertInvalid(.mismatchedBinding, try CaptureMetadata(binding: binding,
                segments: [], gaps: [gap(binding: foreign)]))
        }
    }

    func testConstructorsRejectNonFiniteOrInvertedBoundaries() throws {
        for invalid in [Double.infinity, -.infinity, .nan] {
            let date = Date(timeIntervalSince1970: invalid)
            assertInvalid(.nonFiniteBoundary, try CaptureWindow(start: date, end: nil))
            assertInvalid(.nonFiniteBoundary, try CaptureWindow(start: nil, end: date))
        }
        assertInvalid(.invertedWindow, try CaptureWindow(start: epoch, end: epoch.addingTimeInterval(-1)))
        XCTAssertNoThrow(try CaptureWindow(start: epoch, end: epoch))
    }

    func testConstructorsRejectEmptyIDsAndAmbiguousStableIDs() throws {
        for empty in ["", " \n"] {
            assertInvalid(.invalidIdentifier, try CaptureBinding(matchID: empty, recordingDeviceID: "watch"))
            assertInvalid(.invalidIdentifier, try CaptureBinding(matchID: "match", recordingDeviceID: empty))
            assertInvalid(.invalidIdentifier, try segment(empty))
            assertInvalid(.invalidIdentifier, try segment(workoutID: empty))
            assertInvalid(.invalidIdentifier, try gap(empty))
        }
        assertInvalid(.duplicateID, try CaptureMetadata(binding: binding, segments: [segment(), segment()], gaps: []))
        assertInvalid(.duplicateID, try CaptureMetadata(binding: binding, segments: [], gaps: [gap(), gap()]))
        assertInvalid(.duplicateID, try CaptureMetadata(binding: binding, segments: [segment("same")], gaps: [gap("same")]))
    }

    func testDecodingRechecksNestedIdentifiersAndWindowOrder() throws {
        assertInvalid(.invalidIdentifier, try decode(CaptureBinding.self,
            #"{"matchID":"","recordingDeviceID":"watch"}"#))
        assertInvalid(.invalidIdentifier, try decode(CaptureSegment.self,
            #"{"id":"s","binding":{"matchID":"match","recordingDeviceID":"watch"},"workoutID":" ","window":{}}"#))
        assertInvalid(.invalidIdentifier, try decode(CaptureGap.self,
            #"{"id":"","binding":{"matchID":"match","recordingDeviceID":"watch"},"window":{}}"#))
        assertInvalid(.invertedWindow, try decode(CaptureWindow.self, #"{"start":20,"end":10}"#))
    }

    func testDecodingRechecksContainerBindingsAndDuplicateIDs() throws {
        let scope = #"{"matchID":"match","recordingDeviceID":"watch"}"#
        let foreign = #"{"matchID":"other","recordingDeviceID":"watch"}"#
        let segment = #"{"id":"s","binding":BINDING,"workoutID":"w","window":{}}"#
        assertInvalid(.mismatchedBinding, try decode(CaptureMetadata.self,
            "{\"binding\":\(scope),\"segments\":[\(segment.replacingOccurrences(of: "BINDING", with: foreign))],\"gaps\":[]}"))
        let valid = segment.replacingOccurrences(of: "BINDING", with: scope)
        assertInvalid(.duplicateID, try decode(CaptureMetadata.self,
            "{\"binding\":\(scope),\"segments\":[\(valid),\(valid)],\"gaps\":[]}"))
        assertInvalid(.mismatchedBinding, try decode(CaptureMetadata.self,
            "{\"binding\":\(scope),\"segments\":[],\"gaps\":[{\"id\":\"g\",\"binding\":\(foreign),\"window\":{}}]}"))
    }

    func testDecoderRejectsNonFiniteBoundaryEvenWhenTransportAllowsIt() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return Date(timeIntervalSince1970: text == "Infinity" ? .infinity : .nan)
        }
        for json in [#"{"start":"Infinity"}"#, #"{"end":"NaN"}"#] {
            assertInvalid(.nonFiniteBoundary, try decoder.decode(CaptureWindow.self, from: Data(json.utf8)))
        }
        XCTAssertThrowsError(try decode(CaptureWindow.self, #"{"start":"yesterday"}"#))
        XCTAssertThrowsError(try decode(CaptureSegment.self,
            #"{"id":"s","binding":{"matchID":"match","recordingDeviceID":"watch"},"workoutID":42,"window":{}}"#))
    }
}
