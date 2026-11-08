#import "MMPythonRuntimePlugin.h"
#import "MMPythonRuntime.h"
#import "MMPythonSourceRegistry.h"

@interface MMPythonRuntimePlugin ()
@property(nonatomic,strong) FlutterMethodChannel *channel;
@property(nonatomic,strong) MMPythonSourceRegistry *registry;
@property(nonatomic,strong) MMPythonRuntime *runtime;
@property(nonatomic,strong) NSThread *worker;
@property(nonatomic,strong) NSMutableArray *waiting;
@end

@implementation MMPythonRuntimePlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    MMPythonRuntimePlugin *plugin=[[self alloc] init];
    plugin.waiting=[NSMutableArray array];
    plugin.channel=[FlutterMethodChannel methodChannelWithName:@"marco_movie/python_source" binaryMessenger:registrar.messenger];
    [registrar addMethodCallDelegate:plugin channel:plugin.channel];
}
- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSAssert(NSThread.isMainThread,@"Python channel requires the platform thread");
    if (![@[@"python.capabilities",@"python.open",@"python.call",@"python.cancel",@"python.close"] containsObject:call.method]) {
        result(FlutterMethodNotImplemented);return;
    }
    if (self.runtime) { [self execute:call result:result];return; }
    if (![@[@"python.capabilities",@"python.open"] containsObject:call.method]) {
        result([FlutterError errorWithCode:@"runtime_unavailable" message:@"Python source is not open" details:nil]);return;
    }
    if (self.waiting.count>=4) {
        result([FlutterError errorWithCode:@"runtime_limit" message:@"Python is starting, please retry" details:nil]);return;
    }
    [self.waiting addObject:@{@"call":call,@"reply":[result copy]}];
    if (!self.worker) {
        self.worker=[[NSThread alloc] initWithTarget:self selector:@selector(startRuntime) object:nil];
        self.worker.name=@"marco-python-runtime";self.worker.stackSize=8*1024*1024;[self.worker start];
    }
}
- (void)startRuntime {
    @autoreleasepool {
        MMPythonRuntime *runtime=[MMPythonRuntime sharedRuntime];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.runtime=runtime;
            if (runtime.interpreter) self.registry=[[MMPythonSourceRegistry alloc] initWithChannel:self.channel interpreter:runtime.interpreter];
            NSArray *pending=[self.waiting copy];[self.waiting removeAllObjects];
            for (NSDictionary *job in pending) [self execute:job[@"call"] result:job[@"reply"]];
        });
        // Keep the process bootstrap thread alive; individual sources never run here.
        NSRunLoop *loop=NSRunLoop.currentRunLoop;[loop addPort:[NSPort port] forMode:NSDefaultRunLoopMode];
        while (YES) { @autoreleasepool { [loop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture]; } }
    }
}
- (void)execute:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (!self.registry) {
        result([FlutterError errorWithCode:@"runtime_unavailable" message:self.runtime.failure?:@"Python runtime unavailable" details:nil]);return;
    }
    if ([call.method isEqual:@"python.capabilities"]) {
        if (call.arguments!=nil) { result([FlutterError errorWithCode:@"invalid_request" message:@"Capabilities takes no arguments" details:nil]);return; }
        result(@{@"version":@1,@"runtime":self.runtime.version,@"maxSessions":@2,@"hardCancel":@NO,@"sourceThreads":@NO});return;
    }
    [self.registry handle:call result:result];
}
@end
