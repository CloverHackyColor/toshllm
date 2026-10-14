// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ToshLLM

final class ChatSketchTests: XCTestCase {
    func testAnAgentsFigureIsReadAndMeasured() throws {
        let sketch = try XCTUnwrap(ChatSketch(["title": "Tract", "unit": "ft", "closed": true,
                                               "points": [[0, 0], [737.85, -426], [613.56, -649.46], [-123.25, -224.06], [0.06, -0.06]]]))
        XCTAssertEqual(sketch.unit, "ft")
        XCTAssertEqual(sketch.gap, hypot(0.06, 0.06), accuracy: 1e-9)
        XCTAssertEqual(sketch.scaleLength, 200)
        XCTAssertNil(sketch.corners)
    }

    func testWhatCannotBeDrawnIsRefused() {
        XCTAssertNil(ChatSketch(["points": [[0, 0]]]), "one point is not a figure")
        XCTAssertNil(ChatSketch(["points": [[0, 0], ["a", 1]]]))
        XCTAssertNil(ChatSketch(["points": [[0, 0], [1, 1]], "corners": [[0]]]))
        XCTAssertNil(ChatSketch(["points": Array(repeating: [0, 0], count: ChatSketch.maximumPoints + 1)]))
    }

    func testTheFigureStaysWithTheAnswerItCameWith() throws {
        var message = ChatMessage(role: "assistant", content: "It closes.")
        message.sketch = ChatSketch(title: nil, unit: "ft", points: [[0, 0], [10, 0], [10, 10], [0, 0]], closed: true)
        let saved = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(saved.sketch, message.sketch)
        let older = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(ChatMessage(role: "assistant", content: "x")))
        XCTAssertNil(older.sketch)
    }
}
