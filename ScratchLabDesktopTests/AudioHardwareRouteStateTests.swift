import XCTest
@testable import ScratchLab

final class AudioHardwareRouteStateTests: XCTestCase {
    func testFourteenChannelsExposeSevenStereoPairs() {
        let state = AudioHardwareRouteState(
            deviceName: "RANE ONE MKII",
            transport: .usb,
            sampleRate: 48_000,
            channelCount: 14
        )

        XCTAssertEqual(state.availableStereoPairs.map(\.displayName), [
            "1/2", "3/4", "5/6", "7/8", "9/10", "11/12", "13/14"
        ])
    }

    func testUnpairedFinalChannelIsNotExposedAsStereo() {
        let state = AudioHardwareRouteState(channelCount: 3)

        XCTAssertEqual(state.availableStereoPairs.map(\.displayName), ["1/2"])
    }

    func testSelectionMustBelongToObservedAvailablePairs() throws {
        let unavailablePair = try XCTUnwrap(
            AudioHardwareRouteState.StereoPair(firstChannelIndex: 2, secondChannelIndex: 3)
        )
        let state = AudioHardwareRouteState(
            channelCount: 2,
            selectedStereoPair: unavailablePair
        )

        XCTAssertNil(state.selectedStereoPair)
    }

    func testValidSelectionIsRetained() throws {
        let selectedPair = try XCTUnwrap(
            AudioHardwareRouteState.StereoPair(firstChannelIndex: 2, secondChannelIndex: 3)
        )
        let state = AudioHardwareRouteState(
            channelCount: 4,
            selectedStereoPair: selectedPair
        )

        XCTAssertEqual(state.selectedStereoPair, selectedPair)
        XCTAssertEqual(state.selectedStereoPair?.displayName, "3/4")
    }

    func testRouteValuesAreNormalisedWithoutImplyingReadiness() {
        let state = AudioHardwareRouteState(
            deviceName: "   ",
            transport: .usb,
            sampleRate: -.infinity,
            channelCount: -1,
            isInputActive: true,
            signalLevel: 2
        )

        XCTAssertNil(state.deviceName)
        XCTAssertNil(state.sampleRate)
        XCTAssertEqual(state.channelCount, 0)
        XCTAssertTrue(state.isInputActive)
        XCTAssertEqual(state.signalLevel, 1)
        XCTAssertTrue(state.availableStereoPairs.isEmpty)
    }

    func testNoInputDevicePublishesUnavailableState() {
        XCTAssertEqual(AudioHardwareRouteState.observing(nil), .unavailable)
    }

    func testMonoHardwareDescriptionHasNoStereoPairs() {
        let state = AudioHardwareRouteState.observing(
            mockDescription(channelCount: 1)
        )

        XCTAssertEqual(state.deviceName, "Mock USB Audio")
        XCTAssertEqual(state.deviceUID, "mock-usb-audio")
        XCTAssertEqual(state.availableChannels.map(\.hardwareChannelNumber), [1])
        XCTAssertTrue(state.availableStereoPairs.isEmpty)
    }

    func testStereoHardwareDescriptionExposesOnePair() {
        let state = AudioHardwareRouteState.observing(
            mockDescription(channelCount: 2)
        )

        XCTAssertEqual(state.channelCount, 2)
        XCTAssertEqual(state.availableStereoPairs.map(\.displayName), ["1/2"])
    }

    func testMultichannelHardwareDescriptionUsesReportedChannels() {
        let state = AudioHardwareRouteState.observing(
            mockDescription(channelCount: 14)
        )

        XCTAssertEqual(state.channelCount, 14)
        XCTAssertEqual(state.availableChannels.count, 14)
        XCTAssertEqual(state.availableStereoPairs.map(\.displayName), [
            "1/2", "3/4", "5/6", "7/8", "9/10", "11/12", "13/14"
        ])
    }

    func testInvalidChannelMetadataIsIgnoredWithoutInflatingFormatCount() {
        let state = AudioHardwareRouteState.observing(
            AudioHardwareRouteDescription(
                deviceName: "Malformed Interface",
                transport: .usb,
                sampleRate: 48_000,
                reportedChannelCount: 2,
                channels: [
                    .init(channelNumber: 0, channelName: "Invalid zero"),
                    .init(channelNumber: 1, channelName: "Left"),
                    .init(channelNumber: 1, channelName: "Duplicate"),
                    .init(channelNumber: 99, channelName: "Out of range")
                ]
            )
        )

        XCTAssertEqual(state.channelCount, 2)
        XCTAssertEqual(state.availableChannels.map(\.hardwareChannelNumber), [1, 2])
        XCTAssertEqual(state.availableChannels.map(\.name), ["Left", nil])
        XCTAssertEqual(state.availableStereoPairs.map(\.displayName), ["1/2"])
    }

