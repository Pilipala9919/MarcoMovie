#import <Foundation/Foundation.h>
#import <Python/Python.h>

/// Process-lifetime runtime. Initialize off the UI thread; owners use their own
/// thread state. Never finalize while Node, Flutter or a source owner is alive.
@interface MMPythonRuntime : NSObject
@property(nonatomic,readonly) PyThreadState *mainState;
@property(nonatomic,readonly) PyInterpreterState *interpreter;
@property(nonatomic,readonly) NSString *version;
@property(nonatomic,readonly) NSString *failure;
@property(nonatomic,readonly) NSDictionary *signalsBefore;
@property(nonatomic,readonly) NSDictionary *signalsAfter;
@property(nonatomic,readonly) BOOL preservedInterrupt;
+ (instancetype)sharedRuntime;
@end
