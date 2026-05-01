#!/bin/zsh
set -euo pipefail

APP_NAME="ScratchLab"
BUNDLE_ID="com.machelpnz.scratchlab"
SCRIPT_DIR="${0:A:h}"
DEMO_SESSION_ID="11111111-1111-1111-1111-111111111111"
DEMO_TAKE_ID="take-001"
DEMO_BASE_NAME="${DEMO_SESSION_ID}_take001_mac-routine"

seed_demo_capture=1

usage() {
  cat <<USAGE
Usage:
  $0
  $0 --no-demo-capture
  $0 --print-store-json

Seeds deterministic macOS App Review demo data for real ScratchLab UI screenshots.
The default run writes:
  - selected routine session: Demo DJ / Baby Scratch / 90 BPM / Full Capture
  - completed local routine capture sidecar plus generated .mov and .wav for export-ready UI

Use --no-demo-capture when you only want draft sessions and will record a real take manually.
Use --print-store-json from tests to validate the seeded draft store without touching user data.
USAGE
}

for argument in "$@"; do
  case "${argument}" in
    --no-demo-capture)
      seed_demo_capture=0
      ;;
    --print-store-json)
      print_store_json=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: ${argument}" >&2
      usage >&2
      exit 64
      ;;
  esac
done

STORE_CONTENT='{
  "selectedSessionID" : "11111111-1111-1111-1111-111111111111",
  "sessions" : [
    {
      "config" : {
        "bpm" : 90,
        "createdAt" : "2026-04-25T00:00:00Z",
        "drillMode" : "fullCapture",
        "handedness" : "right",
        "notes" : "Baby Scratch Warmup. Completed take: Warmup 01.",
        "performerName" : "Demo DJ",
        "scratchTypeID" : "baby_scratch",
        "scratchTypeName" : "Baby Scratch",
        "sessionID" : "11111111-1111-1111-1111-111111111111",
        "takeCount" : 1,
        "takeDurationSeconds" : 12,
        "updatedAt" : "2026-04-25T00:02:00Z"
      }
    },
    {
      "config" : {
        "bpm" : 110,
        "createdAt" : "2026-04-24T22:45:00Z",
        "drillMode" : "cameraAudioOnly",
        "handedness" : "right",
        "notes" : "Safe placeholder review session. Take names: Transform Sprint 01.",
        "performerName" : "Demo DJ",
        "scratchTypeID" : "transform",
        "scratchTypeName" : "Transform",
        "sessionID" : "22222222-2222-2222-2222-222222222222",
        "takeCount" : 1,
        "takeDurationSeconds" : 26,
        "updatedAt" : "2026-04-24T22:52:00Z"
      }
    }
  ]
}'

if [[ "${print_store_json:-0}" == "1" ]]; then
  printf "%s\n" "${STORE_CONTENT}"
  exit 0
fi

if /usr/bin/pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
  echo "Quitting ${APP_NAME} so seeded demo data is picked up on next launch..."
  /usr/bin/osascript <<APPLESCRIPT >/dev/null
tell application "${APP_NAME}"
  quit
end tell
APPLESCRIPT

  for _ in {1..40}; do
    if ! /usr/bin/pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
      break
    fi
    /bin/sleep 0.25
  done
fi

typeset -a TARGETS

add_target() {
  local candidate="$1"
  [[ -n "${candidate}" ]] || return 0
  (( ${TARGETS[(Ie)${candidate}]} )) && return 0
  TARGETS+=("${candidate}")
}

generate_demo_video() {
  local output_path="$1"

  /usr/bin/swift - "${output_path}" <<'SWIFT'
import AVFoundation
import CoreMedia
import CoreVideo
import Dispatch
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: outputURL)

let width = 1280
let height = 720
let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height
    ]
)
input.expectsMediaDataInRealTime = false

let attributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height
]
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: attributes
)

guard writer.canAdd(input) else {
    fatalError("Unable to add video input.")
}
writer.add(input)

guard writer.startWriting() else {
    throw writer.error ?? NSError(domain: "ScratchLabReviewSeed", code: 1)
}
writer.startSession(atSourceTime: .zero)

for frameIndex in 0..<60 {
    while !input.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.01)
    }

    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard let pixelBuffer else {
        fatalError("Unable to create video frame.")
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt32.self)
    let pixelsPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt32>.size
    let shade = UInt32(34 + (frameIndex % 12))
    let color = UInt32(255 << 24) | (shade << 16) | (shade << 8) | shade
    for y in 0..<height {
        let row = baseAddress.advanced(by: y * pixelsPerRow)
        for x in 0..<width {
            row[x] = color
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: 30)
    guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
        throw writer.error ?? NSError(domain: "ScratchLabReviewSeed", code: 2)
    }
}

input.markAsFinished()
let semaphore = DispatchSemaphore(value: 0)
writer.finishWriting {
    semaphore.signal()
}
semaphore.wait()

guard writer.status == .completed else {
    throw writer.error ?? NSError(domain: "ScratchLabReviewSeed", code: 3)
}
SWIFT
}

