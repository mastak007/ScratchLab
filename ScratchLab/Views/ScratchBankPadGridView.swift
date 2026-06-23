// ScratchBankPadGridView.swift
// ScratchLab - Scratch Bank Pad Grid View
// UI-only 4-pad grid for scratch sample bank assignment and preview.
// No MIDI routing. No live hardware triggering. No scoring.

import SwiftUI

// MARK: - Scratch Bank Default Assignments (iOS extensions)

extension ScratchBankDefaultAssignments {
    /// Resolve the ScratchSample for a 0-based pad index from the given catalog.
    static func sample(for padIndex: Int,
                       in catalog: [ScratchSample]) -> ScratchSample? {
        guard let id = sampleID(for: padIndex) else { return nil }
        return catalog.first(where: { $0.id == id })
    }

    /// Whether a bundled WAV file exists for the sample at the given pad index.
    static func isSampleAvailable(for padIndex: Int,
                                  resourceRoot: URL?) -> Bool {
        guard let id = sampleID(for: padIndex) else { return false }
        guard let sample = SampleManager.bundledDefaultSamplesCatalog.first(where: { $0.id == id }) else {
            return false
        }
        return SampleManager.bundledDefaultSampleURL(for: sample, in: resourceRoot) != nil
    }
}

// MARK: - Scratch Bank Pad Grid View

/// UI-only 4-pad scratch bank grid.
///
/// - Displays 4 pads in a single row.
/// - Tapping a pad previews the sample via `SampleManager.previewSample`.
/// - Unavailable bundled samples show a disabled/unavailable state.
/// - A footer label reminds that Rane pad verification is pending.
///
/// This view does NOT:
/// - Route MIDI events
/// - Trigger audio output (beyond preview)
/// - Feed scoring
/// - Listen for hardware pad presses
/// - Display pads 5–8
struct ScratchBankPadGridView: View {
    @ObservedObject var sampleManager: SampleManager
    @ObservedObject var viewModel: ScratchBankPadGridViewModel

    private let padCount = 4
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        VStack(spacing: 12) {
            // 4-pad grid (4 columns × 1 row)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(0..<padCount, id: \.self) { index in
                    ScratchBankPadCell(
                        padIndex: index,
                        sample: resolvedSample(for: index),
                        isAvailable: isSampleAvailable(for: index),
                        onTap: { previewPad(index) }
                    )
                }
            }

            // Footer: Rane pads pending verification
            VStack(alignment: .leading, spacing: 4) {
                Text("Rane pads pending verification")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "FFD700").opacity(0.8))

                Text("MIDI not wired yet")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Helpers

    private func resolvedSample(for padIndex: Int) -> ScratchSample? {
        guard let sampleID = ScratchBankDefaultAssignments.sampleID(for: padIndex) else {
            return nil
        }
        return sampleManager.availableSamples.first(where: { $0.id == sampleID })
            ?? SampleManager.bundledDefaultSamplesCatalog.first(where: { $0.id == sampleID })
    }

    private func isSampleAvailable(for padIndex: Int) -> Bool {
        ScratchBankDefaultAssignments.isSampleAvailable(
            for: padIndex,
            resourceRoot: Bundle.main.resourceURL
        )
    }

    private func previewPad(_ padIndex: Int) {
        guard let sample = resolvedSample(for: padIndex),
              isSampleAvailable(for: padIndex) else { return }

        viewModel.recordPreview(sample.id)
        sampleManager.previewSample(sample)
    }
}

// MARK: - Scratch Bank Pad Cell

private struct ScratchBankPadCell: View {
    let padIndex: Int
    let sample: ScratchSample?
    let isAvailable: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: {
            guard isAvailable else { return }
            onTap()
        }) {
            VStack(spacing: 6) {
                // Pad number
                Text("\(padIndex + 1)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(padNumberColor)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(isAvailable
                                ? Color.white.opacity(0.15)
                                : Color.white.opacity(0.04))
                    )

                // Sample name
                Text(sample?.displayName ?? "—")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isAvailable ? .white : .white.opacity(0.25))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                // Availability indicator
                if !isAvailable {
                    Text("unavailable")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(Color(hex: "F44336").opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isAvailable
                        ? Color.white.opacity(0.06)
                        : Color.white.opacity(0.02))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                isAvailable
                                    ? Color.white.opacity(0.08)
                                    : Color.white.opacity(0.03),
                                lineWidth: 0.5
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1.0 : 0.45)
    }

    private var padNumberColor: Color {
        if !isAvailable { return .white.opacity(0.2) }
        // Subtle gold hint for the pad number — no functional MIDI meaning.
        return Color(hex: "FFD700").opacity(0.7)
    }
}

// MARK: - Previews

#if DEBUG
struct ScratchBankPadGridView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color(hex: "0D0D0D").ignoresSafeArea()

            ScratchBankPadGridView(
                sampleManager: SampleManager.shared,
                viewModel: ScratchBankPadGridViewModel()
            )
            .padding(20)
        }
    }
}
#endif
