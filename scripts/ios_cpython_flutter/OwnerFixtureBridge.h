#import <Flutter/Flutter.h>
#import <Python/Python.h>

// Disposable-app adapter for the shared native owner. Bundled fixture only.
@interface OwnerFixtureBridge : NSObject
- (instancetype)initWithChannel:(FlutterMethodChannel *)channel interpreter:(PyInterpreterState *)interpreter;
- (void)handle:(FlutterMethodCall *)call result:(FlutterResult)result;
@end
