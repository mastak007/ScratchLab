import XCTest
@testable import ScratchLab

final class ScratchTypeMetadataSafetyTests: XCTestCase {

    // MARK: - Banned-token detection

    func testNilAndEmptyValuesAreTreatedAsSafe() {
        XCTAssertTrue(ScratchTypeMetadataSafety.isSafe(nil))
        XCTAssertTrue(ScratchTypeMetadataSafety.isSafe(""))
    }

    func testRegularDisplayNamesAreSafe() {
        XCTAssertTrue(ScratchTypeMetadataSafety.isSafe("Baby Scratch"))
        XCTAssertTrue(ScratchTypeMetadataSafety.isSafe("Chirp"))
        XCTAssertTrue(ScratchTypeMetadataSafety.isSafe("1-Click Flare"))
        XCTAssertTrue(ScratchTypeMetadataSafety.isSafe("Transform"))
        XCTAssertTrue(ScratchTypeMetadataSafety.isSafe("baby_scratch"))
        XCTAssertTrue(ScratchTypeMetadataSafety.isSafe("flare_2click"))
    }

    func testBannedSubstringsAreRejected() {
        let bannedExamples: [String] = [
            "/Users/me/clip.mov",
            "ripped via MakeMKV",
            "processed_makemkv/baby/90bpm",
            "sourceMKV: Disc 1",
            "sourceDVD reference",
            "QBERT bonus material",
            "SXRATCH demo",
            "rightsStatus = ok",
            "reviewStatus pending",
        ]
        for example in bannedExamples {
            XCTAssertFalse(
                ScratchTypeMetadataSafety.isSafe(example),
                "Expected banned substring to be detected in \(example.debugDescription)"
            )
            XCTAssertNil(
                ScratchTypeMetadataSafety.sanitized(example),
                "Expected sanitized() to return nil for unsafe value \(example.debugDescription)"
            )
        }
    }

    func testBannedSubstringsAreCaseInsensitive() {
        XCTAssertFalse(ScratchTypeMetadataSafety.isSafe("makemkv"))
        XCTAssertFalse(ScratchTypeMetadataSafety.isSafe("MAKEMKV"))
        XCTAssertFalse(ScratchTypeMetadataSafety.isSafe("RightsSTATUS"))
        XCTAssertFalse(ScratchTypeMetadataSafety.isSafe("reViEwSTatus"))
    }

    func testSanitizedPassesSafeValuesThrough() {
        XCTAssertEqual(ScratchTypeMetadataSafety.sanitized("Baby Scratch"), "Baby Scratch")
        XCTAssertEqual(ScratchTypeMetadataSafety.sanitized("chirp"), "chirp")
    }

    // MARK: - Canonical scratch-type mapping

    func testCanonicalScratchTypeAcceptsRawValues() {
        XCTAssertEqual(
            ScratchTypeMetadataSafety.canonicalScratchType(forIdentifier: "baby_scratch"),
            .babyScratch
        )
        XCTAssertEqual(
            ScratchTypeMetadataSafety.canonicalScratchType(forIdentifier: "chirp"),
            .chirp
        )
        XCTAssertEqual(
            ScratchTypeMetadataSafety.canonicalScratchType(forIdentifier: "flare_1click"),
            .flare1Click
        )
        XCTAssertEqual(
            ScratchTypeMetadataSafety.canonicalScratchType(forIdentifier: "flare_2click"),
            .flare2Click
        )
        XCTAssertEqual(
            ScratchTypeMetadataSafety.canonicalScratchType(forIdentifier: "transform"),
            .transform
        )
    }

    func testCanonicalScratchTypeAcceptsDisplayNames() {
        XCTAssertEqual(
            ScratchTypeMetadataSafety.canonicalScratchType(forIdentifier: "Baby Scratch"),
            .babyScratch
        )
        XCTAssertEqual(
            ScratchTypeMetadataSafety.canonicalScratchType(forIdentifier: "1-click flare"),
            .flare1Click
        )
        XCTAssertEqual(
            ScratchTypeMetadataSafety.canonicalScratchType(forIdentifier: "transform"),
            .transform
        )
    }

    func testCanonicalScratchTypeRejectsUnknown() {
        XCTAssertNil(ScratchTypeMetadataSafety.canonicalScratchType(forIdentifier: nil))
        XCTAssertNil(ScratchTypeMetadataSafety.canonicalScratchType(forIdentifier: ""))
        XCTAssertNil(ScratchTypeMetadataSafety.canonicalScratchType(forIdentifier: "banana"))
    }

    func testTitlesAreSafeAcrossEveryEnumCase() {
        for type in CaptureSessionScratchType.allCases {
            XCTAssertTrue(
                ScratchTypeMetadataSafety.isSafe(type.title),
                "Title for .\(type.rawValue) is unsafe: \(type.title)"
            )
            XCTAssertTrue(
                ScratchTypeMetadataSafety.isSafe(type.rawValue),
                "Raw value for .\(type.rawValue) is unsafe"
            )
        }
    }
}
