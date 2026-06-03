// ScratchLabCoreBridge — Objective-C surface for the pure C++ scratch notation core.
//
// This header is PURE Objective-C (no C++ tokens), so it is safe to expose to Swift via
// the bridging header. It mirrors the committed C++ core types in ScratchLabCore exactly:
//   PlatterEvent { timeSeconds, cc6Step }
//   CrossfaderEvent { timeSeconds, value }
//   Calibration { stepsPerRevolution, crossfaderCutWidth }
//   Stroke { direction, startTime, endTime, travelPercent, audibleState }
//   AnalysisResult { strokes, warnings }
// No renaming of fields and no derived fields are introduced here — translation only.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Mirrors scratchlab::core::StrokeDirection.
typedef NS_ENUM(NSInteger, SLSScratchStrokeDirection) {
    SLSScratchStrokeDirectionForward = 0,
    SLSScratchStrokeDirectionReverse = 1,
};

/// Mirrors scratchlab::core::AudibleState.
typedef NS_ENUM(NSInteger, SLSScratchAudibleState) {
    SLSScratchAudibleStateUnknown = 0,
    SLSScratchAudibleStateAudible = 1,
    SLSScratchAudibleStateCut = 2,
};

/// Mirrors scratchlab::core::ScratchWarning.
typedef NS_ENUM(NSInteger, SLSScratchWarning) {
    SLSScratchWarningEmptyInput = 0,
    SLSScratchWarningInvalidCalibration = 1,
    SLSScratchWarningNonUnitStep = 2,
};

/// Mirrors scratchlab::core::PlatterEvent.
@interface SLSPlatterEvent : NSObject
@property (nonatomic, readonly) double timeSeconds;
@property (nonatomic, readonly) NSInteger cc6Step;
- (instancetype)initWithTimeSeconds:(double)timeSeconds
                            cc6Step:(NSInteger)cc6Step NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Mirrors scratchlab::core::CrossfaderEvent.
@interface SLSCrossfaderEvent : NSObject
@property (nonatomic, readonly) double timeSeconds;
@property (nonatomic, readonly) double value;
- (instancetype)initWithTimeSeconds:(double)timeSeconds
                              value:(double)value NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Mirrors scratchlab::core::Calibration. stepsPerRevolution is a Double (CC6 steps per
/// revolution), never a fixed-width integer.
@interface SLSAnalysisCalibration : NSObject
@property (nonatomic, readonly) double stepsPerRevolution;
@property (nonatomic, readonly) double crossfaderCutWidth;
- (instancetype)initWithStepsPerRevolution:(double)stepsPerRevolution
                         crossfaderCutWidth:(double)crossfaderCutWidth NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Mirrors scratchlab::core::Stroke. Output-only; constructed by the analyzer.
@interface SLSScratchStroke : NSObject
@property (nonatomic, readonly) SLSScratchStrokeDirection direction;
@property (nonatomic, readonly) double startTime;
@property (nonatomic, readonly) double endTime;
@property (nonatomic, readonly) double travelPercent;
@property (nonatomic, readonly) SLSScratchAudibleState audibleState;
@end

/// Mirrors scratchlab::core::AnalysisResult. `warnings` holds boxed SLSScratchWarning values.
@interface SLSAnalysisResult : NSObject
@property (nonatomic, readonly) NSArray<SLSScratchStroke *> *strokes;
@property (nonatomic, readonly) NSArray<NSNumber *> *warnings;
@end

/// Entry point. Translates the inputs to the C++ core, runs analyzeScratch, and translates
/// the result back. The C++ algorithm is untouched.
@interface SLSScratchAnalyzer : NSObject
+ (SLSAnalysisResult *)analyzeWithPlatterEvents:(NSArray<SLSPlatterEvent *> *)platterEvents
                               crossfaderEvents:(NSArray<SLSCrossfaderEvent *> *)crossfaderEvents
                                    calibration:(SLSAnalysisCalibration *)calibration
    NS_SWIFT_NAME(analyze(platter:crossfader:calibration:));
@end

NS_ASSUME_NONNULL_END
