import XCTest
@testable import C2SAppKit

final class MultitouchTriggerTests: XCTestCase {
    func testTwoShortThreeFingerContactsTriggerDoubleTap() {
        var recognizer = ThreeFingerDoubleTapRecognizer()

        XCTAssertNil(recognizer.process(fingerCount: 3, timestamp: 1.00))
        XCTAssertNil(recognizer.process(fingerCount: 3, timestamp: 1.08))
        XCTAssertEqual(recognizer.process(fingerCount: 2, timestamp: 1.09), .firstTap)

        XCTAssertNil(recognizer.process(fingerCount: 3, timestamp: 1.20))
        XCTAssertNil(recognizer.process(fingerCount: 3, timestamp: 1.27))
        XCTAssertEqual(recognizer.process(fingerCount: 1, timestamp: 1.28), .doubleTap)
    }

    func testLongContactDoesNotCountAsTap() {
        var recognizer = ThreeFingerDoubleTapRecognizer()

        XCTAssertNil(recognizer.process(fingerCount: 3, timestamp: 2.00))
        XCTAssertNil(recognizer.process(fingerCount: 3, timestamp: 2.40))
        XCTAssertNil(recognizer.process(fingerCount: 0, timestamp: 2.41))
    }

    func testFourthFingerInvalidatesContact() {
        var recognizer = ThreeFingerDoubleTapRecognizer()

        XCTAssertNil(recognizer.process(fingerCount: 3, timestamp: 3.00))
        XCTAssertNil(recognizer.process(fingerCount: 4, timestamp: 3.05))
        XCTAssertNil(recognizer.process(fingerCount: 0, timestamp: 3.10))
    }

    func testTwoTapsTooFarApartRemainFirstTaps() {
        var recognizer = ThreeFingerDoubleTapRecognizer()

        XCTAssertNil(recognizer.process(fingerCount: 3, timestamp: 4.00))
        XCTAssertEqual(recognizer.process(fingerCount: 0, timestamp: 4.08), .firstTap)
        XCTAssertNil(recognizer.process(fingerCount: 3, timestamp: 4.60))
        XCTAssertEqual(recognizer.process(fingerCount: 0, timestamp: 4.68), .firstTap)
    }

    func testSilenceCanFinishTapWhenNoZeroFingerFrameArrives() {
        var recognizer = ThreeFingerDoubleTapRecognizer()

        XCTAssertNil(recognizer.process(fingerCount: 3, timestamp: 5.00))
        XCTAssertNil(recognizer.process(fingerCount: 3, timestamp: 5.05))
        XCTAssertEqual(recognizer.finishAfterSilence(), .firstTap)
    }
}
