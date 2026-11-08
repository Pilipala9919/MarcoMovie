#import "MMPythonRuntime.h"
#include <signal.h>

static NSString *MMDisposition(const struct sigaction &value) {
    return value.sa_handler==SIG_IGN?@"ignored":value.sa_handler==SIG_DFL?@"default":@"custom";
}
static NSDictionary *MMSignals(void) {
    struct sigaction pipe={},interrupt={};
    if (sigaction(SIGPIPE,NULL,&pipe)!=0 || sigaction(SIGINT,NULL,&interrupt)!=0) return @{@"error":@YES};
    return @{@"sigpipe":MMDisposition(pipe),@"sigint":MMDisposition(interrupt)};
}

@implementation MMPythonRuntime
+ (instancetype)sharedRuntime {
    NSAssert(!NSThread.isMainThread,@"Python initialization must not block the UI thread");
    static MMPythonRuntime *runtime;
    @synchronized(self) {
        if (!runtime) runtime=[[self alloc] init];
        return runtime;
    }
}
- (instancetype)init {
    if ((self=[super init])) [self initializeProcess];
    return self;
}
- (void)initializeProcess {
    if (Py_IsInitialized()) { _failure=@"Another Python runtime is already initialized";return; }
    NSString *bundle=NSBundle.mainBundle.resourcePath;
    for (NSString *relative in @[@"python/lib/python3.14/encodings/__init__.py",@"app/native_source_entry.py",@"app/native_source_host.py"]) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:[bundle stringByAppendingPathComponent:relative]]) {
            _failure=@"Bundled Python runtime is incomplete";return;
        }
    }
    struct sigaction action={},before={},after={};action.sa_handler=SIG_IGN;sigemptyset(&action.sa_mask);
    _signalsBefore=MMSignals();
    if (sigaction(SIGINT,NULL,&before)!=0) { _failure=@"Host signal inspection failed";return; }
    if (sigaction(SIGPIPE,&action,NULL)!=0) { _failure=@"Host signal configuration failed";return; }
    PyPreConfig pre;PyPreConfig_InitIsolatedConfig(&pre);pre.utf8_mode=1;
    PyConfig config;PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode=0;config.buffered_stdio=0;config.install_signal_handlers=0;
    config.site_import=0;config.parse_argv=0;config.use_system_logger=1;
    PyStatus status=Py_PreInitialize(&pre);
    if (PyStatus_Exception(status)) goto failed;
    status=PyConfig_SetBytesString(&config,&config.home,[[bundle stringByAppendingPathComponent:@"python"] UTF8String]);
    if (PyStatus_Exception(status)) goto failed;
    status=PyConfig_SetBytesString(&config,&config.executable,NSBundle.mainBundle.executablePath.UTF8String);
    if (PyStatus_Exception(status)) goto failed;
    for (NSString *relative in @[@"python/lib/python3.14",@"python/lib/python3.14/lib-dynload",@"app_packages",@"app"]) {
        wchar_t *path=Py_DecodeLocale([[bundle stringByAppendingPathComponent:relative] UTF8String],NULL);
        if (!path) { _failure=@"Python module path decoding failed";PyConfig_Clear(&config);return; }
        status=PyWideStringList_Append(&config.module_search_paths,path);PyMem_RawFree(path);
        if (PyStatus_Exception(status)) goto failed;
    }
    config.module_search_paths_set=1;status=Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) goto failed;
    PyConfig_Clear(&config);_version=[NSString stringWithUTF8String:Py_GetVersion()];
    _signalsAfter=MMSignals();
    _preservedInterrupt=sigaction(SIGINT,NULL,&after)==0 && before.sa_handler==after.sa_handler && before.sa_flags==after.sa_flags;
    _interpreter=PyInterpreterState_Get();_mainState=PyEval_SaveThread();return;
failed:
    _failure=status.err_msg?[NSString stringWithUTF8String:status.err_msg]:@"Python initialization failed";
    PyConfig_Clear(&config);
}
@end
