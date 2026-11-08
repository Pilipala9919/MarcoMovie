// Disposable native iOS lxml experiment. Never part of the product runtime.
#import <UIKit/UIKit.h>
#import <Python/Python.h>
#include <atomic>
#include <cstdio>

extern "C" PyObject *run_owners(const char *, const char *);
static std::atomic<int> heartbeat{0};
static std::atomic<bool> finished{false};
static NSString *documents;

static void saveJSON(NSDictionary *report, NSString *name) {
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    if (![bytes writeToFile:[documents stringByAppendingPathComponent:name] atomically:YES])
        NSLog(@"LxmlProbe could not write %@",name);
}

static void checkpoint(NSString *phase) {
    saveJSON(@{@"phase":phase,@"heartbeat":@(heartbeat.load())},@"progress.json");
}

static void uncaughtException(NSException *exception) {
    saveJSON(@{@"passed":@NO,@"exception":exception.name?:@"",@"reason":exception.reason?:@"",
               @"stack":exception.callStackSymbols?:@[]},@"exception.json");
}

static NSString *pythonError(void) {
    PyObject *error=PyErr_GetRaisedException();
    if (!error) return @"Python call failed without exception";
    PyObject *text=PyObject_Str(error);
    const char *utf8=text ? PyUnicode_AsUTF8(text) : NULL;
    NSString *message=utf8 ? [NSString stringWithUTF8String:utf8] : @"Could not format Python exception";
    Py_XDECREF(text);Py_DECREF(error);PyErr_Clear();return message;
}

static BOOL statusOK(PyStatus status, NSString **failure) {
    if (!PyStatus_Exception(status)) return YES;
    *failure=status.err_msg ? [NSString stringWithUTF8String:status.err_msg] : @"Python initialization failed";
    return NO;
}

static void addCheck(NSMutableArray *checks, NSString *name, BOOL passed) {
    [checks addObject:@{@"name":name,@"passed":@(passed)}];
}

@interface LxmlProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end

@implementation LxmlProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *view=[UIViewController new];view.view.backgroundColor=UIColor.blackColor;
    self.window.rootViewController=view;[self.window makeKeyAndVisible];
    documents=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES) firstObject];
    [[NSFileManager defaultManager] createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    freopen([[documents stringByAppendingPathComponent:@"native-stderr.log"] fileSystemRepresentation],"w",stderr);
    freopen([[documents stringByAppendingPathComponent:@"native-stdout.log"] fileSystemRepresentation],"w",stdout);
    setvbuf(stderr,NULL,_IONBF,0);setvbuf(stdout,NULL,_IONBF,0);
    NSSetUncaughtExceptionHandler(uncaughtException);
    checkpoint(@"uikit_did_finish_launching");
    [NSTimer scheduledTimerWithTimeInterval:.01 repeats:YES block:^(NSTimer *) { ++heartbeat; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if (!finished.load()) saveJSON(@{@"passed":@NO,@"failure":@"Owned lxml probe deadline",
            @"heartbeat":@(heartbeat.load())},@"watchdog.json");
    });
    NSThread *worker=[[NSThread alloc] initWithBlock:^{ @autoreleasepool { [self runProbe]; } }];
    worker.name=@"experimental-lxml-probe";worker.stackSize=8*1024*1024;[worker start];return YES;
}

