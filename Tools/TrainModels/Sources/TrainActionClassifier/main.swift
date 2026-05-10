//
//  main.swift
//  TrainActionClassifier (CLI)
//
//  Phase 2 Slices A, B, and C. The CLI runs in one of five mutually-
//  exclusive modes; the existing extract / validate-only / audit /
//  build-windows flows continue to work unchanged.
//
//      Slice A — extract (default):
//          --dataset <dir> --features-cache <dir> [--fps N] [...]
//
//      Slice A — dataset validate only:
//          --dataset <dir> --validate-only
//
//      Slice B — feature-cache audit:
//          --audit-cache <cache-dir>
//              [--audit-expected-files N]
//              [--audit-min-hand-coverage 0..1]
//              [--audit-min-wrist-coverage 0..1]
//
//      Slice B — motion-window build:
//          --build-windows <cache-dir>
//          --windows-out <dir-OUTSIDE-the-repo>
//          [--window-frames 60] [--stride-frames 30]
//          [--force-inside-repo]
//
//      Slice C — train action classifier (macOS only):
//          --train-action-classifier <windows-dir>
//          --model-out <dir-OUTSIDE-the-repo>
//          [--validation-fraction 0.2] [--seed 1337]
//          [--max-iterations 50] [--prediction-window-size 60]
//          [--balance-classes] [--force-inside-repo]
//
//  Does NOT touch the iOS / macOS / watchOS app target, the Xcode
//  project, signing, bundle IDs, entitlements, Info.plist,
//  PrivacyInfo.xcprivacy, Copy Bundle Resources, or app resources.
//  Generated .mlmodel files are written outside the repo.
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

    // Slice B — audit mode
    var auditCachePath: String?
    var auditExpectedFiles: Int?
    var auditMinHandCoverage: Double = 0.5
    var auditMinWristCoverage: Double = 0.5

    // Slice B — window-build mode
    var buildWindowsCachePath: String?
    var windowsOutPath: String?
    var windowFrames: Int = 60
    var strideFrames: Int = 30
    var forceInsideRepo: Bool = false

    // Slice C — train mode
    var trainWindowsPath: String?
    var modelOutPath: String?
    var validationFraction: Double = 0.2
    var seed: UInt64 = 1337
    var maxIterations: Int = 50
    var predictionWindowSize: Int = 60
    var balanceClasses: Bool = false

    // Slice D — evaluate mode
    var evaluateWindowsPath: String?
    var modelPath: String?
    var trainingReportPath: String?
    var evaluationOutPath: String?
    var weakClassThreshold: Double = 0.7
    var topConfusions: Int = 20
    var lowConfidenceThreshold: Double = 0.5
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
        case "--audit-cache":
            i += 1
            guard i < argv.count else { return .error("--audit-cache needs a value") }
            args.auditCachePath = argv[i]
        case "--audit-expected-files":
            i += 1
            guard i < argv.count, let n = Int(argv[i]), n > 0 else {
                return .error("--audit-expected-files needs a positive integer")
            }
            args.auditExpectedFiles = n
        case "--audit-min-hand-coverage":
            i += 1
            guard i < argv.count, let v = Double(argv[i]), v >= 0, v <= 1 else {
                return .error("--audit-min-hand-coverage needs a value in [0, 1]")
            }
            args.auditMinHandCoverage = v
        case "--audit-min-wrist-coverage":
            i += 1
            guard i < argv.count, let v = Double(argv[i]), v >= 0, v <= 1 else {
                return .error("--audit-min-wrist-coverage needs a value in [0, 1]")
            }
            args.auditMinWristCoverage = v
        case "--build-windows":
            i += 1
            guard i < argv.count else { return .error("--build-windows needs a value") }
            args.buildWindowsCachePath = argv[i]
        case "--windows-out":
            i += 1
            guard i < argv.count else { return .error("--windows-out needs a value") }
            args.windowsOutPath = argv[i]
        case "--window-frames":
            i += 1
            guard i < argv.count, let n = Int(argv[i]), n > 0 else {
                return .error("--window-frames needs a positive integer")
            }
            args.windowFrames = n
        case "--stride-frames":
            i += 1
            guard i < argv.count, let n = Int(argv[i]), n > 0 else {
                return .error("--stride-frames needs a positive integer")
            }
            args.strideFrames = n
        case "--force-inside-repo":
            args.forceInsideRepo = true
        case "--train-action-classifier":
            i += 1
            guard i < argv.count else { return .error("--train-action-classifier needs a value") }
            args.trainWindowsPath = argv[i]
        case "--model-out":
            i += 1
            guard i < argv.count else { return .error("--model-out needs a value") }
            args.modelOutPath = argv[i]
        case "--validation-fraction":
            i += 1
            guard i < argv.count, let v = Double(argv[i]), v >= 0, v <= 0.5 else {
                return .error("--validation-fraction needs a value in [0.0, 0.5]")
            }
            args.validationFraction = v
        case "--seed":
            i += 1
            guard i < argv.count, let n = UInt64(argv[i]) else {
                return .error("--seed needs a non-negative integer")
            }
            args.seed = n
        case "--max-iterations":
            i += 1
            guard i < argv.count, let n = Int(argv[i]), n > 0 else {
                return .error("--max-iterations needs a positive integer")
            }
            args.maxIterations = n
        case "--prediction-window-size":
            i += 1
            guard i < argv.count, let n = Int(argv[i]), n > 0 else {
                return .error("--prediction-window-size needs a positive integer")
            }
            args.predictionWindowSize = n
        case "--balance-classes":
            args.balanceClasses = true
        case "--evaluate-action-classifier":
            i += 1
            guard i < argv.count else { return .error("--evaluate-action-classifier needs a value") }
            args.evaluateWindowsPath = argv[i]
        case "--model":
            i += 1
            guard i < argv.count else { return .error("--model needs a value") }
            args.modelPath = argv[i]
        case "--training-report":
            i += 1
            guard i < argv.count else { return .error("--training-report needs a value") }
            args.trainingReportPath = argv[i]
        case "--evaluation-out":
            i += 1
            guard i < argv.count else { return .error("--evaluation-out needs a value") }
            args.evaluationOutPath = argv[i]
        case "--weak-class-threshold":
            i += 1
            guard i < argv.count, let v = Double(argv[i]), v >= 0, v <= 1 else {
                return .error("--weak-class-threshold needs a value in [0.0, 1.0]")
            }
            args.weakClassThreshold = v
        case "--top-confusions":
            i += 1
            guard i < argv.count, let n = Int(argv[i]), n >= 0 else {
                return .error("--top-confusions needs a non-negative integer")
            }
            args.topConfusions = n
        case "--low-confidence-threshold":
            i += 1
            guard i < argv.count, let v = Double(argv[i]), v >= 0, v <= 1 else {
                return .error("--low-confidence-threshold needs a value in [0.0, 1.0]")
            }
            args.lowConfidenceThreshold = v
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
    Usage: train-action-classifier <mode> [options]

    Modes (mutually exclusive — pick one):

      --dataset <dir> --features-cache <dir>
                                  Extract features from every mp4 under the
                                  dataset into the cache. Skips JSONLs that
                                  already exist unless --force is also set.

      --dataset <dir> --validate-only
                                  Validate the dataset's class folders only.
                                  No extraction, no cache write.

      --audit-cache <cache-dir>   Audit a feature cache produced by Slice A.
                                  Reports file counts, frame counts, hand
                                  detection coverage, out-of-range
                                  coordinates, and any structural problems.

      --build-windows <cache-dir> --windows-out <dir>
                                  Slice JSONL feature streams into fixed-
                                  length windows for training. Output is one
                                  JSONL of MotionFeatureWindow per source
                                  clip. The output directory must be outside
                                  the repo unless --force-inside-repo is
                                  also set.

      --train-action-classifier <windows-dir> --model-out <dir>
                                  (macOS only.) Train an MLActivityClassifier
                                  from the windows-dir produced by
                                  --build-windows and write
                                  ScratchActionClassifier.mlmodel plus
                                  ScratchActionClassifier.training-report.json
                                  into model-out. The output directory must
                                  be outside the repo unless
                                  --force-inside-repo is set.

      --evaluate-action-classifier <windows-dir>
        --model <path-to-.mlmodel> --evaluation-out <dir>
                                  (macOS only.) Run the trained model over
                                  every window in <windows-dir> and write
                                  ScratchActionClassifier.evaluation-report.json
                                  plus ScratchActionClassifier.confusion-
                                  matrix.csv into the evaluation-out
                                  directory. Output dir must be outside the
                                  repo unless --force-inside-repo is set.

    Common options:
      --fps <number>              Frame sample rate for extraction. Default 30.
      --limit-per-class <int>     Extract at most N clips per class (sorted
                                  by filename). Useful for smoke tests.
      --min-per-class <int>       Minimum clips per class for dataset
                                  validation. Default 12.
      --force                     Re-extract / re-build even when an output
                                  file already exists.

    Audit options:
      --audit-expected-files <n>      Compare against an expected file count.
      --audit-min-hand-coverage 0..1  Minimum dominantHand coverage. Default 0.5.
      --audit-min-wrist-coverage 0..1 Minimum dominantHandWrist coverage.
                                      Default 0.5.

    Window options:
      --window-frames <n>         Frames per window. Default 60 (≈ 2s @ 30fps).
      --stride-frames <n>         Stride between windows. Default 30 (≈ 50%
                                  overlap @ 30fps).
      --force-inside-repo         Allow writing windows / models under the
                                  current git working tree. Off by default
                                  to avoid accidental commits of generated
                                  artefacts.

    Train options:
      --validation-fraction <f>      Fraction of clips per class held out
                                     for validation. Default 0.2; range
                                     [0.0, 0.5].
      --seed <int>                   Seed for the deterministic train/val
                                     split. Default 1337.
      --max-iterations <int>         CreateML iteration cap. Default 50.
      --prediction-window-size <int> MLActivityClassifier prediction window
                                     in frames. Default 60.
      --balance-classes              Deterministically downsample training
                                     clips per class to the smallest class
                                     count. Off by default — imbalance is
                                     reported instead.

    Evaluate options:
      --training-report <path>       Path to ScratchActionClassifier.training-
                                     report.json. When provided, the
                                     evaluator reproduces the train/val
                                     split (deterministic, same seed) and
                                     reports leakage status.
      --weak-class-threshold <f>     Per-class F1 threshold below which a
                                     class is flagged as weak. Default 0.7.
      --top-confusions <n>           How many top mis-prediction pairs to
                                     surface. Default 20.
      --low-confidence-threshold <f> Predictions whose probability is below
                                     this are flagged in the report.
                                     Default 0.5.

      -h, --help                  Show this help.

    Behaviour:
      * No model is trained.
      * No .mlmodel / .mlmodelc / .mlpackage files are produced.
      * Source-clip absolute paths are NOT written into any JSONL output.
      * Each cached frame and each window is one JSON object per line.
    """
}

// MARK: - Helpers

/// Walk up from `start` looking for a `.git` directory. Used to detect when
/// the user has pointed `--windows-out` at a path inside the current
/// working tree, so we can refuse to write generated artefacts there
/// unless `--force-inside-repo` is set.
func findGitRoot(from start: URL) -> URL? {
    var current = start.standardizedFileURL
    while current.path != "/" {
        let candidate = current.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return current
        }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { return nil }
        current = parent
    }
    return nil
}

func pathIsInside(_ child: URL, of parent: URL) -> Bool {
    let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path
    let parentPath = parent.standardizedFileURL.resolvingSymlinksInPath().path
    if childPath == parentPath { return true }
    let parentSlash = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
    return childPath.hasPrefix(parentSlash)
}

func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

// MARK: - Audit mode

func runAuditMode(cachePath: String, args: CLIArguments) -> Never {
    let cacheURL = URL(fileURLWithPath: cachePath, isDirectory: true)
    let validator = FeatureCacheValidator()
    let config = FeatureCacheValidator.Configuration(
        expectedFileCount: args.auditExpectedFiles,
        minimumDominantHandCoverage: args.auditMinHandCoverage,
        minimumDominantHandWristCoverage: args.auditMinWristCoverage
    )
    let report: FeatureCacheAuditReport
    do {
        report = try validator.audit(at: cacheURL, configuration: config)
    } catch {
        writeStderr("audit failed: \(error)\n")
        exit(1)
    }

    print("Cache: \(cacheURL.path)")
    print("Files: \(report.totalFiles)   Frames: \(report.totalFrames)")
    let pct = { (v: Double) in String(format: "%.2f%%", 100 * v) }
    print("Coverage — dominantHand:        \(pct(report.dominantHandCoverage))")
    print("Coverage — dominantHandWrist:   \(pct(report.dominantHandWristCoverage))")
    print("Coverage — secondaryHandWrist:  \(pct(report.secondaryHandWristCoverage))")
    print("Out-of-range frames: \(report.outOfRangeFrameCount)"
        + " (\(pct(report.outOfRangeFraction)))")
    print("")
    print("Per-class:")
    for cls in report.perClassFiles.keys.sorted() {
        let files = report.perClassFiles[cls] ?? 0
        let frames = report.perClassFrames[cls] ?? 0
        let dom = report.perClassDominantHandCoverage[cls] ?? 0
        let wrist = report.perClassDominantHandWristCoverage[cls] ?? 0
        let sec = report.perClassSecondaryHandWristCoverage[cls] ?? 0
        let pad = String(repeating: " ", count: max(0, 22 - cls.count))
        let filesStr = String(format: "%4d", files)
        let framesStr = String(format: "%7d", frames)
        print("  \(cls)\(pad) files=\(filesStr) frames=\(framesStr)"
            + " dom=\(pct(dom)) wrist=\(pct(wrist)) sec=\(pct(sec))")
    }

    print("")
    if let mismatch = report.unexpectedFileCount {
        print("FILE-COUNT MISMATCH: expected \(mismatch.expected),"
            + " observed \(mismatch.observed)")
    }
    if !report.emptyFiles.isEmpty {
        print("Empty files (\(report.emptyFiles.count)):")
        for f in report.emptyFiles { print("  \(f)") }
    }
    if !report.malformedFiles.isEmpty {
        print("Malformed files (\(report.malformedFiles.count)):")
        for f in report.malformedFiles { print("  \(f)") }
    }
    if !report.nonMonotonicFiles.isEmpty {
        print("Non-monotonic timestamp files (\(report.nonMonotonicFiles.count)):")
        for f in report.nonMonotonicFiles { print("  \(f)") }
    }
    if !report.unknownClassFolders.isEmpty {
        print("Unknown class folders (\(report.unknownClassFolders.count)):")
        for f in report.unknownClassFolders { print("  \(f)") }
    }
    if !report.coverageBelowThresholdClasses.isEmpty {
        print("Below dominantHand coverage threshold:"
            + " \(report.coverageBelowThresholdClasses)")
    }
    if !report.wristCoverageBelowThresholdClasses.isEmpty {
        print("Below dominantHandWrist coverage threshold:"
            + " \(report.wristCoverageBelowThresholdClasses)")
    }

    print("")
    print("structurallyClean: \(report.isStructurallyClean)")
    print("meetsAllThresholds: \(report.meetsAllThresholds)")
    exit(report.meetsAllThresholds ? 0 : 1)
}

// MARK: - Window-build mode

func runWindowBuildMode(cachePath: String, args: CLIArguments) -> Never {
    let cacheURL = URL(fileURLWithPath: cachePath, isDirectory: true)
    guard let outPath = args.windowsOutPath else {
        writeStderr("error: --windows-out is required with --build-windows\n")
        exit(2)
    }
    let outURL = URL(fileURLWithPath: outPath, isDirectory: true)

    // Refuse to write generated windows inside the git working tree unless
    // explicitly forced. Users typically point this at an external scratch
    // disk; an accidental in-repo path would otherwise produce hundreds of
    // MB of churn under git status.
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    if let gitRoot = findGitRoot(from: cwd),
       pathIsInside(outURL, of: gitRoot),
       !args.forceInsideRepo {
        writeStderr(
            "error: --windows-out is inside the git working tree (\(gitRoot.path)).\n"
            + "       Pass --force-inside-repo to override, or pick an external path.\n"
        )
        exit(2)
    }

    do {
        try FileManager.default.createDirectory(
            at: outURL,
            withIntermediateDirectories: true
        )
    } catch {
        writeStderr("error: could not create --windows-out directory: \(error)\n")
        exit(1)
    }

    // Inspect the cache directory layout first so we can iterate clips
    // deterministically.
    let cacheValidator = FeatureCacheValidator()
    let auditReport: FeatureCacheAuditReport
    do {
        auditReport = try cacheValidator.audit(at: cacheURL)
    } catch {
        writeStderr("error: could not read cache directory: \(error)\n")
        exit(1)
    }
    if !auditReport.isStructurallyClean {
        writeStderr(
            "warning: cache has structural problems (empty/malformed/unknown);"
            + " continuing but those clips will be skipped silently.\n"
        )
    }

    let builder = MotionWindowBuilder(
        configuration: MotionWindowBuilder.Configuration(
            windowFrames: args.windowFrames,
            strideFrames: args.strideFrames
        )
    )

    var totalWindows = 0
    var totalClipsWithWindows = 0
    var totalClipsSkipped = 0
    var perClassWindowCounts: [String: Int] = [:]
    let encoder = JSONEncoder()
    encoder.outputFormatting = []

    let classes = Array(auditReport.perClassFiles.keys.sorted())
    let totalClips = auditReport.totalFiles
    var clipIndex = 0

    print("\(totalClips) clip(s) queued."
        + " window=\(args.windowFrames) stride=\(args.strideFrames)")

    for cls in classes {
        let classCacheDir = cacheURL.appendingPathComponent(cls, isDirectory: true)
        let classOutDir = outURL.appendingPathComponent(cls, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: classOutDir,
                withIntermediateDirectories: true
            )
        } catch {
            writeStderr("error: could not create class output dir \(classOutDir.path): \(error)\n")
            exit(1)
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: classCacheDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let jsonlFiles = files
            .filter { $0.pathExtension.lowercased() == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for clipURL in jsonlFiles {
            clipIndex += 1
            let progressTag = "[\(clipIndex)/\(totalClips)]"
            let stem = clipURL.deletingPathExtension().lastPathComponent
            let outFileURL = classOutDir.appendingPathComponent("\(stem).windows.jsonl")
            let destTag = "\(cls)/\(stem).windows.jsonl"

            // Per-clip autoreleasepool keeps decoded frame arrays from
            // accumulating across the whole run.
            autoreleasepool {
                if FileManager.default.fileExists(atPath: outFileURL.path) && !args.force {
                    totalClipsSkipped += 1
                    print("\(progressTag) skip   \(destTag) (cached)")
                    return
                }
                do {
                    let windows = try builder.windows(
                        forClipAt: clipURL,
                        classLabel: cls
                    )
                    if windows.isEmpty {
                        totalClipsSkipped += 1
                        print("\(progressTag) skip   \(destTag) (no windows fit)")
                        return
                    }
                    var lines = ""
                    lines.reserveCapacity(windows.count * 4096)
                    for window in windows {
                        let data = try encoder.encode(window)
                        if let line = String(data: data, encoding: .utf8) {
                            lines.append(line)
                            lines.append("\n")
                        }
                    }
                    try lines.write(to: outFileURL, atomically: true, encoding: .utf8)
                    totalWindows += windows.count
                    totalClipsWithWindows += 1
                    perClassWindowCounts[cls, default: 0] += windows.count
                    print("\(progressTag) ok     \(destTag) (\(windows.count) windows)")
                } catch {
                    writeStderr("\(progressTag) FAIL   \(destTag): \(error)\n")
                }
            }
        }
    }

    print("")
    print("Summary:")
    print("  clips with windows:  \(totalClipsWithWindows)")
    print("  clips skipped:       \(totalClipsSkipped)")
    print("  total windows:       \(totalWindows)")
    print("  output:              \(outURL.path)")
    if !perClassWindowCounts.isEmpty {
        print("")
        print("  per-class windows:")
        for cls in perClassWindowCounts.keys.sorted() {
            print("    \(cls): \(perClassWindowCounts[cls] ?? 0)")
        }
    }
    exit(0)
}

// MARK: - Train mode (Slice C, macOS only)

func runTrainMode(windowsPath: String, args: CLIArguments) -> Never {
    let windowsURL = URL(fileURLWithPath: windowsPath, isDirectory: true)
    guard let modelOutPath = args.modelOutPath else {
        writeStderr("error: --model-out is required with --train-action-classifier\n")
        exit(2)
    }
    let modelOutURL = URL(fileURLWithPath: modelOutPath, isDirectory: true)

    // Refuse to write the .mlmodel inside the working tree unless
    // explicitly forced. Generated artefacts are large and the safety
    // boundary is the same as for the windows builder.
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    if let gitRoot = findGitRoot(from: cwd),
       pathIsInside(modelOutURL, of: gitRoot),
       !args.forceInsideRepo {
        writeStderr(
            "error: --model-out is inside the git working tree (\(gitRoot.path)).\n"
            + "       Pass --force-inside-repo to override, or pick an external path.\n"
        )
        exit(2)
    }

    // Up-front load + split (always available — pure Foundation) so we
    // can print the dataset summary even if the platform can't train.
    let dataset: ActionWindowDataset
    do {
        dataset = try ActionWindowDatasetLoader().load(
            windowsDir: windowsURL,
            validationFraction: args.validationFraction,
            seed: args.seed,
            balanceTrainingClasses: args.balanceClasses
        )
    } catch {
        writeStderr("dataset load failed: \(error)\n")
        exit(1)
    }

    print("Windows directory: \(windowsURL.path)")
    print("Model output:      \(modelOutURL.path)")
    print("Windows loaded:    \(dataset.allWindows.count)")
    print("Classes detected:  \(dataset.perClassTotal.keys.count)")
    print("Train/Val clips:   \(dataset.trainingClipCount) / \(dataset.validationClipCount)")
    print("Train/Val windows: \(dataset.trainingWindows.count) / \(dataset.validationWindows.count)")
    print("Validation frac:   \(args.validationFraction)   seed: \(args.seed)")
    let imbalanceFmt = String(format: "%.2f", dataset.imbalanceRatio)
    print("Imbalance ratio:   \(imbalanceFmt) (max-class / min-class training windows)")
    if dataset.balancedTrainingApplied {
        print("Balancing:         applied — training downsampled to smallest class")
    } else if args.balanceClasses {
        print("Balancing:         requested but already balanced; no change")
    } else {
        print("Balancing:         off (imbalance reported, not corrected)")
    }
    print("")
    print("Per-class train / validation:")
    for cls in dataset.perClassTotal.keys.sorted() {
        let tr = dataset.perClassTraining[cls] ?? 0
        let va = dataset.perClassValidation[cls] ?? 0
        let pad = String(repeating: " ", count: max(0, 22 - cls.count))
        print("  \(cls)\(pad) train=\(tr)  val=\(va)")
    }
    print("")

    #if os(macOS)
    print("Trainer:           MLBoostedTreeClassifier"
        + " (per-window summary features,"
        + " maxIterations=\(args.maxIterations))")
    print("Training… (this can take several minutes)")
    let config = ScratchActionClassifierTrainer.TrainingConfiguration(
        windowsDirectory: windowsURL,
        outputDirectory: modelOutURL,
        modelFilename: "ScratchActionClassifier",
        validationFraction: args.validationFraction,
        seed: args.seed,
        balanceTrainingClasses: args.balanceClasses,
        maximumIterations: args.maxIterations,
        predictionWindowSize: args.predictionWindowSize
    )
    let artifacts: ScratchActionClassifierTrainingArtifacts
    do {
        artifacts = try ScratchActionClassifierTrainer().train(config)
    } catch {
        writeStderr("training failed: \(error)\n")
        exit(1)
    }

    let report = artifacts.report
    let pct = { (v: Double?) -> String in
        guard let v = v else { return "n/a" }
        return String(format: "%.2f%%", 100 * v)
    }
    print("")
    print("Model written:     \(artifacts.modelURL.path)")
    print("Report written:    \(artifacts.reportURL.path)")
    print("Training accuracy: \(pct(report.trainingAccuracy))")
    print("Validation acc.:   \(pct(report.validationAccuracy))")
    print("Training duration: "
        + String(format: "%.1f s", report.trainingDurationSeconds))

    if let perClass = report.perClassValidationAccuracy, !perClass.isEmpty {
        print("")
        print("Per-class validation accuracy:")
        for cls in perClass.keys.sorted() {
            let v = perClass[cls] ?? 0
            let pad = String(repeating: " ", count: max(0, 22 - cls.count))
            print("  \(cls)\(pad) \(pct(v))")
        }
    }
    if !report.weakestClasses.isEmpty {
        print("")
        let weakList = report.weakestClasses.joined(separator: ", ")
        let thresholdStr = pct(report.weakClassThreshold)
        print("Weakest classes (validation accuracy < \(thresholdStr)): \(weakList)")
    }
    if let confusion = report.confusion, !confusion.isEmpty {
        print("")
        print("Confusion matrix (top mis-predictions):")
        let misPredictions = confusion
            .filter { $0.actual != $0.predicted && $0.count > 0 }
            .sorted { $0.count > $1.count }
            .prefix(15)
        if misPredictions.isEmpty {
            print("  (none — every prediction matched its label)")
        } else {
            for cell in misPredictions {
                print("  \(cell.actual) → \(cell.predicted): \(cell.count)")
            }
        }
    }
    exit(0)
    #else
    writeStderr("error: training is only available on macOS\n")
    exit(1)
    #endif
}

// MARK: - Evaluate mode (Slice D, macOS only)

func runEvaluateMode(windowsPath: String, args: CLIArguments) -> Never {
    let windowsURL = URL(fileURLWithPath: windowsPath, isDirectory: true)
    guard let modelPath = args.modelPath else {
        writeStderr("error: --model is required with --evaluate-action-classifier\n")
        exit(2)
    }
    guard let evalOutPath = args.evaluationOutPath else {
        writeStderr("error: --evaluation-out is required with --evaluate-action-classifier\n")
        exit(2)
    }
    let modelURL = URL(fileURLWithPath: modelPath)
    let outURL = URL(fileURLWithPath: evalOutPath, isDirectory: true)

    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    if let gitRoot = findGitRoot(from: cwd),
       pathIsInside(outURL, of: gitRoot),
       !args.forceInsideRepo {
        writeStderr(
            "error: --evaluation-out is inside the git working tree (\(gitRoot.path)).\n"
            + "       Pass --force-inside-repo to override, or pick an external path.\n"
        )
        exit(2)
    }

    let trainingReportURL = args.trainingReportPath.map { URL(fileURLWithPath: $0) }

    print("Model:             \(modelURL.path)")
    print("Windows:           \(windowsURL.path)")
    print("Output:            \(outURL.path)")
    if let url = trainingReportURL {
        print("Training report:   \(url.path)")
    } else {
        print("Training report:   (not provided — leakage check skipped)")
    }
    print("Weak threshold:    \(args.weakClassThreshold)")
    print("Top confusions:    \(args.topConfusions)")
    print("")

    #if os(macOS)
    let config = ScratchActionClassifierEvaluator.Configuration(
        modelURL: modelURL,
        windowsDirectory: windowsURL,
        outputDirectory: outURL,
        trainingReportURL: trainingReportURL,
        weakClassThreshold: args.weakClassThreshold,
        topConfusions: args.topConfusions,
        lowConfidenceThreshold: args.lowConfidenceThreshold,
        modelFilename: "ScratchActionClassifier"
    )

    print("Evaluating… (loading model and running predictions)")
    let artifacts: ScratchActionClassifierEvaluator.Artifacts
    do {
        artifacts = try ScratchActionClassifierEvaluator().evaluate(config)
    } catch {
        writeStderr("evaluation failed: \(error)\n")
        exit(1)
    }
    let report = artifacts.report

    print("")
    print("Report written:    \(artifacts.reportURL.path)")
    print("Confusion CSV:     \(artifacts.confusionMatrixCsvURL.path)")
    print("Total windows:     \(report.totalWindowsEvaluated)")
    print(String(format: "Overall accuracy:  %.2f%%", report.overallAccuracy * 100))
    print("Evaluation mode:   \(report.evaluationMode.rawValue)")
    if let train = report.trainOverlapClipCount,
       let val = report.validationOverlapClipCount {
        print("Train clips seen:  \(train)   Val clips seen: \(val)")
    }
    print("Duration:          " + String(format: "%.2f s", report.evaluationDurationSeconds))

    print("")
    print("Per-class precision / recall / F1 / support:")
    let pct = { (v: Double) -> String in String(format: "%.2f%%", 100 * v) }
    for cls in report.perClassMetrics.keys.sorted() {
        guard let m = report.perClassMetrics[cls] else { continue }
        let pad = String(repeating: " ", count: max(0, 22 - cls.count))
        print("  \(cls)\(pad) p=\(pct(m.precision))  r=\(pct(m.recall))"
            + "  f1=\(pct(m.f1))  n=\(m.support)")
    }

    if !report.weakClasses.isEmpty {
        print("")
        let thresholdStr = pct(report.weakClassThreshold)
        print("Weak classes (F1 < \(thresholdStr)): "
            + report.weakClasses.joined(separator: ", "))
    } else {
        print("")
        print("Weak classes: none below F1 threshold "
            + pct(report.weakClassThreshold))
    }

    if !report.topConfusions.isEmpty {
        print("")
        print("Top confusions:")
        for cell in report.topConfusions {
            print("  \(cell.actual) → \(cell.predicted): \(cell.count)")
        }
    }

    if let lowConf = report.lowConfidencePredictions, !lowConf.isEmpty {
        print("")
        let pct = pct(report.lowConfidenceThreshold)
        print("Low-confidence predictions (probability < \(pct)): "
            + "\(lowConf.count) (top 5 shown)")
        for p in lowConf.prefix(5) {
            print("  \(p.sourceFile)#\(p.windowIndex) actual=\(p.actual)"
                + " predicted=\(p.predicted)"
                + " conf=" + String(format: "%.2f", p.confidence))
        }
    } else if report.lowConfidencePredictions != nil {
        print("")
        print("Low-confidence predictions: none below threshold "
            + pct(report.lowConfidenceThreshold))
    }

    if !report.leakageWarnings.isEmpty {
        print("")
        print("Leakage / quality warnings (\(report.leakageWarnings.count)):")
        for w in report.leakageWarnings {
            print("  ! \(w)")
        }
    }

    print("")
    print("Recommendation:")
    print("  readyForRuntimeExperiment: \(report.recommendation.readyForRuntimeExperiment)")
    print("  readyForAppBundle:         \(report.recommendation.readyForAppBundle)")
    print("  reasons:")
    for r in report.recommendation.reasons {
        print("    - \(r)")
    }
    if !report.recommendation.suggestedNextActions.isEmpty {
        print("  suggested next actions:")
        for a in report.recommendation.suggestedNextActions {
            print("    - \(a)")
        }
    }

    exit(0)
    #else
    writeStderr("error: evaluation is only available on macOS\n")
    exit(1)
    #endif
}

// MARK: - Mode dispatch

let parsedArgs: CLIArguments
switch parseArguments(CommandLine.arguments) {
case .ok(let a): parsedArgs = a
case .error(let message):
    writeStderr(message + "\n")
    exit(2)
}

// Mutual exclusion: at most one of --audit-cache, --build-windows,
// --train-action-classifier, --evaluate-action-classifier, --validate-only
// may be set.
let modeFlagsSet = [
    parsedArgs.auditCachePath != nil,
    parsedArgs.buildWindowsCachePath != nil,
    parsedArgs.trainWindowsPath != nil,
    parsedArgs.evaluateWindowsPath != nil,
    parsedArgs.validateOnly,
].filter { $0 }.count
if modeFlagsSet > 1 {
    writeStderr(
        "error: --audit-cache, --build-windows, --train-action-classifier,"
        + " --evaluate-action-classifier, and --validate-only are mutually"
        + " exclusive — pick one.\n"
    )
    exit(2)
}

if let auditPath = parsedArgs.auditCachePath {
    runAuditMode(cachePath: auditPath, args: parsedArgs)
}
if let buildPath = parsedArgs.buildWindowsCachePath {
    runWindowBuildMode(cachePath: buildPath, args: parsedArgs)
}
if let trainWindowsPath = parsedArgs.trainWindowsPath {
    runTrainMode(windowsPath: trainWindowsPath, args: parsedArgs)
}
if let evalWindowsPath = parsedArgs.evaluateWindowsPath {
    runEvaluateMode(windowsPath: evalWindowsPath, args: parsedArgs)
}

guard let datasetPath = parsedArgs.datasetPath else {
    writeStderr("error: --dataset is required\n\(usage())\n")
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
