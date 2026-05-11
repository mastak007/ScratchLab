//
//  main.swift
//  TestSoundClassifier (CLI)
//
//  Smoke-test a trained ScratchSoundClassifier .mlmodel against a Create ML-
//  shaped dataset directory (one folder per label, audio files inside). Prints
//  per-sample expected/predicted lines and a summary with overall accuracy
//  and per-label failure counts.
//
//  Run from the package root:
//      swift run test-sound-classifier \
//          --model   <path>/ScratchSoundClassifier.mlmodel \
//          --samples <path>/coreml_ready/sound_classifier
//          [--limit-per-label N]
//
//  No paths are baked in; nothing is bundled.
//

import Foundation
import CoreML
import SoundTrainer

// MARK: - Args

struct CLIArguments {
    var modelPath: String?
    var samplesPath: String?
    var limitPerLabel: Int?
}

enum CLIParseOutcome {
    case ok(CLIArguments)
    case error(String)
}

func usage() -> String {
    return """
    Usage: test-sound-classifier --model <path> --samples <dir> [--limit-per-label N]

    Options:
      --model <path>            Path to a trained .mlmodel or .mlmodelc.
      --samples <dir>           Dataset directory: one subfolder per class
                                label, audio files inside.
      --limit-per-label <int>   Optional cap on how many samples to test from
                                each label folder.
      -h, --help                Show this help.

    The CLI never bundles training data and never copies the model into the
    repo. Pass paths that point outside the repo.
    """
}

func parseArguments(_ argv: [String]) -> CLIParseOutcome {
    var args = CLIArguments()
    var i = 1
    while i < argv.count {
        let token = argv[i]
        switch token {
        case "--model":
            i += 1
            guard i < argv.count else { return .error("--model needs a value") }
            args.modelPath = argv[i]
        case "--samples":
            i += 1
            guard i < argv.count else { return .error("--samples needs a value") }
            args.samplesPath = argv[i]
        case "--limit-per-label":
            i += 1
            guard i < argv.count, let n = Int(argv[i]), n > 0 else {
                return .error("--limit-per-label needs a positive integer")
            }
            args.limitPerLabel = n
        case "-h", "--help":
            return .error(usage())
        default:
            return .error("Unknown argument: \(token)\n\(usage())")
        }
        i += 1
    }
    return .ok(args)
}

// MARK: - Helpers

func isAudioFile(_ url: URL) -> Bool {
    let exts: Set<String> = ["wav", "aif", "aiff", "caf", "m4a", "mp3"]
    return exts.contains(url.pathExtension.lowercased())
}

func listLabelFolders(in url: URL) -> [URL] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    return entries
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func listAudioFiles(in url: URL) -> [URL] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else { return [] }
    return entries.filter(isAudioFile).sorted { $0.lastPathComponent < $1.lastPathComponent }
}

// MARK: - Entry

let args: CLIArguments
switch parseArguments(CommandLine.arguments) {
case .ok(let a): args = a
case .error(let message):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

guard let modelPath = args.modelPath else {
    FileHandle.standardError.write(Data("error: --model is required\n\(usage())\n".utf8))
    exit(2)
}
guard let samplesPath = args.samplesPath else {
    FileHandle.standardError.write(Data("error: --samples is required\n\(usage())\n".utf8))
    exit(2)
}

let modelURL = URL(fileURLWithPath: modelPath)
let samplesURL = URL(fileURLWithPath: samplesPath, isDirectory: true)

let model: MLModel
do {
    model = try SoundFileTester.loadModel(at: modelURL)
} catch {
    FileHandle.standardError.write(Data("model load failed: \(error)\n".utf8))
    exit(1)
}

let labelFolders = listLabelFolders(in: samplesURL)
guard !labelFolders.isEmpty else {
    FileHandle.standardError.write(Data("no class folders found at \(samplesPath)\n".utf8))
    exit(1)
}

var totalTested = 0
var correct = 0
var attemptsByLabel: [String: Int] = [:]
var failuresByLabel: [String: Int] = [:]
var errorsByLabel: [String: Int] = [:]

print("Testing \(labelFolders.count) labels from \(samplesURL.path)\n")

for folder in labelFolders {
    let expected = folder.lastPathComponent
    var files = listAudioFiles(in: folder)
    if let limit = args.limitPerLabel {
        files = Array(files.prefix(limit))
    }

    for file in files {
        do {
            let prediction = try SoundFileTester.classify(audioFile: file, with: model)
            let predicted = prediction.topLabel
            let isCorrect = predicted == expected

            totalTested += 1
            attemptsByLabel[expected, default: 0] += 1
            if isCorrect {
                correct += 1
            } else {
                failuresByLabel[expected, default: 0] += 1
            }

            let mark = isCorrect ? "ok  " : "FAIL"
            let conf = String(format: "%.3f", prediction.topConfidence)
            print("\(mark)  expected=\(expected)  predicted=\(predicted)  conf=\(conf)  file=\(file.lastPathComponent)")
        } catch {
            errorsByLabel[expected, default: 0] += 1
            FileHandle.standardError.write(Data("err   \(file.lastPathComponent): \(error)\n".utf8))
        }
    }
}

let accuracy = totalTested > 0 ? Double(correct) / Double(totalTested) * 100.0 : 0.0
print("")
print("---- Summary ----")
print("Total tested:  \(totalTested)")
print("Correct:       \(correct)")
print(String(format: "Accuracy:      %.1f%%", accuracy))

if failuresByLabel.isEmpty && errorsByLabel.isEmpty {
    print("Per-label:     all labels at 100% on this set")
} else {
    print("")
    print("Per-label failures (failures / attempted):")
    let sortedFails = failuresByLabel.sorted { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.key < rhs.key
    }
    for (label, fails) in sortedFails {
        let attempts = attemptsByLabel[label, default: 0]
        print("  \(label): \(fails)/\(attempts)")
    }
    if !errorsByLabel.isEmpty {
        print("")
        print("Per-label inference errors:")
        for (label, count) in errorsByLabel.sorted(by: { $0.key < $1.key }) {
            print("  \(label): \(count)")
        }
    }
}