- (void)runProbe {
    NSString *failure=nil;NSMutableArray *checks=[NSMutableArray array];
    NSMutableDictionary *report=[@{@"passed":@NO,@"checks":checks,
        @"experiment":@"ios-lxml-own-gil",@"physical_device_tested":@NO,
        @"product_enabled":@NO,@"flutter_integration_tested":@NO} mutableCopy];
#if defined(__arm64__) || defined(__aarch64__)
    report[@"native_arch"]=@"arm64";
#else
    report[@"native_arch"]=@"x86_64";
#endif
    report[@"os_version"]=UIDevice.currentDevice.systemVersion;
    NSString *bundle=NSBundle.mainBundle.resourcePath;
    report[@"bundle_path"]=bundle;
    PyPreConfig pre;PyPreConfig_InitIsolatedConfig(&pre);pre.utf8_mode=1;
    PyConfig config;PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode=0;config.buffered_stdio=0;config.install_signal_handlers=0;
    config.site_import=0;config.parse_argv=0;config.use_system_logger=1;
    BOOL initialized=NO;
    addCheck(checks,@"probe_runs_off_ui_thread",![NSThread isMainThread]);
    checkpoint(@"python_preinitialize");
    if (!statusOK(Py_PreInitialize(&pre),&failure)) goto done;
    if (!statusOK(PyConfig_SetBytesString(&config,&config.home,[[bundle stringByAppendingPathComponent:@"python"] UTF8String]),&failure)) goto done;
    if (!statusOK(PyConfig_SetBytesString(&config,&config.program_name,"CPythonProbe"),&failure)) goto done;
    // CPython's AppleFrameworkLoader resolves .fwork paths from sys.executable.
    if (!statusOK(PyConfig_SetBytesString(&config,&config.executable,NSBundle.mainBundle.executablePath.UTF8String),&failure)) goto done;
    for (NSString *relative in @[@"python/lib/python3.14",@"python/lib/python3.14/lib-dynload",@"app_packages",@"app"]) {
        wchar_t *path=Py_DecodeLocale([[bundle stringByAppendingPathComponent:relative] UTF8String],NULL);
        if (!path) { failure=@"Path decoding failed";goto done; }
        PyStatus status=PyWideStringList_Append(&config.module_search_paths,path);PyMem_RawFree(path);
        if (!statusOK(status,&failure)) goto done;
    }
    config.module_search_paths_set=1;
    checkpoint(@"python_initialize");
    if (!statusOK(Py_InitializeFromConfig(&config),&failure)) goto done;
    initialized=YES;
    report[@"runtime"]=[NSString stringWithUTF8String:Py_GetVersion()];
    {
        const char *platform=PyUnicode_AsUTF8(PySys_GetObject("platform"));
        if (!platform) { failure=pythonError();goto done; }
        report[@"platform"]=[NSString stringWithUTF8String:platform];
        addCheck(checks,@"actual_ios_python",[report[@"platform"] isEqualToString:@"ios"]);
        addCheck(checks,@"pinned_python_3_14_10",[report[@"runtime"] hasPrefix:@"3.14.10 "]);
        PyObject *fault=PyImport_ImportModule("faulthandler");
        PyObject *enabled=fault ? PyObject_CallMethod(fault,"enable","i",2) : NULL;
        Py_XDECREF(fault);
        if (!enabled) { failure=pythonError();goto done; }
        Py_DECREF(enabled);
    }
    {
        checkpoint(@"concurrent_own_gil_owners");
        int before=heartbeat.load();
        dispatch_semaphore_t ping=dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(),^{ dispatch_semaphore_signal(ping); });
        PyObject *result=run_owners([[bundle stringByAppendingPathComponent:@"app_packages"] UTF8String],
                                  [[bundle stringByAppendingPathComponent:@"app/owner_fixture.py"] UTF8String]);
        int during=heartbeat.load()-before;
        report[@"heartbeat_during_owners"]=@(during);
        // The ping is queued while the background thread begins its owner work.
        // No host operation below synchronously dispatches Python to the UI.
        BOOL responsive=dispatch_semaphore_wait(ping,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0;
        addCheck(checks,@"ui_main_thread_remained_responsive",responsive&&during>0);
        if (!result) { failure=pythonError();goto done; }
        PyObject *json=PyImport_ImportModule("json");
        PyObject *encoded=json ? PyObject_CallMethod(json,"dumps","O",result) : NULL;
        Py_DECREF(result);Py_XDECREF(json);
        const char *text=encoded ? PyUnicode_AsUTF8(encoded) : NULL;
        NSData *data=text ? [[NSString stringWithUTF8String:text] dataUsingEncoding:NSUTF8StringEncoding] : nil;
        NSDictionary *owners=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        Py_XDECREF(encoded);
        if (![owners isKindOfClass:NSDictionary.class]) { failure=pythonError();goto done; }
        report[@"owner_harness"]=owners;
        addCheck(checks,@"own_gil_owner_lifecycle",[owners[@"passed"] boolValue]);
        addCheck(checks,@"peer_use_after_owner_destroyed",[owners[@"peer_used_after_alpha_destroyed"] boolValue]);
        addCheck(checks,@"main_interpreter_remains_attached",PyInterpreterState_GetID(PyInterpreterState_Get())==0);
        addCheck(checks,@"lxml_absent_from_main_interpreter",PyDict_GetItemString(PyImport_GetModuleDict(),"lxml.etree")==NULL);
        checkpoint(@"all_owners_joined_and_destroyed");
    }
done:
    PyConfig_Clear(&config);
    if (initialized) {
        if (PyErr_Occurred()) PyErr_Clear();
        // The UIKit process keeps CPython alive. Its three test owners have all
        // ended before this point; only the external runner terminates the app.
        PyEval_SaveThread();
    }
    BOOL passed=initialized&&failure==nil;
    for (NSDictionary *entry in checks) if (![entry[@"passed"] boolValue]) passed=NO;
    report[@"passed"]=@(passed);report[@"failure"]=failure?:@"";report[@"heartbeat"]=@(heartbeat.load());
    report[@"limitations"]=@[@"Simulator only; no physical-device or iOS14 execution claim",
        @"No Flutter integration or external source playback",
        @"Subinterpreters share process and filesystem; no hard in-process cancellation"];
    checkpoint(@"write_result");saveJSON(report,@"result.json");finished=true;
}
@end

int main(int argc,char **argv) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(LxmlProbeDelegate.class)); }
}
