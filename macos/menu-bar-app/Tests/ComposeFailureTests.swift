// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

import XCTest
@testable import FalconPulsarMenuBar

final class ComposeFailureTests: XCTestCase {
    func testUnhealthyCoreIsExplainedInPlainWords() {
        // Verbatim from `docker compose up -d` against a Core that does not
        // answer its health check.
        let output = """
         Container falconpulsar-core  Running
         Container falconpulsar-core  Waiting
         Container falconpulsar-core  Error dependency core failed to start
        dependency failed to start: container falconpulsar-core is unhealthy
        """
        let s = ComposeFailure.summary(output: output, status: 1)
        XCTAssertTrue(s.hasPrefix("FalconPulsar Core is running but not answering"), s)
    }

    func testLastErrorLineWinsOverLaterProgress() {
        let output = """
        Error response from daemon: pull access denied for falconpulsar/nope
         Container falconpulsar-ui  Started
        """
        XCTAssertEqual(ComposeFailure.summary(output: output, status: 1),
                       "Error response from daemon: pull access denied for falconpulsar/nope")
    }

    func testColourCodesAreStripped() {
        let output = "\u{1B}[31mError\u{1B}[0m port is already allocated\n"
        XCTAssertEqual(ComposeFailure.summary(output: output, status: 1), "Error port is already allocated")
    }

    func testNoErrorWordFallsBackToTheLastLine() {
        XCTAssertEqual(ComposeFailure.summary(output: "one\ntwo\n\n", status: 1), "two")
    }

    func testNoOutputNamesTheExitStatus() {
        XCTAssertEqual(ComposeFailure.summary(output: "  \n", status: 125),
                       "docker compose exited with status 125.")
    }

    func testLongReasonIsTruncated() {
        let long = "error: " + String(repeating: "x", count: 500)
        let s = ComposeFailure.summary(output: long, status: 1, limit: 40)
        XCTAssertEqual(s.count, 40)
        XCTAssertTrue(s.hasSuffix("…"))
    }

    func testAnotherContainerUnhealthyIsNotCalledCore() {
        let output = "dependency failed to start: container falconpulsar-ai-gateway is unhealthy"
        XCTAssertEqual(ComposeFailure.summary(output: output, status: 1), output)
    }
}
