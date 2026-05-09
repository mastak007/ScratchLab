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

// Long-running CLIs need line-buffered stdout so progress lines flow through
// `tee` / pipes immediately. Without this Swift's stdout switches to block
// buffering when stdout is not a TTY and the user can't see what clip is
// in flight when the extractor is processing — making hangs hard to spot.
setlinebuf(stdout)

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

// Build the full work list up-front so per-clip progress can show "i/total"
// against the global plan. Cache-skip is decided inside the loop so the
// counter still increments through cached entries.
struct PendingClip {
    let label: ScratchClassLabel
    let url: URL
    let outputURL: URL
}
var pending: [PendingClip] = []
for label in validation.labels {
    let classFolder = datasetURL.appendingPathComponent(label.rawValue, isDirectory: true)
    var clips = validator.clips(in: classFolder)
    if let cap = parsedArgs.limitPerClass {
        clips = Array(clips.prefix(cap))
    }
    let outputClassDir = featuresCacheURL
        .appendingPathComponent(label.rawValue, isDirectory: true)
    do {
        try FileManager.default.createDirectory(
            at: outputClassDir,
            withIntermediateDirectories: true
        )
    } catch {
        FileHandle.standardError.write(Data(
            "error: could not create class output dir \(outputClassDir.path): \(error)\n".utf8
        ))
        exit(1)
    }
    for clipURL in clips {
        let stem = clipURL.deletingPathExtension().lastPathComponent
        pending.append(PendingClip(
            label: label,
            url: clipURL,
            outputURL: outputClassDir.appendingPathComponent("\(stem).jsonl")
        ))
    }
}

let total = pending.count
print("\(total) clip(s) queued.")

for (idx, p) in pending.enumerated() {
    let progressTag = "[\(idx + 1)/\(total)]"
    let stem = p.url.deletingPathExtension().lastPathComponent
    let sourceTag = "\(p.label.rawValue)/\(stem).mp4"
    let destTag   = "\(p.label.rawValue)/\(stem).jsonl"

    // Per-clip autoreleasepool keeps CGImage / CVPixelBuffer / VNRequest
    // results from accumulating across clips. Without this the extractor
    // builds up retained Vision/AVFoundation resources over a long run
    // and eventually starves the dispatch callback paths, which is the
    // hang signature seen in the field.
    autoreleasepool {
        totalClips += 1

        if FileManager.default.fileExists(atPath: p.outputURL.path) && !parsedArgs.force {
            totalSkipped += 1
            print("\(progressTag) skip   \(destTag) (cached)")
            return
        }

        // Print the start line BEFORE we call into AVFoundation/Vision so
        // the log identifies the in-flight clip even if extraction hangs.
        print("\(progressTag) start  \(sourceTag) -> \(destTag)")

        do {
            let frames = try extractor.extract(clipURL: p.url)
            var lines = ""
            lines.reserveCapacity(frames.count * 256)
            for frame in frames {
                let data = try encoder.encode(frame)
                if let line = String(data: data, encoding: .utf8) {
                    lines.append(line)
                    lines.append("\n")
                }
            }
            // Atomic write — readers never see a half-written JSONL, and
            // a kill mid-write leaves no file at all (the skip-cache logic
            // will retry it on the next run).
            try lines.write(to: p.outputURL, atomically: true, encoding: .utf8)
            totalExtracted += 1
            print("\(progressTag) ok     \(destTag) (\(frames.count) frames)")
        } catch {
            totalFailed += 1
            FileHandle.standardError.write(Data(
                "\(progressTag) FAIL   \(destTag): \(error)\n".utf8
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
