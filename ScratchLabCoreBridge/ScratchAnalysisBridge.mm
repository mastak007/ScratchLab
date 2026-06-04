// ScratchLabCoreBridge — Objective-C++ translation layer over the pure C++ scratch core.
//
// The only file that includes the C++ headers. Pure value translation: NSObject inputs ->
// std::vector, call scratchlab::core::analyzeScratch, std::vector results -> NSObject.
// No algorithm logic lives here.

#import "ScratchAnalysisBridge.h"

#include "ScratchAnalysisCore.hpp"

#include <vector>

using namespace scratchlab::core;

#pragma mark - Input value objects

@implementation SLSPlatterEvent
- (instancetype)initWithTimeSeconds:(double)timeSeconds cc6Step:(NSInteger)cc6Step {
    if ((self = [super init])) {
        _timeSeconds = timeSeconds;
        _cc6Step = cc6Step;
    }
    return self;
}
@end

@implementation SLSCrossfaderEvent
- (instancetype)initWithTimeSeconds:(double)timeSeconds value:(double)value {
    if ((self = [super init])) {
        _timeSeconds = timeSeconds;
        _value = value;
    }
    return self;
}
@end

@implementation SLSAnalysisCalibration
- (instancetype)initWithStepsPerRevolution:(double)stepsPerRevolution
                         crossfaderCutWidth:(double)crossfaderCutWidth {
    if ((self = [super init])) {
        _stepsPerRevolution = stepsPerRevolution;
        _crossfaderCutWidth = crossfaderCutWidth;
    }
    return self;
}
@end

#pragma mark - Output value objects (readonly publicly, writable here)

@interface SLSScratchStroke ()
@property (nonatomic, readwrite) SLSScratchStrokeDirection direction;
@property (nonatomic, readwrite) double startTime;
@property (nonatomic, readwrite) double endTime;
@property (nonatomic, readwrite) double travelPercent;
@property (nonatomic, readwrite) SLSScratchAudibleState audibleState;
@end

@implementation SLSScratchStroke
@end

@interface SLSAnalysisResult ()
@property (nonatomic, readwrite, copy) NSArray<SLSScratchStroke *> *strokes;
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *warnings;
@end

@implementation SLSAnalysisResult
@end

#pragma mark - Enum translation

static SLSScratchStrokeDirection SLSMapDirection(StrokeDirection direction) {
    switch (direction) {
        case StrokeDirection::forward: return SLSScratchStrokeDirectionForward;
        case StrokeDirection::reverse: return SLSScratchStrokeDirectionReverse;
    }
    return SLSScratchStrokeDirectionForward;
}

static SLSScratchAudibleState SLSMapAudible(AudibleState state) {
    switch (state) {
        case AudibleState::unknown: return SLSScratchAudibleStateUnknown;
        case AudibleState::audible: return SLSScratchAudibleStateAudible;
        case AudibleState::cut: return SLSScratchAudibleStateCut;
    }
    return SLSScratchAudibleStateUnknown;
}

static SLSScratchWarning SLSMapWarning(ScratchWarning warning) {
    switch (warning) {
        case ScratchWarning::emptyInput: return SLSScratchWarningEmptyInput;
        case ScratchWarning::invalidCalibration: return SLSScratchWarningInvalidCalibration;
        case ScratchWarning::nonUnitStep: return SLSScratchWarningNonUnitStep;
    }
    return SLSScratchWarningEmptyInput;
}

#pragma mark - Analyzer

@implementation SLSScratchAnalyzer

+ (SLSAnalysisResult *)analyzeWithPlatterEvents:(NSArray<SLSPlatterEvent *> *)platterEvents
                               crossfaderEvents:(NSArray<SLSCrossfaderEvent *> *)crossfaderEvents
                                    calibration:(SLSAnalysisCalibration *)calibration {
    std::vector<PlatterEvent> platter;
    platter.reserve(platterEvents.count);
    for (SLSPlatterEvent *event in platterEvents) {
        platter.push_back(PlatterEvent{event.timeSeconds, static_cast<int>(event.cc6Step)});
    }

    std::vector<CrossfaderEvent> crossfader;
    crossfader.reserve(crossfaderEvents.count);
    for (SLSCrossfaderEvent *event in crossfaderEvents) {
        crossfader.push_back(CrossfaderEvent{event.timeSeconds, event.value});
    }

    const Calibration cal{calibration.stepsPerRevolution, calibration.crossfaderCutWidth};

    const AnalysisResult result = analyzeScratch(platter, crossfader, cal);

    NSMutableArray<SLSScratchStroke *> *strokes =
        [NSMutableArray arrayWithCapacity:result.strokes.size()];
    for (const Stroke &stroke : result.strokes) {
        SLSScratchStroke *out = [[SLSScratchStroke alloc] init];
        out.direction = SLSMapDirection(stroke.direction);
        out.startTime = stroke.startTime;
        out.endTime = stroke.endTime;
        out.travelPercent = stroke.travelPercent;
        out.audibleState = SLSMapAudible(stroke.audibleState);
        [strokes addObject:out];
    }

    NSMutableArray<NSNumber *> *warnings =
        [NSMutableArray arrayWithCapacity:result.warnings.size()];
    for (const ScratchWarning warning : result.warnings) {
        [warnings addObject:@(SLSMapWarning(warning))];
    }

    SLSAnalysisResult *out = [[SLSAnalysisResult alloc] init];
    out.strokes = strokes;
    out.warnings = warnings;
    return out;
}

@end
