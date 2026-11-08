#import <Foundation/Foundation.h>
#import <Python/Python.h>

NS_ASSUME_NONNULL_BEGIN
// Trusted host callbacks only. All three Python callbacks run with this owner's
// interpreter attached, on its one dedicated thread. Never capture PyObjects
// belonging to a different interpreter in these blocks.
typedef PyObject * _Nullable (^MMPythonCreate)(void);
typedef id _Nullable (^MMPythonInvoke)(PyObject *source, NSDictionary *payload, NSUInteger remainingBudgetMs);
typedef void (^MMPythonDispose)(PyObject *source);
typedef void (^MMPythonReply)(id _Nullable value, NSString * _Nullable errorCode);

/// Owns a subinterpreter and a bounded serial queue on one OS thread. The main
/// interpreter must outlive every owner; this class never finalizes the runtime.
/// Cancel/revoke do not forcibly terminate Python or C. Close replies only after
/// actual interpreter destruction; a stuck owner must continue consuming a slot.
@interface MMPythonOwner : NSObject
- (instancetype)initWithMainInterpreter:(PyInterpreterState *)mainInterpreter
                                create:(MMPythonCreate)create
                                invoke:(MMPythonInvoke)invoke
                               dispose:(MMPythonDispose)dispose
                             interrupt:(void (^)(NSString *callId))interrupt;
- (void)start:(MMPythonReply)reply;
- (void)invoke:(NSString *)callId payload:(NSDictionary *)payload
      budgetMs:(NSUInteger)budgetMs reply:(MMPythonReply)reply;
// Returns active/queued/absent. Cancellation settles a queued request immediately;
// an active request settles only when its native execution really returns.
- (NSString *)cancel:(NSString *)callId;
- (void)close:(MMPythonReply)reply;
- (NSDictionary *)snapshot;
@end
NS_ASSUME_NONNULL_END