    // MARK: - Stereo pair selection (Task 3 rules)

    func testNormalMicrophoneDefaultsToFirstPair() {
        let pairs = AudioHardwareRouteState.StereoPair.contiguousPairs(channelCount: 2)

        let selected = AudioHardwareRouteState.StereoPair.resolveSelection(
            availablePairs: pairs,
            remembered: nil
        )

        XCTAssertEqual(selected?.displayName, "1/2")
    }

    func testRaneStyleDeviceDefaultsToFirstOfSevenPairs() {
        let pairs = AudioHardwareRouteState.StereoPair.contiguousPairs(channelCount: 14)

        XCTAssertEqual(pairs.map(\.displayName), [
            "1/2", "3/4", "5/6", "7/8", "9/10", "11/12", "13/14"
        ])

        let selected = AudioHardwareRouteState.StereoPair.resolveSelection(
            availablePairs: pairs,
            remembered: nil
        )

        XCTAssertEqual(selected?.displayName, "1/2")
    }

    func testInvalidMetadataResolvesSelectionSafelyWithoutCrashing() {
        // Duplicate/out-of-range channel numbers collapse to a small,
        // well-formed channel count once normalized by the model.
        let state = AudioHardwareRouteState.observing(
            AudioHardwareRouteDescription(
                deviceName: "Malformed Interface",
                transport: .usb,
                sampleRate: 48_000,
                reportedChannelCount: 2,
                channels: [
                    .init(channelNumber: 0, channelName: "Invalid zero"),
                    .init(channelNumber: 1, channelName: "Left"),
                    .init(channelNumber: 1, channelName: "Duplicate"),
                    .init(channelNumber: 99, channelName: "Out of range")
                ]
            )
        )

        let selected = AudioHardwareRouteState.StereoPair.resolveSelection(
            availablePairs: state.availableStereoPairs,
            remembered: nil
        )

        XCTAssertEqual(selected?.displayName, "1/2")

        // A genuinely single-channel device has no complete pair at all —
        // resolution must return nil, not trap.
        let monoSelected = AudioHardwareRouteState.StereoPair.resolveSelection(
            availablePairs: AudioHardwareRouteState.StereoPair.contiguousPairs(channelCount: 1),
            remembered: nil
        )
        XCTAssertNil(monoSelected)
    }

    func testRememberedSelectionIsRestoredWhenStillAvailable() throws {
        let pairs = AudioHardwareRouteState.StereoPair.contiguousPairs(channelCount: 14)
        let remembered = try XCTUnwrap(
            AudioHardwareRouteState.StereoPair(firstChannelIndex: 2, secondChannelIndex: 3)
        )

        let selected = AudioHardwareRouteState.StereoPair.resolveSelection(
            availablePairs: pairs,
            remembered: remembered
        )

        XCTAssertEqual(selected?.displayName, "3/4")
    }

    func testRememberedSelectionFallsBackSafelyWhenNoLongerAvailable() throws {
        // Hardware disappeared/changed to fewer channels than the
        // previously remembered pair required.
        let remembered = try XCTUnwrap(
            AudioHardwareRouteState.StereoPair(firstChannelIndex: 12, secondChannelIndex: 13)
        )
        let pairs = AudioHardwareRouteState.StereoPair.contiguousPairs(channelCount: 2)

        let selected = AudioHardwareRouteState.StereoPair.resolveSelection(
            availablePairs: pairs,
            remembered: remembered
        )

        XCTAssertEqual(selected?.displayName, "1/2")
    }

    // MARK: - DVS hardware profile default (Phase 2)

    func testRaneOneMKIIProfileDefaultsToPairThreeFour() {
        let pair = DVSHardwareProfile.preferredStereoPair(forDeviceName: "Rane ONE MKII")

        XCTAssertEqual(pair?.displayName, "3/4")
    }

    func testProfileLookupIsCaseInsensitiveAndSubstringMatched() {
        XCTAssertEqual(
            DVSHardwareProfile.preferredStereoPair(forDeviceName: "RANE ONE MKII")?.displayName,
            "3/4"
        )
        XCTAssertEqual(
            DVSHardwareProfile.preferredStereoPair(forDeviceName: "USB Rane ONE MKII Audio")?.displayName,
            "3/4"
        )
    }

