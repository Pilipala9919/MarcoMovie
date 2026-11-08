#import <Flutter/Flutter.h>
#import <Python/Python.h>

// Main-thread registry over dedicated native owners. Runtime initialization is
// supplied by the embedding app and must outlive this registry and all owners.
@interface MMPythonSourceRegistry : NSObject
- (instancetype)initWithChannel:(FlutterMethodChannel *)channel interpreter:(PyInterpreterState *)interpreter;
- (void)handle:(FlutterMethodCall *)call result:(FlutterResult)result;
- (NSDictionary *)snapshot;
@end
