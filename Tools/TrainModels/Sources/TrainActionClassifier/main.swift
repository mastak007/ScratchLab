//
//  main.swift
//  TrainActionClassifier (CLI)
//
//  Phase 2 Slice A. Validates an action-classifier dataset and (optionally)
//  extracts Vision-derived motion features into a JSONL cache. Does NOT
//  train a model; does NOT bundle anything; does NOT touch the iOS app.
//
//  Usage:
//      swift run train-action-classifier \
//          --dataset       <path-to-coreml_ready/action_classifier> \
//          --features-cache <path-to-features-cache-OUTSIDE-the-repo> \
//          [--validate-only] \
//          [--fps 30] [--limit-per-class N] [--force]
//
//  No paths are baked into the binary. The features-cache directory must be
//  passed in by the caller — there is no default — so we never accidentally
//  write extracted features inside the repo.
//

import Foundation
import MotionTrainer
import ScratchLabML

struct CLIArguments {
    var datasetPath: String?
    var featuresCachePath: String?
    var validateOnly: Bool = false
    var fps: Double = 30
    var limitPerClass: Int?
    var force: Bool = false
    var minimumSamplesPerClass: Int = 12
}

enum CLIParseOutcome {
    case ok(CLIArguments)
    case error(String)
}

func parseArguments(_ argv: [String]) -> CLIParseOutcome {
    var args = CLIArguments()
    var i = 1
    while i < argv.count {
        let token = argv[i]
        switch token {
        case "--dataset":
            i += 1
            guard i < argv.count else { return .error("--dataset needs a value") }
            args.datasetPath = argv[i]
        case "--features-cache":
            i += 1
            guard i < argv.count else { return .error("--features-cache needs a value") }
            args.featuresCachePath = argv[i]
        case "--validate-only":
            args.validateOnly = true
        case "--fps":
            i += 1
            guard i < argv.count, let v = Double(argv[i]), v > 0 else {
                return .error("--fps needs a positive number")
            }
            args.fps = v
        case "--limit-per-class":
            i += 1
            guard i < argv.count, let n = Int(argv[i]), n > 0 else {
                return .error("--limit-per-class needs a positive integer")
            }
            args.limitPerClass = n
        case "--min-per-class":
            i += 1
            guard i < argv.count, let n = Int(argv[i]), n > 0 else {
                return .error("--min-per-class needs a positive integer")
            }
            args.minimumSamplesPerClass = n
        case "--force":
            args.force = true
        case "-h", "--help":
            return .error(usage())
        default:
            return .error("Unknown argument: \(token)\n\(usage())")
        }
        i += 1
    }
    return .ok(args)
}

func usage() -> String {
    return """
    Usage: train-action-classifier --dataset <dir> [--features-cache <dir>] [options]

    Options:
      --dataset <dir>             Path to coreml_ready/action_classifier
                                  (one subfolder per ScratchClassLabel).
      --features-cache <dir>      Output directory for per-clip JSONL feature
                                  files. Required unless --validate-only.
                                  Must be supplied by the caller; there is no
                                  default and the path should be OUTSIDE the
                                  repo.
      --validate-only             Validate the dataset and exit. No extraction.
      --fps <number>              Frame sample rate. Default: 30.
      --limit-per-class <int>     Process at most N clips per class (sorted by
                                  filename). Useful for smoke tests.
      --min-per-class <int>       Minimum clips per class for validation.
                                  Default: 12.
      --force                     Re-extract even if a cached JSONL exists.
      -h, --help                  Show this help.

    Behaviour:
      * No model is trained.
      * No .mlmodel / .mlmodelc files are produced.
      * Source-clip absolute paths are NOT written into the JSONL output.
      * Each cached file is one JSON object per line, the encoded form of
        ScratchMotionFrame.
    """
}

let parsedArgs: CLIArguments
switch parseArguments(CommandLine.arguments) {
case .ok(let a): parsedArgs = a
case .error(let message):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

guard let datasetPath = parsedArgs.datasetPath else {
    FileHandle.standardError.write(Data("error: --dataset is required\n\(usage())\n".utf8))
    exit(2)
}

let datasetURL = URL(fileURLWithPath: datasetPath, isDirectory: true)
let validator = ActionDatasetValidator()

let validation: ActionDatasetValidationResult
do {
    validation = try validator.validateDataset(
        at: datasetURL,
        minimumSamplesPerClass: parsedArgs.minimumSamplesPerClass
    )
    print("Dataset OK — \(validation.labels.count) classes:")
    for label in validation.labels {
        let count = validation.perLabelCount[label] ?? 0
        print("  \(label.rawValue): \(count) clip(s)")
    }
} catch {
    FileHandle.standardError.write(Data("validation failed: \(error)\n".utf8))
    exit(1)
}

if parsedArgs.validateOnly {
    exit(0)
}

guard let featuresCachePath = parsedArgs.featuresCachePath else {
    FileHandle.standardError.write(Data(
        "error: --features-cache is required when extracting (omit only with --validate-only)\n".utf8
    ))
    exit(2)
}

let featuresCacheURL = URL(fileURLWithPath: featuresCachePath, isDirectory: true)
do {
    try FileManager.default.createDirectory(
        at: featuresCacheURL,
        withIntermediateDirectories: true
    )
} catch {
    FileHandle.standardError.write(Data(
        "error: could not create --features-cache directory: \(error)\n".utf8
    ))
    exit(1)
}

let extractor = MotionFeatureExtractor(
    configuration: MotionFeatureExtractor.Configuration(fps: parsedArgs.fps)
)
let encoder = JSONEncoder()
encoder.outputFormatting = []

var totalClips = 0
var totalSkipped = 0
var totalExtracted = 0
var totalFailed = 0

for label in validation.labels {
    let classFolder = datasetURL.appendingPathComponent(label.rawValue, isDirectory: true)
    var clips = validator.clips(in: classFolder)
    if let cap = parsedArgs.limitPerClass {
        clips = Array(clips.prefix(cap))
    }
    let outputClassDir = featuresCacheURL.appendingPathComponent(label.rawValue, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: outputClassDir, withIntermediateDirectories: true)
    } catch {
        FileHandle.standardError.write(Data(
            "error: could not create class output dir \(outputClassDir.path): \(error)\n".utf8
        ))
        exit(1)
    }

    print("[\(label.rawValue)] \(clips.count) clip(s)")
    for clipURL in clips {
        totalClips += 1
        let stem = clipURL.deletingPathExtension().lastPathComponent
        let outputURL = outputClassDir.appendingPathComponent("\(stem).jsonl")

        if FileManager.default.fileExists(atPath: outputURL.path) && !parsedArgs.force {
            totalSkipped += 1
            continue
        }

        do {
            let frames = try extractor.extract(clipURL: clipURL)
            var lines = ""
            lines.reserveCapacity(frames.count * 256)
            for frame in frames {
                let data = try encoder.encode(frame)
                if let line = String(data: data, encoding: .utf8) {
                    lines.append(line)
                    lines.append("\n")
                }
            }
            try lines.write(to: outputURL, atomically: true, encoding: .utf8)
            totalExtracted += 1
            print("  + \(stem).jsonl  (\(frames.count) frames)")
        } catch {
            totalFailed += 1
            FileHandle.standardError.write(Data(
                "  ! \(stem): \(error)\n".utf8
            ))
        }
    }
}

print("")
print("Summary:")
print("  clips inspected: \(totalClips)")
print("  extracted:       \(totalExtracted)")
print("  skipped (cache): \(totalSkipped)")
print("  failed:          \(totalFailed)")

if totalFailed > 0 {
    exit(1)
}
exit(0)