generate_demo_audio() {
  local output_path="$1"
  local duration_seconds="${2:-12}"

  /usr/bin/python3 - "${output_path}" "${duration_seconds}" <<'PY'
import math
import os
import struct
import sys
import wave

output_path = sys.argv[1]
duration_seconds = max(0.5, float(sys.argv[2]))
sample_rate = 44_100
frequency = 440.0
amplitude = 0.18
fade_frames = max(1, int(sample_rate * 0.05))
frame_count = int(sample_rate * duration_seconds)

try:
    os.remove(output_path)
except FileNotFoundError:
    pass

with wave.open(output_path, "wb") as wav_file:
    wav_file.setnchannels(1)
    wav_file.setsampwidth(2)
    wav_file.setframerate(sample_rate)

    for frame_index in range(frame_count):
        fade_in = min(1.0, frame_index / fade_frames)
        fade_out = min(1.0, (frame_count - frame_index) / fade_frames)
        envelope = min(fade_in, fade_out)
        sample = math.sin((2.0 * math.pi * frequency * frame_index) / sample_rate)
        pcm_value = int(32767 * amplitude * envelope * sample)
        wav_file.writeframesraw(struct.pack("<h", pcm_value))

    wav_file.writeframes(b"")
PY

  if [[ ! -s "${output_path}" ]]; then
    echo "Failed to generate ${output_path}; cannot seed export-ready demo audio." >&2
    exit 1
  fi
}

write_demo_capture() {
  local store_path="$1"
  local scratchlab_dir="${store_path:h}"
  local capture_dir="${scratchlab_dir}/RoutineCaptures"
  local media_path="${capture_dir}/${DEMO_BASE_NAME}.mov"
  local audio_path="${capture_dir}/${DEMO_BASE_NAME}.wav"
  local sidecar_path="${capture_dir}/${DEMO_BASE_NAME}.json"

  /bin/mkdir -p "${capture_dir}"

  generate_demo_video "${media_path}"
  generate_demo_audio "${audio_path}" 12

  cat > "${sidecar_path}" <<JSON
{
  "appLocalTakeNumber" : 1,
  "appSurface" : "ScratchLab Routine Recorder",
  "audioDeviceName" : "Serato Virtual Audio",
  "audioDeviceUniqueID" : "review-demo-audio",
  "audioInputName" : "Serato Virtual Audio",
  "auditTrail" : [
    {
      "category" : "take_allocated",
      "detail" : "Allocated ${DEMO_TAKE_ID} for session ${DEMO_SESSION_ID}.",
      "id" : "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "timestamp" : "2026-04-25T00:01:00Z"
    },
    {
      "category" : "recording_completed",
      "detail" : "Recording completed successfully.",
      "id" : "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      "timestamp" : "2026-04-25T00:01:12Z"
    }
  ],
  "cameraPosition" : "unspecified",
  "endedAt" : "2026-04-25T00:01:12Z",
  "mediaFileName" : "${DEMO_BASE_NAME}.mov",
  "platform" : "macOS",
  "recordingRole" : "mac_routine_capture",
  "recordingStatus" : "completed",
  "schemaVersion" : "scratchlab_local_recording_sidecar_v1",
  "sessionConfig" : {
    "bpm" : 90,
    "createdAt" : "2026-04-25T00:00:00Z",
    "drillMode" : "fullCapture",
    "handedness" : "right",
    "notes" : "Baby Scratch Warmup. Completed take: Warmup 01.",
    "performerName" : "Demo DJ",
    "scratchTypeID" : "baby_scratch",
    "scratchTypeName" : "Baby Scratch",
    "sessionID" : "${DEMO_SESSION_ID}",
    "takeCount" : 1,
    "takeDurationSeconds" : 12,
    "updatedAt" : "2026-04-25T00:02:00Z"
  },
  "sessionID" : "${DEMO_SESSION_ID}",
  "sidecarFileName" : "${DEMO_BASE_NAME}.json",
  "sourceDeviceName" : "Review Demo Mac",
  "startedAt" : "2026-04-25T00:01:00Z",
  "takeID" : "${DEMO_TAKE_ID}",
  "videoDeviceName" : "MacBook Pro Camera",
  "videoDeviceUniqueID" : "review-demo-camera",
  "watchSyncState" : "notRequested"
}
JSON

  echo "Seeded completed demo capture at ${capture_dir}"
}

add_target "${HOME}/Library/Application Support/ScratchLab/RoutineSessionDrafts.json"
add_target "${HOME}/Library/Containers/${BUNDLE_ID}/Data/Library/Application Support/ScratchLab/RoutineSessionDrafts.json"

for container_root in "${HOME}"/Library/Containers/*; do
  [[ -d "${container_root}" ]] || continue

  if [[ -d "${container_root}/Data/Library/Application Support/ScratchLab" \
        || -f "${container_root}/Data/Library/Preferences/${BUNDLE_ID}.plist" \
        || -d "${container_root}/Data/Library/Application Scripts/${BUNDLE_ID}" ]]; then
    add_target "${container_root}/Data/Library/Application Support/ScratchLab/RoutineSessionDrafts.json"
  fi
done

for store_path in "${TARGETS[@]}"; do
  /bin/mkdir -p "${store_path:h}"
  printf "%s\n" "${STORE_CONTENT}" > "${store_path}"
  echo "Seeded review demo sessions at ${store_path}"

  if [[ "${seed_demo_capture}" == "1" ]]; then
    write_demo_capture "${store_path}"
  fi
done

echo "Launch ScratchLab and open Routine Capture to review the selected session and completed take."
