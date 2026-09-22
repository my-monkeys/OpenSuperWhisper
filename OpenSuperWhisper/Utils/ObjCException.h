#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil when it returned normally.
///
/// Swift cannot catch an `NSException`, and letting one unwind through Swift frames is not just a
/// crash deferred: when it happens inside a main-actor task, the concurrency runtime is left
/// pointing at the dead task's stack. macOS 27 swallows the exception, so nothing fails there and
/// then — the app sits on "Connecting..." and dies on the next click, in
/// `swift_task_isCurrentExecutor`, far from the cause. `AVAudioEngine.installTap` is the one we
/// hit: it raises when the input device is mid-reconfiguration.
FOUNDATION_EXPORT NSException *_Nullable OSWCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
