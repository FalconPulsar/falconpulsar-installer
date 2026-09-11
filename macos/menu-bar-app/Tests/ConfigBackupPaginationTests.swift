// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

import Foundation
import XCTest
@testable import FalconPulsarMenuBar

final class ConfigBackupPaginationTests: XCTestCase {
    func testSeriesImportCountsFailuresInsideSuccessfulBulkResponses() {
        let cases: [(String, Int)] = [
            (#"{"results":[{"status":"created"},{"status":"exists"}]}"#, 0),
            (#"{"results":[{"status":"created"},{"status":"error","error":"storage type conflict"}]}"#, 1),
            (#"{"results":[{"status":"updated"},{"status":"exists"}]}"#, 1),
            (#"{"results":[{"status":"created"}]}"#, 2),
            (#"{"results":null}"#, 2), ("{}", 2), ("{", 2),
            (#"{"results":[{"status":1},{"status":"exists"}]}"#, 2),
        ]
        for (json, failures) in cases {
            XCTAssertEqual(ConfigBackup.countSeriesImportErrors(Data(json.utf8), expectedCount: 2), failures, json)
        }
    }

    private func harvest(_ pages: [String], key: String = "series", cap: Int = 10_000) throws -> [String: Any] {
        var index = 0
        let data = try ConfigBackup.harvestPaginated(path: "/series", sectionKey: key, maxIterations: cap) { _ in
            guard index < pages.count else { throw URLError(.networkConnectionLost) }
            defer { index += 1 }
            return Data(pages[index].utf8)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testDefaultOffsetAdvancesByItemCountAndPreservesQuery() throws {
        var paths: [String] = []
        let data = try ConfigBackup.harvestPaginated(path: "/series?include_engineering=true", sectionKey: "series") { path in
            paths.append(path)
            return Data((paths.count == 1
                ? #"{"series":[{"id":1},{"id":2}],"has_more":true}"#
                : #"{"series":[{"id":3}],"has_more":false}"#).utf8)
        }
        XCTAssertEqual(paths, ["/series?include_engineering=true&limit=1000&offset=0",
                               "/series?include_engineering=true&limit=1000&offset=2"])
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(out["count"] as? Int, 3)
        XCTAssertEqual((out["series"] as? [[String: Int]])?.compactMap { $0["id"] }, [1, 2, 3])
    }

    func testExplicitOffsetAliasesBareArraysAndEmptyCompletion() throws {
        var paths: [String] = []
        _ = try ConfigBackup.harvestPaginated(path: "/series", sectionKey: "series") { path in
            paths.append(path)
            return Data((paths.count == 1
                ? #"{"items":[1],"has_more":true,"next_offset":17}"#
                : #"{"series":[],"has_more":false}"#).utf8)
        }
        XCTAssertEqual(paths.last, "/series?limit=1000&offset=17")
        XCTAssertEqual(try harvest([#"{"asset-types":[1,2]}"#], key: "asset_types")["count"] as? Int, 2)
        XCTAssertEqual(try harvest(["[1,2]"])["count"] as? Int, 2)
        XCTAssertEqual(try harvest([#"{"series":[]}"#])["count"] as? Int, 0)
    }

    func testLaterTransportAndParseFailuresDiscardCollectedPages() {
        let first = #"{"series":[1],"has_more":true}"#
        XCTAssertThrowsError(try harvest([first]))
        XCTAssertThrowsError(try harvest([first, "{"]))
        XCTAssertThrowsError(try harvest([first, #"{"error":"temporarily unavailable"}"#]))
    }

    func testInvalidItemArraysAndPaginationTypesFail() {
        let invalidPages = [
            "null", "42", #"{"error":"unavailable"}"#,
            #"{"series":null}"#, #"{"series":{},"items":[1]}"#,
            #"{"series":[],"has_more":null}"#, #"{"series":[],"has_more":"false"}"#,
            #"{"series":[],"has_more":0}"#, #"{"series":[],"has_more":1}"#,
            #"{"series":[],"next_offset":null}"#, #"{"series":[],"next_offset":"1"}"#,
            #"{"series":[],"next_offset":true}"#, #"{"series":[],"next_offset":-1}"#,
            #"{"series":[],"next_offset":1.0}"#, #"{"series":[],"next_offset":1e0}"#,
            #"{"series":[],"next_offset":1.5}"#, #"{"series":[],"next_offset":9223372036854775808}"#,
        ]
        for page in invalidPages {
            XCTAssertThrowsError(try harvest([page]), page)
        }
    }

    func testStalledOrEmptyContinuationAndIterationExhaustionFail() {
        XCTAssertThrowsError(try harvest([#"{"series":[],"has_more":true,"next_offset":1}"#]))
        XCTAssertThrowsError(try harvest([#"{"series":[1],"has_more":true,"next_offset":0}"#]))
        XCTAssertThrowsError(try harvest([
            #"{"series":[1],"has_more":true,"next_offset":2}"#,
            #"{"series":[2],"has_more":true,"next_offset":2}"#,
        ]))
        XCTAssertThrowsError(try harvest([
            #"{"series":[1],"has_more":true}"#,
            #"{"series":[2],"has_more":true}"#,
        ], cap: 2))
        XCTAssertThrowsError(try harvest([
            #"{"series":[1],"has_more":true,"next_offset":9223372036854775807}"#,
            #"{"series":[2],"has_more":true}"#,
        ]))
    }
}
