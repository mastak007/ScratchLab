//
//  main.swift
//  TrainSoundClassifier (CLI)
//
//  Thin executable wrapping `SoundClassifierTrainer`. Run from the package
//  root:
//
//      swift run train-sound-classifier \
//          --dataset <path-to-coreml_ready/sound_classifier> \
//          --output  <path-to-output-dir>
//
//  No paths are baked into the binary; the dataset must be passed in.
//  No training data is bundled.
//

import Foundation
import SoundTrainer

struct CLIArguments {
    var datasetPath: String?
    var outputPath: String?
    var modelFilename: String = "ScratchSoundClassifier"
    var minimumSamplesPerClass: Int = 3
    var validateOnly: Bool = false
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
        case "--output":
            i += 1
            guard i < argv.count else { return .error("--output needs a value") }
            args.outputPath = argv[i]
        case "--model-name":
            i += 1
            guard i < argv.count else { return .error("--model-name needs a value") }
            args.modelFilename = argv[i]
        case "--min-per-class":
            i += 1
            guard i < argv.count, let n = Int(argv[i]) else {
                return .error("--min-per-class needs an integer")
            }
            args.minimumSamplesPerClass = n
        case "--validate-only":
            args.validateOnly = true
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
    Usage: train-sound-classifier --dataset <dir> --output <dir> [options]

    Options:
      --dataset <dir>          Path to a Create ML sound classifier dataset
                               (one subfolder per class label).
      --output <dir>           Directory to write the trained .mlmodel into.
      --model-name <name>      Output model basename. Default: ScratchSoundClassifier.
      --min-per-class <int>    Minimum sample count per class. Default: 3.
      --validate-only          Validate the dataset and exit without training.
      -h, --help               Show this help.

    The CLI never bundles training data. The output .mlmodel contains no
    author, license, or version metadata.
    """
}

let args: CLIArguments
switch parseArguments(CommandLine.arguments) {
case .ok(let a): args = a
case .error(let message):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

guard let datasetPath = args.datasetPath else {
    FileHandle.standardError.write(Data("error: --dataset is required\n\(usage())\n".utf8))
    exit(2)
}

let datasetURL = URL(fileURLWithPath: datasetPath, isDirectory: true)
let trainer = SoundClassifierTrainer()

do {
    let validation = try trainer.validateDataset(
        at: datasetURL,
        minimumSamplesPerClass: args.minimumSamplesPerClass
    )
    print("Dataset OK — \(validation.labels.count) classes:")
    for label in validation.labels {
        let count = validation.perLabelCount[label] ?? 0
        print("  \(label.rawValue): \(count) sample(s)")
    }
} catch {
    FileHandle.standardError.write(Data("validation failed: \(error)\n".utf8))
    exit(1)
}

if args.validateOnly {
    exit(0)
}

#if os(macOS)
guard let outputPath = args.outputPath else {
    FileHandle.standardError.write(Data("error: --output is required when training\n".utf8))
    exit(2)
}
let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
let config = SoundClassifierTrainer.TrainingConfiguration(
    datasetURL: datasetURL,
    outputDirectory: outputURL,
    modelFilename: args.modelFilename,
    minimumSamplesPerClass: args.minimumSamplesPerClass
)
do {
    print("Training... this may take several minutes.")
    let modelURL = try trainer.train(config)
    print("Wrote model: \(modelURL.path)")
} catch {
    FileHandle.standardError.write(Data("training failed: \(error)\n".utf8))
    exit(1)
}
#else
FileHandle.standardError.write(Data("training is only available on macOS\n".utf8))
exit(1)
#endif
