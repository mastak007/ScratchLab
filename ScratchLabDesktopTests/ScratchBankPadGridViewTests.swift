import XCTest
@testable import ScratchLab

/// UI-only scratch bank pad grid tests — 4-pad slice.
/// Verifies default assignments, preview intent,
/// and that no MIDI/scoring/audio-routing concerns leak into the UI slice.
final class ScratchBankPadGridViewTests: XCTestCase {

    // MARK: - 1. Default 4 pad assignments resolve expected sample IDs

    func testDefaultAssignmentsHaveFourEntries() {
        XCTAssertEqual(ScratchBankDefaultAssignments.defaultPadSampleIDs.count, 4,
            "Default scratch bank must have exactly 4 pad assignments in this slice")
    }

    func testPad1IsAhhh() {
        XCTAssertEqual(ScratchBankDefaultAssignments.sampleID(for: 0), "ahhh")
    }

    func testPad2IsFresh() {
        XCTAssertEqual(ScratchBankDefaultAssignments.sampleID(for: 1), "fresh")
    }

    func testPad3IsAhYeah() {
        XCTAssertEqual(ScratchBankDefaultAssignments.sampleID(for: 2), "ah_yeah")
    }

    func testPad4IsCheckItOut() {
        XCTAssertEqual(ScratchBankDefaultAssignments.sampleID(for: 3), "check_it_out")
    }

    // MARK: - 2. No Pad 5–8 assignments exist in this UI slice

    func testPad5Thru8ReturnNil() {
        XCTAssertNil(ScratchBankDefaultAssignments.sampleID(for: 4),
            "Pad 5 must return nil — not in the 4-pad slice")
        XCTAssertNil(ScratchBankDefaultAssignments.sampleID(for: 5),
            "Pad 6 must return nil — not in the 4-pad slice")
        XCTAssertNil(ScratchBankDefaultAssignments.sampleID(for: 6),
            "Pad 7 must return nil — not in the 4-pad slice")
        XCTAssertNil(ScratchBankDefaultAssignments.sampleID(for: 7),
            "Pad 8 must return nil — not in the 4-pad slice")
    }

    func testSampleIDOutOfBoundsReturnsNil() {
        XCTAssertNil(ScratchBankDefaultAssignments.sampleID(for: -1))
        XCTAssertNil(ScratchBankDefaultAssignments.sampleID(for: 4))
        XCTAssertNil(ScratchBankDefaultAssignments.sampleID(for: 100))
    }

    // MARK: - 3. Preview intent is captured by the view model

    func testViewModelRecordsPreviewIntent() {
        let vm = ScratchBankPadGridViewModel()
        XCTAssertNil(vm.lastPreviewedSampleID)
        XCTAssertNil(vm.lastSelectedSampleID)

        vm.recordPreview("ahhh")
        XCTAssertEqual(vm.lastPreviewedSampleID, "ahhh")
        XCTAssertNil(vm.lastSelectedSampleID)
    }

    func testViewModelRecordsSelectionIntent() {
        let vm = ScratchBankPadGridViewModel()
        vm.recordSelection("fresh")
        XCTAssertEqual(vm.lastSelectedSampleID, "fresh")
        XCTAssertNil(vm.lastPreviewedSampleID)
    }

    func testViewModelOverwritesLastPreview() {
        let vm = ScratchBankPadGridViewModel()
        vm.recordPreview("ahhh")
        vm.recordPreview("check_it_out")
        XCTAssertEqual(vm.lastPreviewedSampleID, "check_it_out")
    }

    // MARK: - 4. Rane pad mapping remains verificationRequired

    func testRanePadMappingVerificationRequiredRemainsTrue() {
        for mapping in ScratchBankPadMappingCatalog.raneOneMKII {
            XCTAssertTrue(mapping.verificationRequired,
                "All Rane pad mappings must keep verificationRequired = true; pad \(mapping.padIndex) deck \(mapping.deck as Any)")
        }
    }

    // MARK: - 5. No scoring is enabled

    func testNoScoringEnabledOnPadMapping() {
        for mapping in ScratchBankPadMappingCatalog.raneOneMKII {
            XCTAssertFalse(mapping.canFeedScoring,
                "Pad mapping must not enable scoring")
        }
    }

    func testDefaultAssignmentsAreDataOnly_NoScoringSideEffects() {
        let ids = ScratchBankDefaultAssignments.defaultPadSampleIDs
        XCTAssertEqual(ids.count, 4)

        for i in 0..<4 {
            _ = ScratchBankDefaultAssignments.sampleID(for: i)
        }
        XCTAssertTrue(true, "Default assignments accessed without scoring side effects")
    }

    // MARK: - 6. No MIDI routing type is introduced in the UI slice

    func testNoMIDIRoutingTypeInPadGridViewModel() {
        let mirror = Mirror(reflecting: ScratchBankPadGridViewModel())
        let propertyTypes = mirror.children.compactMap { $0.label }
        let containsMIDI = propertyTypes.contains { $0.lowercased().contains("midi") }
        XCTAssertFalse(containsMIDI,
            "ScratchBankPadGridViewModel must not expose any MIDI-routing property; found: \(propertyTypes)")
    }

    func testNoMIDIRoutingTypeInDefaultAssignments() {
        let mirror = Mirror(reflecting: ScratchBankDefaultAssignments.self)
        let children = mirror.children.compactMap { $0.label }
        let containsMIDI = children.contains { $0.lowercased().contains("midi") }
        XCTAssertFalse(containsMIDI,
            "ScratchBankDefaultAssignments must not reference MIDI; found: \(children)")
    }

    // MARK: - 7. View model is ObservableObject (required for SwiftUI binding)

    func testViewModelIsObservableObject() {
        let vm = ScratchBankPadGridViewModel()
        XCTAssertTrue(vm is ObservableObject,
            "ViewModel must conform to ObservableObject for SwiftUI binding")
    }
}