    func testUnknownDeviceHasNoProfileDefault() {
        XCTAssertNil(DVSHardwareProfile.preferredStereoPair(forDeviceName: "Generic USB Audio"))
        XCTAssertNil(DVSHardwareProfile.preferredStereoPair(forDeviceName: nil))
        XCTAssertNil(DVSHardwareProfile.preferredStereoPair(forDeviceName: ""))
    }

    func testProfileDefaultAppliesOnlyWhenNoRememberedSelectionExists() throws {
        let pairs = AudioHardwareRouteState.StereoPair.contiguousPairs(channelCount: 14)
        let profileDefault = DVSHardwareProfile.preferredStereoPair(forDeviceName: "Rane ONE MKII")

        // First-time selection (no remembered pair yet) — profile default wins.
        let firstTime = AudioHardwareRouteState.StereoPair.resolveSelection(
            availablePairs: pairs,
            remembered: nil,
            preferredDefault: profileDefault
        )
        XCTAssertEqual(firstTime?.displayName, "3/4")

        // A remembered pair (e.g. the user picked something else) still wins
        // over the profile default.
        let userChoice = try XCTUnwrap(
            AudioHardwareRouteState.StereoPair(firstChannelIndex: 6, secondChannelIndex: 7)
        )
        let restored = AudioHardwareRouteState.StereoPair.resolveSelection(
            availablePairs: pairs,
            remembered: userChoice,
            preferredDefault: profileDefault
        )
        XCTAssertEqual(restored?.displayName, "7/8")
    }

    func testProfileDefaultFallsBackToFirstPairWhenUnavailable() {
        // Profile default (3/4 = indices 2/3) doesn't fit a 2-channel device.
        let pairs = AudioHardwareRouteState.StereoPair.contiguousPairs(channelCount: 2)
        let profileDefault = DVSHardwareProfile.preferredStereoPair(forDeviceName: "Rane ONE MKII")

        let selected = AudioHardwareRouteState.StereoPair.resolveSelection(
            availablePairs: pairs,
            remembered: nil,
            preferredDefault: profileDefault
        )

        XCTAssertEqual(selected?.displayName, "1/2")
    }

    func testUnknownDeviceStillDefaultsToFirstPair() {
        let pairs = AudioHardwareRouteState.StereoPair.contiguousPairs(channelCount: 14)
        let profileDefault = DVSHardwareProfile.preferredStereoPair(forDeviceName: "Generic USB Audio")

        let selected = AudioHardwareRouteState.StereoPair.resolveSelection(
            availablePairs: pairs,
            remembered: nil,
            preferredDefault: profileDefault
        )

        XCTAssertEqual(selected?.displayName, "1/2")
    }

    // MARK: - Interleaved PCM extraction

    func testExtractInterleavedRaneStylePairThreeFourReadsIndicesTwoAndThree() throws {
        let pair = try XCTUnwrap(
            AudioHardwareRouteState.StereoPair(firstChannelIndex: 2, secondChannelIndex: 3)
        )
        let channelCount = 14
        // Two frames of 14 channels, interleaved. Each sample encodes
        // (frame, channel) so a wrong index is obvious in a failure message.
        var samples: [Float] = []
        for frame in 0..<2 {
            for channel in 0..<channelCount {
                samples.append(Float(frame * 100 + channel))
            }
        }

        let extracted = try XCTUnwrap(pair.extractInterleaved(samples, channelCount: channelCount))

        XCTAssertEqual(extracted.left, [2, 102])
        XCTAssertEqual(extracted.right, [3, 103])
    }

    func testExtractInterleavedReturnsNilWhenPairExceedsChannelCount() throws {
        let pair = try XCTUnwrap(
            AudioHardwareRouteState.StereoPair(firstChannelIndex: 12, secondChannelIndex: 13)
        )

        XCTAssertNil(pair.extractInterleaved([1, 2], channelCount: 2))
    }

    func testExtractInterleavedReturnsNilForIncompleteFrame() throws {
        let pair = try XCTUnwrap(
            AudioHardwareRouteState.StereoPair(firstChannelIndex: 0, secondChannelIndex: 1)
        )

        // Fewer samples than one full 2-channel frame.
        XCTAssertNil(pair.extractInterleaved([1], channelCount: 2))
    }

    private func mockDescription(channelCount: Int) -> AudioHardwareRouteDescription {
        AudioHardwareRouteDescription(
            deviceName: "Mock USB Audio",
            deviceUID: "mock-usb-audio",
            transport: .usb,
            sampleRate: 48_000,
            reportedChannelCount: channelCount,
            channels: (1...channelCount).map {
                .init(channelNumber: $0, channelName: "Input \($0)")
            }
        )
    }
}
