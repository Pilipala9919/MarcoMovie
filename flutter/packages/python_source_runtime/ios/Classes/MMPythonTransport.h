#import <Flutter/Flutter.h>
#import <Python/Python.h>

// One transport per native owner. Both source identity and currently executing
// call are selected by the native host, never by the source request envelope.
@interface MMPythonTransport : NSObject
- (instancetype)initWithChannel:(FlutterMethodChannel *)channel handle:(NSString *)handle;
- (BOOL)beginCall:(NSString *)callId budgetMs:(NSUInteger)budgetMs;
- (void)endCall;
- (NSUInteger)cancelCall:(NSString *)callId;
@end
PyObject *MMCreatePythonTransportBridge(MMPythonTransport *transport);
