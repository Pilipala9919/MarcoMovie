// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
#import "MMPythonNativeBridge.h"

static NSString * const MMPythonErrorDomain = @"marco_movie.python";

static NSError *MMPythonMakeError(NSInteger code, NSString *errorCode, NSString *message) {
    return [NSError errorWithDomain:MMPythonErrorDomain
                               code:code
                           userInfo:@{
                               NSLocalizedDescriptionKey: message ?: @"Python runtime error",
                               @"code": errorCode ?: @"python_error",
                           }];
}

#if defined(MARCO_HAS_CPYTHON) && MARCO_HAS_CPYTHON

#import <Python/Python.h>
#import <CommonCrypto/CommonDigest.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>

static const NSUInteger MMNativeBodyLimit = 6 * 1024 * 1024;
static const NSUInteger MMNativeHeaderSizeLimit = 32768;
static const NSUInteger MMNativeHeaderCountLimit = 128;
static const NSUInteger MMNativeResultJSONLimit = 9 * 1024 * 1024;

// ============================================================================
// Validation & Conversion Helpers
// ============================================================================

static BOOL MMIsHex32(id value) {
    if (![value isKindOfClass:NSString.class] || [(NSString *)value length] != 32) {
        return NO;
    }
    static NSCharacterSet *nonHex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    });
    return [(NSString *)value rangeOfCharacterFromSet:nonHex].location == NSNotFound;
}

static NSString *MMNormalizeCallId(NSString *rawCallId) {
    if (![rawCallId isKindOfClass:NSString.class] || rawCallId.length == 0) {
        return @"";
    }
    NSString *lower = rawCallId.lowercaseString;
    if (MMIsHex32(lower)) {
        return lower;
    }
    NSString *stripped = [lower stringByReplacingOccurrencesOfString:@"-" withString:@""];
    if (MMIsHex32(stripped)) {
        return stripped;
    }
    NSData *utf8 = [rawCallId dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8) {
        return @"";
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(utf8.bytes, (CC_LONG)utf8.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

static BOOL MMPositiveInteger(id value, NSUInteger maximum) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    double number = [value doubleValue];
    return isfinite(number) && number >= 1.0 && number <= (double)maximum && floor(number) == number;
}

static BOOL MMIsValidHeaderToken(NSString *name) {
    if (![name isKindOfClass:NSString.class] || name.length == 0) {
        return NO;
    }
    static NSCharacterSet *invalidTokenChars = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *allowed = @"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
        invalidTokenChars = [[NSCharacterSet characterSetWithCharactersInString:allowed] invertedSet];
    });
    return [name rangeOfCharacterFromSet:invalidTokenChars].location == NSNotFound;
}

static BOOL MMIsValidHeaderValue(NSString *value) {
    if (![value isKindOfClass:NSString.class]) {
        return NO;
    }
    NSUInteger len = value.length;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [value characterAtIndex:i];
        if (c > 0xFF || c == 0x7F || (c < 0x20 && c != 0x09)) {
            return NO;
        }
    }
    return YES;
}

static NSString *MMSanitizeReasonPhrase(NSInteger statusCode) {
    NSString *raw = [NSHTTPURLResponse localizedStringForStatusCode:statusCode] ?: @"OK";
    NSMutableString *clean = [NSMutableString stringWithCapacity:MIN(raw.length, (NSUInteger)512)];
    for (NSUInteger i = 0; i < raw.length && clean.length < 512; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c >= 0x20 && c <= 0x7E) {
            [clean appendFormat:@"%C", c];
        }
    }
    return clean.length > 0 ? clean : @"OK";
}

static BOOL MMValidateProxyURL(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0 || value.length > 8192) {
        return NO;
    }
    NSURLComponents *url = [NSURLComponents componentsWithString:value];
    if (!url || ![url.scheme isEqualToString:@"http"] || ![url.host isEqualToString:@"127.0.0.1"]) {
        return NO;
    }
    NSInteger port = url.port.integerValue;
    if (port <= 0 || port > 65535 || url.user || url.password || url.fragment) {
        return NO;
    }
    if (![url.path hasPrefix:@"/"]) {
        return NO;
    }
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        if ([part isEqualToString:@"."] || [part isEqualToString:@".."]) {
            return NO;
        }
    }
    NSMutableDictionary<NSString *, NSString *> *query = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in url.queryItems) {
        if (!item.name) continue;
        NSString *lowerKey = item.name.lowercaseString;
        if (query[lowerKey] != nil) {
            return NO;
        }
        query[lowerKey] = item.value ?: @"";
    }
    return [query[@"do"] isEqualToString:@"py"] && query[@"sitekey"].length > 0;
}

static NSString *MMFetchPythonErrorDescription(void) {
    if (!PyErr_Occurred()) {
        return nil;
    }
    PyObject *ptype = NULL;
    PyObject *pvalue = NULL;
    PyObject *ptraceback = NULL;
    PyErr_Fetch(&ptype, &pvalue, &ptraceback);
    PyErr_NormalizeException(&ptype, &pvalue, &ptraceback);
    NSString *description = nil;
    if (pvalue) {
        PyObject *strObj = PyObject_Str(pvalue);
        if (strObj) {
            Py_ssize_t len = 0;
            const char *utf8 = PyUnicode_AsUTF8AndSize(strObj, &len);
            if (utf8 && len > 0) {
                description = [[NSString alloc] initWithBytes:utf8
                                                       length:(NSUInteger)MIN(len, (Py_ssize_t)2048)
                                                     encoding:NSUTF8StringEncoding];
            }
            Py_DECREF(strObj);
        }
    }
    Py_XDECREF(ptype);
    Py_XDECREF(pvalue);
    Py_XDECREF(ptraceback);
    PyErr_Clear();
    return description;
}

static PyObject *MMStringToPy(NSString *value) {
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes) {
        PyErr_SetString(PyExc_ValueError, "Invalid UTF-8 string");
        return NULL;
    }
    const char *ptr = bytes.length > 0 ? (const char *)bytes.bytes : "";
    return PyUnicode_DecodeUTF8(ptr, (Py_ssize_t)bytes.length, "strict");
}

static PyObject *MMJSONObjectToPy(id obj) {
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!bytes || bytes.length > 64 * 1024) {
        PyErr_SetString(PyExc_ValueError, "Invalid JSON payload");
        return NULL;
    }
    PyObject *module = PyImport_ImportModule("json");
    const char *ptr = bytes.length > 0 ? (const char *)bytes.bytes : "";
    PyObject *text = PyUnicode_DecodeUTF8(ptr, (Py_ssize_t)bytes.length, "strict");
    PyObject *value = (module && text) ? PyObject_CallMethod(module, "loads", "O", text) : NULL;
    Py_XDECREF(text);
    Py_XDECREF(module);
    return value;
}

static NSString *MMPyResultToJSONString(PyObject *value) {
    PyObject *module = PyImport_ImportModule("json");
    if (!module) {
        return nil;
    }
    PyObject *dumpsFn = PyObject_GetAttrString(module, "dumps");
    Py_DECREF(module);
    if (!dumpsFn) {
        return nil;
    }
    PyObject *argsTuple = PyTuple_Pack(1, value);
    PyObject *kwargs = PyDict_New();
    PyObject *text = NULL;
    if (argsTuple && kwargs) {
        PyDict_SetItemString(kwargs, "ensure_ascii", Py_False);
        PyDict_SetItemString(kwargs, "allow_nan", Py_False);
        text = PyObject_Call(dumpsFn, argsTuple, kwargs);
    }
    Py_XDECREF(argsTuple);
    Py_XDECREF(kwargs);
    Py_DECREF(dumpsFn);
    if (!text) {
        return nil;
    }
    Py_ssize_t size = 0;
    const char *utf8 = PyUnicode_AsUTF8AndSize(text, &size);
    NSString *result = nil;
    if (utf8 && size >= 0 && (NSUInteger)size <= MMNativeResultJSONLimit) {
        result = [[NSString alloc] initWithBytes:utf8 length:(NSUInteger)size encoding:NSUTF8StringEncoding];
    }
    Py_DECREF(text);
    if (!result && !PyErr_Occurred()) {
        PyErr_SetString(PyExc_ValueError, "Result exceeds source protocol limit");
    }
    return result;
}

static PyObject *MMPackageFilesToPy(NSDictionary<NSString *, NSData *> *files) {
    PyObject *dict = PyDict_New();
    if (!dict) {
        return NULL;
    }
    for (NSString *name in files) {
        PyObject *key = MMStringToPy(name);
        NSData *data = files[name];
        const char *ptr = data.length > 0 ? (const char *)data.bytes : "";
        PyObject *val = PyBytes_FromStringAndSize(ptr, (Py_ssize_t)data.length);
        int status = (key && val) ? PyDict_SetItem(dict, key, val) : -1;
        Py_XDECREF(key);
        Py_XDECREF(val);
        if (status < 0) {
            Py_DECREF(dict);
            return NULL;
        }
    }
    return dict;
}

static BOOL MMIsBundledPythonPresent(void) {
    NSString *bundle = NSBundle.mainBundle.resourcePath;
    if (bundle.length == 0) {
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *relative in @[
        @"python/lib/python3.14/encodings/__init__.py",
        @"app/native_source_entry.py",
        @"app/native_source_host.py",
    ]) {
        if (![fm fileExistsAtPath:[bundle stringByAppendingPathComponent:relative]]) {
            return NO;
        }
    }
    return YES;
}

static NSUInteger MMRecommendedMaxSessions(void) {
    const unsigned long long fourGigabytesFloor = 3800ULL * 1024ULL * 1024ULL;
    return NSProcessInfo.processInfo.physicalMemory >= fourGigabytesFloor ? 4 : 2;
}

// ============================================================================
// Process-Lifetime CPython Runtime
// ============================================================================

@interface MMPythonNativeRuntime : NSObject
@property (nonatomic, readonly) PyThreadState *mainState;
@property (nonatomic, readonly) PyInterpreterState *interpreter;
@property (nonatomic, readonly, copy, nullable) NSString *version;
@property (nonatomic, readonly, copy, nullable) NSString *failure;
+ (instancetype)sharedRuntime;
@end

@implementation MMPythonNativeRuntime

+ (instancetype)sharedRuntime {
    NSAssert(!NSThread.isMainThread, @"Python initialization must not block the UI thread");
    static MMPythonNativeRuntime *runtime = nil;
    @synchronized(self) {
        if (!runtime) {
            runtime = [[self alloc] init];
        }
        return runtime;
    }
}

- (instancetype)init {
    if ((self = [super init])) {
        [self initializeProcess];
    }
    return self;
}

- (void)initializeProcess {
    if (Py_IsInitialized()) {
        _failure = @"Another Python runtime is already initialized";
        return;
    }
    NSString *bundle = NSBundle.mainBundle.resourcePath;
    if (!MMIsBundledPythonPresent()) {
        _failure = @"Bundled Python runtime is incomplete";
        return;
    }

    struct sigaction action = {};
    action.sa_handler = SIG_IGN;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGPIPE, &action, NULL) != 0) {
        _failure = @"Host signal configuration failed";
        return;
    }

    PyPreConfig pre;
    PyPreConfig_InitIsolatedConfig(&pre);
    pre.utf8_mode = 1;

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;
    config.buffered_stdio = 0;
    config.install_signal_handlers = 0;
    config.site_import = 0;
    config.parse_argv = 0;
    config.use_system_logger = 1;

    PyStatus status = Py_PreInitialize(&pre);
    if (PyStatus_Exception(status)) {
        goto failed;
    }

    status = PyConfig_SetBytesString(
        &config,
        &config.home,
        [[bundle stringByAppendingPathComponent:@"python"] UTF8String]
    );
    if (PyStatus_Exception(status)) {
        goto failed;
    }

    status = PyConfig_SetBytesString(
        &config,
        &config.executable,
        NSBundle.mainBundle.executablePath.UTF8String
    );
    if (PyStatus_Exception(status)) {
        goto failed;
    }

    for (NSString *relative in @[
        @"python/lib/python3.14",
        @"python/lib/python3.14/lib-dynload",
        @"app_packages",
        @"app",
    ]) {
        wchar_t *path = Py_DecodeLocale(
            [[bundle stringByAppendingPathComponent:relative] UTF8String],
            NULL
        );
        if (!path) {
            _failure = @"Python module path decoding failed";
            PyConfig_Clear(&config);
            return;
        }
        status = PyWideStringList_Append(&config.module_search_paths, path);
        PyMem_RawFree(path);
        if (PyStatus_Exception(status)) {
            goto failed;
        }
    }

    config.module_search_paths_set = 1;
    status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) {
        goto failed;
    }

    PyConfig_Clear(&config);
    _version = [NSString stringWithUTF8String:Py_GetVersion()];
    _interpreter = PyInterpreterState_Get();
    _mainState = PyEval_SaveThread();
    return;

failed:
    _failure = status.err_msg
        ? [NSString stringWithUTF8String:status.err_msg]
        : @"Python initialization failed";
    PyConfig_Clear(&config);
}

@end

// ============================================================================
// Native Ephemeral URLSession HTTP Transport (Zero Flutter)
// ============================================================================

@interface MMNativeTransportPending : NSObject
@property (nonatomic, copy) NSString *callId;
@property (nonatomic, copy) NSString *requestId;
@property (nonatomic, copy) NSString *requestURL;
@property (nonatomic, copy) NSString *httpMethod;
@property (nonatomic, strong) dispatch_semaphore_t signal;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *task;
@property (nonatomic, strong, nullable) NSHTTPURLResponse *httpResponse;
@property (nonatomic, strong) NSMutableData *receivedData;
@property (nonatomic, assign) BOOL bodyLimitExceeded;
@property (nonatomic, strong, nullable) NSDictionary *responseEnvelope;
@property (nonatomic, copy, nullable) NSString *errorKind;
@property (nonatomic, assign) BOOL settled;
@end

@implementation MMNativeTransportPending
@end

@interface MMPythonNativeTransport : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSOperationQueue *delegateQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, MMNativeTransportPending *> *pendingByRequestId;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, MMNativeTransportPending *> *pendingByTaskId;
@property (nonatomic, strong) NSMutableSet<NSString *> *cancelledCalls;
@property (nonatomic, copy, nullable) NSString *activeCall;
@property (nonatomic, assign) double deadline;
@property (nonatomic, assign) BOOL invalidated;

- (BOOL)beginCall:(NSString *)callId budgetMs:(NSUInteger)budgetMs;
- (void)endCall;
- (NSUInteger)cancelCall:(NSString *)callId;
- (void)invalidate;
- (nullable MMNativeTransportPending *)performRequest:(NSDictionary *)envelope error:(NSString * _Nullable *)error;
- (nullable NSDictionary *)claimResponse:(MMNativeTransportPending *)pending error:(NSString * _Nullable *)error;
@end

static NSString *MMMapURLErrorToKind(NSError *error) {
    if (!error) {
        return @"protocol";
    }
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorCancelled:
                return @"cancelled";
            case NSURLErrorTimedOut:
                return @"timeout";
            case NSURLErrorSecureConnectionFailed:
            case NSURLErrorServerCertificateHasBadDate:
            case NSURLErrorServerCertificateUntrusted:
            case NSURLErrorServerCertificateHasUnknownRoot:
            case NSURLErrorServerCertificateNotYetValid:
            case NSURLErrorClientCertificateRejected:
            case NSURLErrorClientCertificateRequired:
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return @"tls";
            default:
                return @"connection";
        }
    }
    return @"connection";
}

@implementation MMPythonNativeTransport

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _pendingByRequestId = [NSMutableDictionary dictionary];
        _pendingByTaskId = [NSMutableDictionary dictionary];
        _cancelledCalls = [NSMutableSet set];

        _delegateQueue = [NSOperationQueue new];
        _delegateQueue.name = @"marco.python.native.transport";
        _delegateQueue.maxConcurrentOperationCount = 4;

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.HTTPCookieStorage = nil;
        cfg.HTTPShouldSetCookies = NO;
        cfg.URLCache = nil;
        cfg.URLCredentialStorage = nil;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.waitsForConnectivity = NO;
        cfg.HTTPMaximumConnectionsPerHost = 4;

        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:_delegateQueue];
    }
    return self;
}

- (void)invalidate {
    [self endCall];
    [self.lock lock];
    BOOL wasInvalidated = self.invalidated;
    self.invalidated = YES;
    NSURLSession *session = self.session;
    self.session = nil;
    [self.lock unlock];
    if (!wasInvalidated && session) {
        [session invalidateAndCancel];
    }
}

- (BOOL)beginCall:(NSString *)callId budgetMs:(NSUInteger)budgetMs {
    if (!MMIsHex32(callId) || budgetMs < 1 || budgetMs > 45000) {
        return NO;
    }
    [self.lock lock];
    BOOL available = !self.invalidated && self.activeCall == nil &&
        self.pendingByRequestId.count == 0 && ![self.cancelledCalls containsObject:callId];
    if (available) {
        self.activeCall = [callId copy];
        self.deadline = NSProcessInfo.processInfo.systemUptime + (double)budgetMs / 1000.0;
        [self.cancelledCalls removeAllObjects];
    }
    [self.lock unlock];
    return available;
}

- (BOOL)settlePending:(MMNativeTransportPending *)pending
             response:(nullable NSDictionary *)response
            errorKind:(nullable NSString *)errorKind {
    [self.lock lock];
    BOOL owned = self.pendingByRequestId[pending.requestId] == pending && !pending.settled;
    if (owned) {
        pending.responseEnvelope = response;
        pending.errorKind = errorKind;
        pending.settled = YES;
        if (pending.task) {
            [self.pendingByTaskId removeObjectForKey:@(pending.task.taskIdentifier)];
        }
    }
    [self.lock unlock];
    if (owned) {
        dispatch_semaphore_signal(pending.signal);
    }
    return owned;
}

- (NSUInteger)cancelCall:(NSString *)callId {
    [self.lock lock];
    if (MMIsHex32(callId) && self.cancelledCalls.count < 64) {
        [self.cancelledCalls addObject:callId];
    }
    NSArray<MMNativeTransportPending *> *values = self.pendingByRequestId.allValues;
    NSMutableArray<MMNativeTransportPending *> *toWake = [NSMutableArray array];
    NSMutableArray<NSURLSessionDataTask *> *tasksToCancel = [NSMutableArray array];
    NSUInteger count = 0;
    for (MMNativeTransportPending *pending in values) {
        if (![pending.callId isEqualToString:callId]) {
            continue;
        }
        count++;
        pending.errorKind = @"cancelled";
        pending.responseEnvelope = nil;
        if (pending.task) {
            [tasksToCancel addObject:pending.task];
            [self.pendingByTaskId removeObjectForKey:@(pending.task.taskIdentifier)];
        }
        if (!pending.settled) {
            pending.settled = YES;
            [toWake addObject:pending];
        }
    }
    [self.lock unlock];

    for (NSURLSessionDataTask *task in tasksToCancel) {
        [task cancel];
    }
    for (MMNativeTransportPending *pending in toWake) {
        dispatch_semaphore_signal(pending.signal);
    }
    return count;
}

- (void)endCall {
    [self.lock lock];
    NSArray<MMNativeTransportPending *> *values = self.pendingByRequestId.allValues;
    self.activeCall = nil;
    NSMutableArray<MMNativeTransportPending *> *toWake = [NSMutableArray array];
    NSMutableArray<NSURLSessionDataTask *> *tasksToCancel = [NSMutableArray array];
    for (MMNativeTransportPending *pending in values) {
        pending.errorKind = @"cancelled";
        pending.responseEnvelope = nil;
        if (pending.task) {
            [tasksToCancel addObject:pending.task];
        }
        if (!pending.settled) {
            pending.settled = YES;
            [toWake addObject:pending];
        }
    }
    [self.pendingByRequestId removeAllObjects];
    [self.pendingByTaskId removeAllObjects];
    [self.cancelledCalls removeAllObjects];
    [self.lock unlock];

    for (NSURLSessionDataTask *task in tasksToCancel) {
        [task cancel];
    }
    for (MMNativeTransportPending *pending in toWake) {
        dispatch_semaphore_signal(pending.signal);
    }
}

- (nullable MMNativeTransportPending *)performRequest:(NSDictionary *)envelope error:(NSString * _Nullable *)error {
    if (NSThread.isMainThread) {
        *error = @"protocol";
        return nil;
    }
    static NSSet<NSString *> *requiredKeys = nil;
    static NSSet<NSString *> *allowedMethods = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        requiredKeys = [NSSet setWithArray:@[
            @"version", @"callId", @"requestId", @"url", @"method",
            @"headers", @"body", @"connectTimeoutMs", @"readTimeoutMs", @"deadlineRemainingMs",
        ]];
        allowedMethods = [NSSet setWithArray:@[
            @"GET", @"HEAD", @"POST", @"PUT", @"PATCH", @"DELETE", @"OPTIONS",
        ]];
    });

    if (![envelope isKindOfClass:NSDictionary.class] ||
        ![[NSSet setWithArray:envelope.allKeys] isEqualToSet:requiredKeys] ||
        !MMPositiveInteger(envelope[@"version"], 1) ||
        !MMIsHex32(envelope[@"callId"]) ||
        !MMIsHex32(envelope[@"requestId"]) ||
        !MMPositiveInteger(envelope[@"connectTimeoutMs"], 45000) ||
        !MMPositiveInteger(envelope[@"readTimeoutMs"], 45000) ||
        !MMPositiveInteger(envelope[@"deadlineRemainingMs"], 45000) ||
        ![envelope[@"body"] isKindOfClass:NSData.class] ||
        [(NSData *)envelope[@"body"] length] > MMNativeBodyLimit ||
        ![envelope[@"headers"] isKindOfClass:NSArray.class] ||
        [(NSArray *)envelope[@"headers"] count] > MMNativeHeaderCountLimit ||
        ![allowedMethods containsObject:envelope[@"method"]]) {
        *error = @"protocol";
        return nil;
    }

    NSString *address = [envelope[@"url"] isKindOfClass:NSString.class] ? envelope[@"url"] : nil;
    NSURLComponents *components = address ? [NSURLComponents componentsWithString:address] : nil;
    if (!components ||
        !([components.scheme.lowercaseString isEqualToString:@"http"] ||
          [components.scheme.lowercaseString isEqualToString:@"https"]) ||
        components.host.length == 0 ||
        components.user != nil ||
        components.password != nil ||
        components.fragment != nil) {
        *error = @"protocol";
        return nil;
    }
    for (NSString *part in [components.path componentsSeparatedByString:@"/"]) {
        if ([part isEqualToString:@"."] ||
            [part isEqualToString:@".."] ||
            [part containsString:@"\\"] ||
            [part rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
            *error = @"protocol";
            return nil;
        }
    }

    NSURL *url = [NSURL URLWithString:address];
    if (!url) {
        *error = @"protocol";
        return nil;
    }

    [self.lock lock];
    BOOL allowed = !self.invalidated && self.session != nil && [self.activeCall isEqualToString:envelope[@"callId"]];
    double remainingMs = (self.deadline - NSProcessInfo.processInfo.systemUptime) * 1000.0;
    BOOL cancelled = [self.cancelledCalls containsObject:envelope[@"callId"]];
    if (!allowed || cancelled || remainingMs <= 0.0 ||
        self.pendingByRequestId.count >= 4 ||
        self.pendingByRequestId[envelope[@"requestId"]] != nil) {
        [self.lock unlock];
        *error = cancelled ? @"cancelled" : (!allowed ? @"protocol" : (remainingMs <= 0.0 ? @"timeout" : @"protocol"));
        return nil;
    }

    NSUInteger envelopeDeadlineMs = [envelope[@"deadlineRemainingMs"] unsignedIntegerValue];
    NSUInteger readTimeoutMs = [envelope[@"readTimeoutMs"] unsignedIntegerValue];
    NSUInteger effectiveBudgetMs = MIN(envelopeDeadlineMs, (NSUInteger)MAX(1.0, remainingMs));
    NSUInteger effectiveTimeoutMs = MIN(effectiveBudgetMs, readTimeoutMs);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = envelope[@"method"];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.HTTPShouldHandleCookies = NO;
    request.timeoutInterval = MAX(0.1, (double)effectiveTimeoutMs / 1000.0);

    NSData *bodyData = envelope[@"body"];
    if (bodyData.length > 0) {
        request.HTTPBody = bodyData;
    }

    BOOL sawAcceptEncoding = NO;
    for (id pair in (NSArray *)envelope[@"headers"]) {
        if (![pair isKindOfClass:NSArray.class] || [(NSArray *)pair count] != 2) {
            [self.lock unlock];
            *error = @"protocol";
            return nil;
        }
        id rawName = pair[0];
        id rawVal = pair[1];
        if (![rawName isKindOfClass:NSString.class] || ![rawVal isKindOfClass:NSString.class]) {
            [self.lock unlock];
            *error = @"protocol";
            return nil;
        }
        NSString *name = rawName;
        NSString *val = rawVal;
        if ([name.lowercaseString isEqualToString:@"accept-encoding"]) {
            // Force identity so URLSession never mismatches Content-Encoding vs decoded body bytes.
            sawAcceptEncoding = YES;
            [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
            continue;
        }
        [request setValue:val forHTTPHeaderField:name];
    }
    if (!sawAcceptEncoding) {
        [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    }

    MMNativeTransportPending *pending = [MMNativeTransportPending new];
    pending.callId = envelope[@"callId"];
    pending.requestId = envelope[@"requestId"];
    pending.requestURL = address;
    pending.httpMethod = envelope[@"method"];
    pending.signal = dispatch_semaphore_create(0);
    pending.receivedData = [NSMutableData data];

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request];
    pending.task = task;
    self.pendingByRequestId[pending.requestId] = pending;
    self.pendingByTaskId[@(task.taskIdentifier)] = pending;
    [self.lock unlock];

    [task resume];

    int64_t waitNs = (int64_t)effectiveBudgetMs * (int64_t)NSEC_PER_MSEC;
    if (dispatch_semaphore_wait(pending.signal, dispatch_time(DISPATCH_TIME_NOW, waitNs)) != 0) {
        [self settlePending:pending response:nil errorKind:@"timeout"];
        [task cancel];
    }
    return pending;
}

- (nullable NSDictionary *)claimResponse:(MMNativeTransportPending *)pending error:(NSString * _Nullable *)error {
    [self.lock lock];
    if (self.pendingByRequestId[pending.requestId] != pending || !pending.settled) {
        [self.lock unlock];
        *error = @"protocol";
        return nil;
    }
    if ([self.cancelledCalls containsObject:pending.callId]) {
        pending.errorKind = @"cancelled";
        pending.responseEnvelope = nil;
    }
    [self.pendingByRequestId removeObjectForKey:pending.requestId];
    if (pending.task) {
        [self.pendingByTaskId removeObjectForKey:@(pending.task.taskIdentifier)];
    }
    NSDictionary *response = pending.responseEnvelope;
    *error = pending.errorKind;
    [self.lock unlock];
    return response;
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    // Enforce followRedirects = false so Python's BridgeSession handles redirects & cookie isolation.
    (void)session;
    (void)task;
    (void)response;
    (void)request;
    completionHandler(nil);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;
    [self.lock lock];
    MMNativeTransportPending *pending = self.pendingByTaskId[@(dataTask.taskIdentifier)];
    [self.lock unlock];
    if (!pending || pending.settled) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    if (![response isKindOfClass:NSHTTPURLResponse.class]) {
        [self settlePending:pending response:nil errorKind:@"protocol"];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
    if (httpResp.expectedContentLength > (long long)MMNativeBodyLimit) {
        pending.bodyLimitExceeded = YES;
        [self settlePending:pending response:nil errorKind:@"protocol"];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    pending.httpResponse = httpResp;
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    [self.lock lock];
    MMNativeTransportPending *pending = self.pendingByTaskId[@(dataTask.taskIdentifier)];
    [self.lock unlock];
    if (!pending || pending.settled) {
        [dataTask cancel];
        return;
    }
    if (pending.receivedData.length + data.length > MMNativeBodyLimit) {
        pending.bodyLimitExceeded = YES;
        [self settlePending:pending response:nil errorKind:@"protocol"];
        [dataTask cancel];
        return;
    }
    [pending.receivedData appendData:data];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(nullable NSError *)error {
    (void)session;
    [self.lock lock];
    MMNativeTransportPending *pending = self.pendingByTaskId[@(task.taskIdentifier)];
    [self.lock unlock];
    if (!pending || pending.settled) {
        return;
    }
    if (pending.bodyLimitExceeded) {
        [self settlePending:pending response:nil errorKind:@"protocol"];
        return;
    }
    if (error) {
        [self settlePending:pending response:nil errorKind:MMMapURLErrorToKind(error)];
        return;
    }
    NSHTTPURLResponse *httpResp = pending.httpResponse;
    if (!httpResp && [task.response isKindOfClass:NSHTTPURLResponse.class]) {
        httpResp = (NSHTTPURLResponse *)task.response;
    }
    if (!httpResp) {
        [self settlePending:pending response:nil errorKind:@"protocol"];
        return;
    }
    NSInteger status = httpResp.statusCode;
    if (status < 200 || status > 599) {
        [self settlePending:pending response:nil errorKind:@"protocol"];
        return;
    }

    BOOL forbidBody = [pending.httpMethod isEqualToString:@"HEAD"] || status == 204 || status == 304;
    NSData *body = forbidBody ? [NSData data] : [NSData dataWithData:pending.receivedData];

    NSMutableArray<NSArray<NSString *> *> *headers = [NSMutableArray array];
    NSMutableSet<NSString *> *seenSingletons = [NSMutableSet set];
    NSSet<NSString *> *singletonNames = [NSSet setWithArray:@[
        @"content-length", @"location", @"content-encoding", @"transfer-encoding",
    ]];
    NSUInteger headerBytes = 0;

    NSDictionary *rawFields = httpResp.allHeaderFields;
    for (id rawKey in rawFields) {
        if (headers.count >= MMNativeHeaderCountLimit) {
            break;
        }
        NSString *keyStr = [[NSString stringWithFormat:@"%@", rawKey] lowercaseString];
        NSString *valStr = [NSString stringWithFormat:@"%@", rawFields[rawKey]];
        // Strip framing/compression headers because URLSession already dechunked & decoded body bytes.
        if ([keyStr isEqualToString:@"content-encoding"] ||
            [keyStr isEqualToString:@"transfer-encoding"] ||
            (!forbidBody && [keyStr isEqualToString:@"content-length"])) {
            continue;
        }
        if (!MMIsValidHeaderToken(keyStr) || !MMIsValidHeaderValue(valStr)) {
            continue;
        }
        if ([singletonNames containsObject:keyStr]) {
            if ([seenSingletons containsObject:keyStr]) {
                continue;
            }
            [seenSingletons addObject:keyStr];
        }
        NSUInteger entrySize = keyStr.length + valStr.length + 4;
        if (headerBytes + entrySize > MMNativeHeaderSizeLimit) {
            break;
        }
        headerBytes += entrySize;
        [headers addObject:@[keyStr, valStr]];
    }

    NSDictionary *envelope = @{
        @"version": @1,
        @"callId": pending.callId,
        @"requestId": pending.requestId,
        @"url": pending.requestURL,
        @"status": @(status),
        @"reason": MMSanitizeReasonPhrase(status),
        @"headers": headers,
        @"body": body,
    };
    [self settlePending:pending response:envelope errorKind:nil];
}

@end

// ============================================================================
// Python <-> ObjC Transport Capsule
// ============================================================================

static id MMFromPython(PyObject *value, NSUInteger depth) {
    if (depth > 8) {
        PyErr_SetString(PyExc_ValueError, "Python request nesting exceeds limit");
        return nil;
    }
    if (value == Py_None) return NSNull.null;
    if (PyBool_Check(value)) return value == Py_True ? @YES : @NO;
    if (PyLong_Check(value)) {
        long long number = PyLong_AsLongLong(value);
        return PyErr_Occurred() ? nil : @(number);
    }
    if (PyUnicode_Check(value)) {
        Py_ssize_t length = 0;
        const char *text = PyUnicode_AsUTF8AndSize(value, &length);
        if (!text) return nil;
        if (length > 65536) {
            PyErr_SetString(PyExc_ValueError, "Python request string exceeds limit");
            return nil;
        }
        return [[NSString alloc] initWithBytes:text length:(NSUInteger)length encoding:NSUTF8StringEncoding];
    }
    if (PyBytes_Check(value)) {
        char *bytes = NULL;
        Py_ssize_t length = 0;
        if (PyBytes_AsStringAndSize(value, &bytes, &length) < 0) return nil;
        if ((NSUInteger)length > MMNativeBodyLimit) {
            PyErr_SetString(PyExc_ValueError, "Python body exceeds limit");
            return nil;
        }
        return [NSData dataWithBytes:bytes length:(NSUInteger)length];
    }
    if (PyList_Check(value) || PyTuple_Check(value)) {
        Py_ssize_t count = PySequence_Size(value);
        if (count > 256) {
            PyErr_SetString(PyExc_ValueError, "Python list exceeds limit");
            return nil;
        }
        NSMutableArray *array = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
        for (Py_ssize_t i = 0; i < count; i++) {
            PyObject *item = PySequence_GetItem(value, i);
            id converted = item ? MMFromPython(item, depth + 1) : nil;
            Py_XDECREF(item);
            if (!converted) return nil;
            [array addObject:converted];
        }
        return array;
    }
    if (PyDict_Check(value)) {
        if (PyDict_Size(value) > 128) {
            PyErr_SetString(PyExc_ValueError, "Python dict exceeds limit");
            return nil;
        }
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        Py_ssize_t pos = 0;
        PyObject *key = NULL;
        PyObject *item = NULL;
        while (PyDict_Next(value, &pos, &key, &item)) {
            if (!PyUnicode_Check(key)) {
                PyErr_SetString(PyExc_TypeError, "Python keys must be strings");
                return nil;
            }
            id name = MMFromPython(key, depth + 1);
            id converted = MMFromPython(item, depth + 1);
            if (!name || !converted) return nil;
            dict[name] = converted;
        }
        return dict;
    }
    PyErr_SetString(PyExc_TypeError, "Unsupported source request value");
    return nil;
}

static PyObject *MMToPython(id value, NSUInteger depth) {
    if (depth > 8) {
        PyErr_SetString(PyExc_ValueError, "Python response nesting exceeds limit");
        return NULL;
    }
    if (!value || value == NSNull.null) return Py_NewRef(Py_None);
    if ([value isKindOfClass:NSData.class]) {
        NSData *data = (NSData *)value;
        if (data.length > MMNativeBodyLimit) {
            PyErr_SetString(PyExc_ValueError, "Python response body exceeds limit");
            return NULL;
        }
        const char *ptr = data.length > 0 ? (const char *)data.bytes : "";
        return PyBytes_FromStringAndSize(ptr, (Py_ssize_t)data.length);
    }
    if ([value isKindOfClass:NSString.class]) {
        NSData *data = [(NSString *)value dataUsingEncoding:NSUTF8StringEncoding];
        if (!data || data.length > 65536) {
            PyErr_SetString(PyExc_ValueError, "Python response string exceeds limit");
            return NULL;
        }
        const char *ptr = data.length > 0 ? (const char *)data.bytes : "";
        return PyUnicode_DecodeUTF8(ptr, (Py_ssize_t)data.length, "strict");
    }
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
            return PyBool_FromLong([(NSNumber *)value boolValue]);
        }
        double number = [(NSNumber *)value doubleValue];
        if (!isfinite(number) || floor(number) != number) {
            PyErr_SetString(PyExc_ValueError, "Python response number must be integer");
            return NULL;
        }
        return PyLong_FromLongLong([(NSNumber *)value longLongValue]);
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSArray *array = (NSArray *)value;
        if (array.count > 256) {
            PyErr_SetString(PyExc_ValueError, "Python response list exceeds limit");
            return NULL;
        }
        PyObject *list = PyList_New((Py_ssize_t)array.count);
        if (!list) return NULL;
        for (NSUInteger i = 0; i < array.count; i++) {
            PyObject *item = MMToPython(array[i], depth + 1);
            if (!item) {
                Py_DECREF(list);
                return NULL;
            }
            PyList_SET_ITEM(list, (Py_ssize_t)i, item);
        }
        return list;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictObj = (NSDictionary *)value;
        if (dictObj.count > 128) {
            PyErr_SetString(PyExc_ValueError, "Python response dict exceeds limit");
            return NULL;
        }
        PyObject *dict = PyDict_New();
        if (!dict) return NULL;
        for (id key in dictObj) {
            if (![key isKindOfClass:NSString.class]) {
                PyErr_SetString(PyExc_TypeError, "Python response keys must be strings");
                Py_DECREF(dict);
                return NULL;
            }
            PyObject *name = MMToPython(key, depth + 1);
            PyObject *item = MMToPython(dictObj[key], depth + 1);
            int status = (name && item) ? PyDict_SetItem(dict, name, item) : -1;
            Py_XDECREF(name);
            Py_XDECREF(item);
            if (status < 0) {
                Py_DECREF(dict);
                return NULL;
            }
        }
        return dict;
    }
    PyErr_SetString(PyExc_TypeError, "Unsupported source response value");
    return NULL;
}

static PyObject *MMRaiseTransportError(NSString *kind) {
    PyObject *module = PyImport_ImportModule("requests_adapter");
    const char *excName = [kind isEqualToString:@"protocol"] ? "BridgeProtocolError" : "BridgeTransportError";
    PyObject *type = module ? PyObject_GetAttrString(module, excName) : NULL;
    PyObject *errObj = type ? PyObject_CallFunction(type, "s", [kind UTF8String]) : NULL;
    if (errObj) {
        PyErr_SetObject(type, errObj);
    } else if (!PyErr_Occurred()) {
        PyErr_SetString(PyExc_RuntimeError, [kind UTF8String]);
    }
    Py_XDECREF(errObj);
    Py_XDECREF(type);
    Py_XDECREF(module);
    return NULL;
}

static PyObject *MMNativeTransportCall(PyObject *capsule, PyObject *args) {
    if (!PyTuple_Check(args) || PyTuple_Size(args) != 2) {
        PyErr_SetString(PyExc_TypeError, "Python bridge requires envelope and call context");
        return NULL;
    }
    void *pointer = PyCapsule_GetPointer(capsule, "marco.source.transport");
    if (!pointer) {
        return NULL;
    }
    MMPythonNativeTransport *transport = (__bridge MMPythonNativeTransport *)pointer;
    @autoreleasepool {
        id envelope = MMFromPython(PyTuple_GET_ITEM(args, 0), 0);
        if (!envelope) {
            return NULL;
        }
        if (![envelope isKindOfClass:NSDictionary.class]) {
            PyErr_SetString(PyExc_TypeError, "Python envelope must be a dict");
            return NULL;
        }
        NSString *error = nil;
        NSDictionary *response = nil;
        MMNativeTransportPending *pending = nil;
        // Release the subinterpreter GIL across the blocking URLSession semaphore wait.
        PyThreadState *savedState = PyEval_SaveThread();
        @try {
            pending = [transport performRequest:envelope error:&error];
        } @catch (NSException *exception) {
            (void)exception;
            error = @"protocol";
        } @finally {
            PyEval_RestoreThread(savedState);
        }
        if (pending) {
            response = [transport claimResponse:pending error:&error];
        }
        if ([error isEqualToString:@"cancelled"]) {
            PyObject *cancelled = PyObject_CallMethod(PyTuple_GET_ITEM(args, 1), "cancel", NULL);
            if (!cancelled) {
                return NULL;
            }
            Py_DECREF(cancelled);
        }
        if (error) {
            return MMRaiseTransportError(error);
        }
        if (!response) {
            return MMRaiseTransportError(@"protocol");
        }
        return MMToPython(response, 0);
    }
}

static void MMNativeTransportCapsuleDestroy(PyObject *capsule) {
    void *pointer = PyCapsule_GetPointer(capsule, "marco.source.transport");
    if (pointer) {
        id released = CFBridgingRelease(pointer);
        (void)released;
    } else {
        PyErr_Clear();
    }
}

static PyObject *MMCreatePythonNativeTransportBridge(MMPythonNativeTransport *transport) {
    static PyMethodDef method = {
        "source_transport",
        MMNativeTransportCall,
        METH_VARARGS,
        "Owned ephemeral URLSession HTTP transport bridge"
    };
    void *retained = (__bridge_retained void *)transport;
    PyObject *capsule = PyCapsule_New(retained, "marco.source.transport", MMNativeTransportCapsuleDestroy);
    if (!capsule) {
        id released = CFBridgingRelease(retained);
        (void)released;
        return NULL;
    }
    PyObject *callable = PyCFunction_NewEx(&method, capsule, NULL);
    Py_DECREF(capsule);
    return callable;
}

// ============================================================================
// Dedicated Per-Session Subinterpreter Owner (Own-GIL, 8 MiB Thread)
// ============================================================================

typedef PyObject * _Nullable (^MMNativePyCreate)(NSString * _Nullable * _Nullable detailOut);
typedef NSString * _Nullable (^MMNativePyInvoke)(PyObject *source,
                                                 NSDictionary *payload,
                                                 NSUInteger remainingBudgetMs,
                                                 NSString * _Nullable * _Nullable detailOut);
typedef void (^MMNativePyDispose)(PyObject *source);
typedef void (^MMNativePyReply)(id _Nullable value, NSString * _Nullable errorCode, NSString * _Nullable detail);

@interface MMNativeOwnedCall : NSObject
@property (nonatomic, copy) NSString *identity;
@property (nonatomic, copy) NSDictionary *payload;
@property (nonatomic, copy) MMNativePyReply reply;
@property (nonatomic, assign) double deadline;
@property (nonatomic, assign) BOOL cancelled;
@end

@implementation MMNativeOwnedCall
@end

@interface MMPythonNativeOwner : NSObject
@property (nonatomic, assign) PyInterpreterState *mainInterpreter;
@property (nonatomic, copy, nullable) MMNativePyCreate createBlock;
@property (nonatomic, copy, nullable) MMNativePyInvoke invokeBlock;
@property (nonatomic, copy, nullable) MMNativePyDispose disposeBlock;
@property (nonatomic, copy) void (^interruptBlock)(NSString *callId);
@property (nonatomic, strong) NSCondition *condition;
@property (nonatomic, strong) NSMutableArray<MMNativeOwnedCall *> *queue;
@property (nonatomic, strong) NSMutableArray<MMNativePyReply> *closeReplies;
@property (nonatomic, strong, nullable) MMNativeOwnedCall *running;
@property (nonatomic, strong, nullable) NSThread *worker;
@property (nonatomic, copy, nullable) MMNativePyReply openingReply;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL ready;
@property (nonatomic, assign) BOOL closing;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) uint64_t workerIdentity;
@property (nonatomic, assign) int64_t interpreterIdentity;

- (instancetype)initWithMainInterpreter:(PyInterpreterState *)mainInterpreter
                                 create:(MMNativePyCreate)create
                                 invoke:(MMNativePyInvoke)invoke
                                dispose:(MMNativePyDispose)dispose
                              interrupt:(void (^)(NSString *callId))interrupt;
- (void)start:(MMNativePyReply)reply;
- (void)invoke:(NSString *)callId payload:(NSDictionary *)payload budgetMs:(NSUInteger)budgetMs reply:(MMNativePyReply)reply;
- (NSString *)cancel:(NSString *)callId;
- (void)close:(MMNativePyReply)reply;
- (BOOL)isFinished;
@end

static void MMDispatchReply(MMNativePyReply reply, id _Nullable value, NSString * _Nullable errorCode, NSString * _Nullable detail) {
    if (!reply) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        reply(value, errorCode, detail);
    });
}

@implementation MMPythonNativeOwner

- (instancetype)initWithMainInterpreter:(PyInterpreterState *)mainInterpreter
                                 create:(MMNativePyCreate)create
                                 invoke:(MMNativePyInvoke)invoke
                                dispose:(MMNativePyDispose)dispose
                              interrupt:(void (^)(NSString *callId))interrupt {
    if ((self = [super init])) {
        _mainInterpreter = mainInterpreter;
        _createBlock = [create copy];
        _invokeBlock = [invoke copy];
        _disposeBlock = [dispose copy];
        _interruptBlock = [interrupt copy];
        _condition = [NSCondition new];
        _queue = [NSMutableArray array];
        _closeReplies = [NSMutableArray array];
        _interpreterIdentity = -1;
    }
    return self;
}

- (BOOL)isFinished {
    [self.condition lock];
    BOOL done = self.finished;
    [self.condition unlock];
    return done;
}

- (void)start:(MMNativePyReply)reply {
    [self.condition lock];
    if (self.started || self.finished || self.closing || !self.mainInterpreter) {
        [self.condition unlock];
        MMDispatchReply(reply, nil, @"runtime_unavailable", @"Python owner cannot start");
        return;
    }
    self.started = YES;
    self.openingReply = [reply copy];
    self.worker = [[NSThread alloc] initWithTarget:self selector:@selector(workerMain) object:nil];
    self.worker.name = @"native-python-source-owner";
    self.worker.stackSize = 8 * 1024 * 1024;
    [self.worker start];
    [self.condition unlock];
}

- (void)invoke:(NSString *)callId payload:(NSDictionary *)payload budgetMs:(NSUInteger)budgetMs reply:(MMNativePyReply)reply {
    if (!MMIsHex32(callId) || budgetMs < 1 || budgetMs > 45000 || ![payload isKindOfClass:NSDictionary.class]) {
        MMDispatchReply(reply, nil, @"invalid_request", @"Invalid call parameters");
        return;
    }
    NSData *data = nil;
    NSDictionary *copy = nil;
    @try {
        data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (data && data.length <= 64 * 1024) {
            copy = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        }
    } @catch (NSException *exception) {
        (void)exception;
    }
    if (!copy) {
        MMDispatchReply(reply, nil, @"invalid_request", @"Call payload exceeds 64 KiB or is not valid JSON");
        return;
    }

    MMNativeOwnedCall *call = [MMNativeOwnedCall new];
    call.identity = callId;
    call.payload = copy;
    call.reply = reply;
    call.deadline = NSProcessInfo.processInfo.systemUptime + (double)budgetMs / 1000.0;

    [self.condition lock];
    NSString *errorCode = nil;
    if (!self.ready || self.closing || self.finished) {
        errorCode = @"invalid_handle";
    } else if (self.queue.count + (self.running ? 1 : 0) >= 4) {
        errorCode = @"runtime_limit";
    } else {
        if ([self.running.identity isEqualToString:callId]) {
            errorCode = @"invalid_request";
        }
        for (MMNativeOwnedCall *pending in self.queue) {
            if ([pending.identity isEqualToString:callId]) {
                errorCode = @"invalid_request";
                break;
            }
        }
    }
    if (!errorCode) {
        [self.queue addObject:call];
        [self.condition signal];
    }
    [self.condition unlock];

    if (errorCode) {
        MMDispatchReply(reply, nil, errorCode, @"Python call rejected");
    }
}

- (NSString *)cancel:(NSString *)callId {
    [self.condition lock];
    MMNativeOwnedCall *removed = nil;
    BOOL active = self.running && [self.running.identity isEqualToString:callId];
    if (active) {
        self.running.cancelled = YES;
    } else {
        for (MMNativeOwnedCall *call in self.queue) {
            if ([call.identity isEqualToString:callId]) {
                removed = call;
                break;
            }
        }
    }
    if (removed) {
        removed.cancelled = YES;
        [self.queue removeObjectIdenticalTo:removed];
    }
    [self.condition unlock];

    if (active && self.interruptBlock) {
        self.interruptBlock(callId);
    }
    if (removed) {
        MMDispatchReply(removed.reply, nil, @"cancelled", @"Python call cancelled");
    }
    return active ? @"active" : (removed ? @"queued" : @"absent");
}

- (void)close:(MMNativePyReply)reply {
    [self.condition lock];
    if (self.finished) {
        [self.condition unlock];
        MMDispatchReply(reply, @YES, nil, nil);
        return;
    }
    if (reply) {
        [self.closeReplies addObject:[reply copy]];
    }
    self.closing = YES;
    NSArray<MMNativeOwnedCall *> *removed = [self.queue copy];
    [self.queue removeAllObjects];
    NSString *activeId = self.running.identity;
    self.running.cancelled = YES;
    [self.condition signal];
    BOOL unstarted = !self.started;
    [self.condition unlock];

    if (activeId && self.interruptBlock) {
        self.interruptBlock(activeId);
    }
    for (MMNativeOwnedCall *call in removed) {
        MMDispatchReply(call.reply, nil, @"cancelled", @"Python session closed");
    }
    if (unstarted) {
        [self finishWithOpenError:@"cancelled" detail:@"Session closed before starting"];
    }
}

- (void)finishWithOpenError:(nullable NSString *)errorCode detail:(nullable NSString *)detail {
    [self.condition lock];
    self.finished = YES;
    self.ready = NO;
    self.closing = YES;
    MMNativePyReply opening = self.openingReply;
    self.openingReply = nil;
    NSArray<MMNativePyReply> *replies = [self.closeReplies copy];
    [self.closeReplies removeAllObjects];
    self.worker = nil;
    self.createBlock = nil;
    self.invokeBlock = nil;
    self.disposeBlock = nil;
    [self.condition unlock];

    if (opening) {
        MMDispatchReply(opening, nil, errorCode ?: @"python_error", detail);
    }
    for (MMNativePyReply reply in replies) {
        MMDispatchReply(reply, @YES, nil, nil);
    }
}

- (void)workerMain {
    @autoreleasepool {
        uint64_t tid = 0;
        pthread_threadid_np(NULL, &tid);
        [self.condition lock];
        self.workerIdentity = tid;
        [self.condition unlock];

        PyThreadState *bootstrap = PyThreadState_New(self.mainInterpreter);
        if (!bootstrap) {
            [self finishWithOpenError:@"runtime_unavailable" detail:@"Unable to create bootstrap PyThreadState"];
            return;
        }
        PyThreadState_Swap(bootstrap);

        PyInterpreterConfig config = {};
        config.use_main_obmalloc = 0;
        config.allow_fork = 0;
        config.allow_exec = 0;
        config.allow_threads = 0;
        config.allow_daemon_threads = 0;
        config.check_multi_interp_extensions = 1;
        config.gil = PyInterpreterConfig_OWN_GIL;

        PyThreadState *state = NULL;
        PyStatus status = Py_NewInterpreterFromConfig(&state, &config);
        if (PyStatus_Exception(status)) {
            if (!PyThreadState_GetUnchecked()) {
                PyThreadState_Swap(bootstrap);
            }
            PyErr_Clear();
            PyThreadState_Clear(bootstrap);
            PyThreadState_DeleteCurrent();
            [self finishWithOpenError:@"runtime_unavailable"
                               detail:status.err_msg ? [NSString stringWithUTF8String:status.err_msg] : @"Subinterpreter creation failed"];
            return;
        }

        [self.condition lock];
        self.interpreterIdentity = PyInterpreterState_GetID(PyThreadState_GetInterpreter(state));
        BOOL closing = self.closing;
        [self.condition unlock];

        PyObject *source = NULL;
        NSString *openDetail = nil;
        if (!closing && self.createBlock) {
            source = self.createBlock(&openDetail);
        }
        NSString *pyErr = MMFetchPythonErrorDescription();
        if (pyErr.length > 0 && openDetail.length == 0) {
            openDetail = pyErr;
        }
        NSString *openError = closing ? @"cancelled" : ((source && !pyErr) ? nil : @"python_error");

        if (!openError) {
            state = PyEval_SaveThread();
            [self.condition lock];
            self.ready = !self.closing;
            closing = self.closing;
            MMNativePyReply opening = self.openingReply;
            if (closing) {
                opening = nil;
            } else {
                self.openingReply = nil;
            }
            [self.condition unlock];

            if (closing) {
                openError = @"cancelled";
            }
            if (opening) {
                MMDispatchReply(opening, @YES, nil, nil);
            }

            while (YES) {
                @autoreleasepool {
                    [self.condition lock];
                    while (!self.closing && self.queue.count == 0) {
                        [self.condition wait];
                    }
                    if (self.closing) {
                        [self.condition unlock];
                        break;
                    }
                    MMNativeOwnedCall *call = self.queue.firstObject;
                    [self.queue removeObjectAtIndex:0];
                    self.running = call;
                    [self.condition unlock];

                    NSString *jsonResult = nil;
                    NSString *callError = nil;
                    NSString *callDetail = nil;
                    if (NSProcessInfo.processInfo.systemUptime >= call.deadline) {
                        callError = @"timeout";
                    } else {
                        PyEval_RestoreThread(state);
                        double remaining = (call.deadline - NSProcessInfo.processInfo.systemUptime) * 1000.0;
                        if (remaining <= 0.0) {
                            callError = @"timeout";
                        } else if (self.invokeBlock) {
                            jsonResult = self.invokeBlock(source, call.payload, (NSUInteger)MAX(1.0, remaining), &callDetail);
                            NSString *invErr = MMFetchPythonErrorDescription();
                            if (invErr.length > 0) {
                                callDetail = invErr;
                                callError = @"python_error";
                                jsonResult = nil;
                            } else if (!jsonResult) {
                                callError = @"python_error";
                            }
                        } else {
                            callError = @"runtime_unavailable";
                        }
                        state = PyEval_SaveThread();
                    }

                    [self.condition lock];
                    if (call.cancelled || self.closing) {
                        jsonResult = nil;
                        callError = @"cancelled";
                    } else if (NSProcessInfo.processInfo.systemUptime >= call.deadline) {
                        jsonResult = nil;
                        callError = @"timeout";
                    }
                    self.running = nil;
                    [self.condition unlock];

                    MMDispatchReply(call.reply, jsonResult, callError, callDetail);
                }
            }
            PyEval_RestoreThread(state);
        }

        if (source) {
            if (self.disposeBlock) {
                self.disposeBlock(source);
            }
            PyErr_Clear();
            Py_DECREF(source);
        }
        Py_EndInterpreter(state);
        PyThreadState_Swap(bootstrap);
        PyThreadState_Clear(bootstrap);
        PyThreadState_DeleteCurrent();
        [self finishWithOpenError:openError detail:openDetail];
    }
}

@end

// ============================================================================
// Coordinator & Public Bridge
// ============================================================================

@interface MMPythonNativeCoordinator : NSObject
@property (nonatomic, strong) dispatch_queue_t registryQueue;
@property (nonatomic, strong, nullable) MMPythonNativeRuntime *runtime;
@property (nonatomic, strong, nullable) NSThread *bootstrapThread;
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *waitingOpens;
@property (nonatomic, strong) NSMutableDictionary<NSString *, MMPythonNativeOwner *> *owners;
@property (nonatomic, assign) NSUInteger maxSessions;
+ (instancetype)sharedCoordinator;
@end

@implementation MMPythonNativeCoordinator

+ (instancetype)sharedCoordinator {
    static MMPythonNativeCoordinator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _registryQueue = dispatch_queue_create("marco.python.native.registry", DISPATCH_QUEUE_SERIAL);
        _waitingOpens = [NSMutableArray array];
        _owners = [NSMutableDictionary dictionary];
        _maxSessions = MMRecommendedMaxSessions();
    }
    return self;
}

- (void)ensureRuntimeAndRun:(dispatch_block_t)block onLimit:(dispatch_block_t)limitBlock {
    dispatch_async(self.registryQueue, ^{
        if (self.runtime) {
            block();
            return;
        }
        if (self.waitingOpens.count >= 8) {
            limitBlock();
            return;
        }
        [self.waitingOpens addObject:[block copy]];
        if (!self.bootstrapThread) {
            self.bootstrapThread = [[NSThread alloc] initWithTarget:self selector:@selector(bootstrapMain) object:nil];
            self.bootstrapThread.name = @"marco-python-runtime";
            self.bootstrapThread.stackSize = 8 * 1024 * 1024;
            [self.bootstrapThread start];
        }
    });
}

- (void)bootstrapMain {
    @autoreleasepool {
        MMPythonNativeRuntime *runtime = [MMPythonNativeRuntime sharedRuntime];
        dispatch_async(self.registryQueue, ^{
            self.runtime = runtime;
            NSArray<dispatch_block_t> *pending = [self.waitingOpens copy];
            [self.waitingOpens removeAllObjects];
            for (dispatch_block_t job in pending) {
                job();
            }
        });
        // Keep the main CPython bootstrap thread alive for the process lifetime.
        NSRunLoop *loop = NSRunLoop.currentRunLoop;
        [loop addPort:[NSPort port] forMode:NSDefaultRunLoopMode];
        while (YES) {
            @autoreleasepool {
                [loop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture];
            }
        }
    }
}

- (NSUInteger)allocatedSessionCount {
    NSUInteger count = 0;
    NSMutableArray<NSString *> *finishedKeys = [NSMutableArray array];
    for (NSString *key in self.owners) {
        if ([self.owners[key] isFinished]) {
            [finishedKeys addObject:key];
        } else {
            count++;
        }
    }
    for (NSString *key in finishedKeys) {
        [self.owners removeObjectForKey:key];
    }
    return count;
}

@end

@implementation MMPythonNativeBridge

+ (BOOL)isRuntimeAvailable {
    MMPythonNativeCoordinator *coord = [MMPythonNativeCoordinator sharedCoordinator];
    if (coord.runtime != nil) {
        return coord.runtime.interpreter != NULL;
    }
    return MMIsBundledPythonPresent();
}

+ (NSDictionary<NSString *, id> *)capabilities {
    MMPythonNativeCoordinator *coord = [MMPythonNativeCoordinator sharedCoordinator];
    MMPythonNativeRuntime *runtime = coord.runtime;
    if (runtime) {
        return @{
            @"available": @(runtime.interpreter != NULL),
            @"mode": @"cpython",
            @"version": @1,
            @"runtime": runtime.version ?: @"",
            @"maxSessions": @(coord.maxSessions),
            @"hardCancel": @NO,
            @"sourceThreads": @NO,
            @"initialized": @YES,
            @"failure": runtime.failure ?: @"",
        };
    }
    BOOL bundleOk = MMIsBundledPythonPresent();
    return @{
        @"available": @(bundleOk),
        @"mode": @"cpython",
        @"version": @1,
        @"runtime": @"3.14",
        @"maxSessions": @(coord.maxSessions),
        @"hardCancel": @NO,
        @"sourceThreads": @NO,
        @"initialized": @NO,
    };
}

+ (void)openSessionWithSessionId:(NSString *)sessionId
                    packageFiles:(NSDictionary<NSString *, NSData *> *)packageFiles
                     entryModule:(NSString *)entryModule
                    proxyBaseURL:(nullable NSString *)proxyBaseURL
                      completion:(void (^)(NSDictionary<NSString *, id> * _Nullable, NSError * _Nullable))completion {
    [self openSessionWithSessionId:sessionId
                      packageFiles:packageFiles
                       entryModule:entryModule
                         extension:@""
                      proxyBaseURL:proxyBaseURL
                  remoteDescriptor:nil
                        completion:completion];
}

+ (void)openSessionWithSessionId:(NSString *)sessionId
                    packageFiles:(NSDictionary<NSString *, NSData *> *)packageFiles
                     entryModule:(NSString *)entryModule
                       extension:(NSString *)extension
                    proxyBaseURL:(nullable NSString *)proxyBaseURL
                remoteDescriptor:(nullable NSDictionary<NSString *, id> *)remoteDescriptor
                      completion:(void (^)(NSDictionary<NSString *, id> * _Nullable, NSError * _Nullable))completion {
    void (^finish)(NSDictionary<NSString *, id> *, NSError *) = ^(NSDictionary<NSString *, id> *res, NSError *err) {
        if (!completion) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(res, err);
        });
    };

    if (![sessionId isKindOfClass:NSString.class] || sessionId.length == 0 || sessionId.length > 128) {
        finish(nil, MMPythonMakeError(400, @"invalid_request", @"Invalid Python sessionId"));
        return;
    }
    if (![packageFiles isKindOfClass:NSDictionary.class] || packageFiles.count < 1 || packageFiles.count > 256) {
        finish(nil, MMPythonMakeError(400, @"invalid_request", @"Package requires 1..256 files"));
        return;
    }
    if (![entryModule isKindOfClass:NSString.class] || entryModule.length == 0 || entryModule.length > 1024) {
        finish(nil, MMPythonMakeError(400, @"invalid_request", @"Invalid entryModule"));
        return;
    }

    NSString *resolvedEntry = entryModule;
    if (![resolvedEntry hasSuffix:@".py"]) {
        NSString *withPy = [resolvedEntry stringByAppendingString:@".py"];
        if (packageFiles[withPy] != nil) {
            resolvedEntry = withPy;
        }
    }
    if (![resolvedEntry hasSuffix:@".py"] || packageFiles[resolvedEntry] == nil) {
        finish(nil, MMPythonMakeError(400, @"invalid_request", @"Entry Python module not found in packageFiles"));
        return;
    }

    NSMutableDictionary<NSString *, NSData *> *filesCopy = [NSMutableDictionary dictionaryWithCapacity:packageFiles.count];
    NSUInteger totalBytes = 0;
    for (id rawName in packageFiles) {
        id rawData = packageFiles[rawName];
        if (![rawName isKindOfClass:NSString.class] || [(NSString *)rawName length] == 0 ||
            [(NSString *)rawName length] > 1024 || ![rawData isKindOfClass:NSData.class]) {
            finish(nil, MMPythonMakeError(400, @"invalid_request", @"Invalid file entry in packageFiles"));
            return;
        }
        NSData *data = (NSData *)rawData;
        totalBytes += data.length;
        if (data.length > 2 * 1024 * 1024 || totalBytes > MMNativeBodyLimit) {
            finish(nil, MMPythonMakeError(400, @"invalid_request", @"Package files exceed 2 MiB/file or 6 MiB total"));
            return;
        }
        filesCopy[[(NSString *)rawName copy]] = [data copy];
    }

    NSString *extCopy = [extension isKindOfClass:NSString.class] ? [extension copy] : @"";
    if ([extCopy lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 64 * 1024) {
        finish(nil, MMPythonMakeError(400, @"invalid_request", @"Extension exceeds 64 KiB limit"));
        return;
    }

    NSString *proxyCopy = nil;
    if (proxyBaseURL != nil && proxyBaseURL.length > 0) {
        if (!MMValidateProxyURL(proxyBaseURL)) {
            finish(nil, MMPythonMakeError(400, @"invalid_request", @"Invalid loopback proxyBaseURL"));
            return;
        }
        proxyCopy = [proxyBaseURL copy];
    }

    id remoteCopy = NSNull.null;
    if (remoteDescriptor != nil) {
        if (![remoteDescriptor isKindOfClass:NSDictionary.class] ||
            ![remoteDescriptor[@"url"] isKindOfClass:NSString.class] ||
            ![remoteDescriptor[@"headers"] isKindOfClass:NSDictionary.class] ||
            [(NSString *)remoteDescriptor[@"url"] length] > 16384) {
            finish(nil, MMPythonMakeError(400, @"invalid_request", @"Invalid remoteDescriptor"));
            return;
        }
        remoteCopy = @{
            @"url": [remoteDescriptor[@"url"] copy],
            @"headers": [remoteDescriptor[@"headers"] copy],
        };
    }

    NSString *sidCopy = [sessionId copy];
    NSString *entryCopy = [resolvedEntry copy];
    MMPythonNativeCoordinator *coord = [MMPythonNativeCoordinator sharedCoordinator];

    [coord ensureRuntimeAndRun:^{
        MMPythonNativeRuntime *runtime = coord.runtime;
        if (!runtime || !runtime.interpreter) {
            finish(nil, MMPythonMakeError(503, @"runtime_unavailable", runtime.failure ?: @"CPython runtime unavailable"));
            return;
        }
        if ([coord allocatedSessionCount] >= coord.maxSessions || coord.owners.count >= 16) {
            finish(nil, MMPythonMakeError(429, @"runtime_limit", @"Maximum concurrent Python sessions reached"));
            return;
        }
        if (coord.owners[sidCopy] != nil) {
            finish(nil, MMPythonMakeError(409, @"invalid_handle", @"Python sessionId is already active"));
            return;
        }

        MMPythonNativeTransport *transport = [[MMPythonNativeTransport alloc] init];
        MMPythonNativeOwner *owner = [[MMPythonNativeOwner alloc]
            initWithMainInterpreter:runtime.interpreter
            create:^PyObject *(NSString **detailOut) {
                PyObject *module = PyImport_ImportModule("native_source_entry");
                PyObject *package = module ? MMPackageFilesToPy(filesCopy) : NULL;
                PyObject *entryVal = MMStringToPy(entryCopy);
                PyObject *extVal = MMStringToPy(extCopy);
                PyObject *proxyVal = proxyCopy ? MMStringToPy(proxyCopy) : Py_NewRef(Py_None);
                PyObject *bridge = package ? MMCreatePythonNativeTransportBridge(transport) : NULL;
                PyObject *options = MMJSONObjectToPy(@[remoteCopy]);
                PyObject *source = (module && package && entryVal && extVal && proxyVal && bridge && options)
                    ? PyObject_CallMethod(
                        module,
                        "create",
                        "OOOOOO",
                        entryVal,
                        package,
                        extVal,
                        proxyVal,
                        bridge,
                        PyList_GetItem(options, 0)
                      )
                    : NULL;
                if (!source && detailOut) {
                    *detailOut = MMFetchPythonErrorDescription();
                }
                PyObject *root = source ? PyTuple_Pack(2, module, source) : NULL;
                Py_XDECREF(source);
                Py_XDECREF(options);
                Py_XDECREF(bridge);
                Py_XDECREF(proxyVal);
                Py_XDECREF(extVal);
                Py_XDECREF(entryVal);
                Py_XDECREF(package);
                Py_XDECREF(module);
                return root;
            }
            invoke:^NSString *(PyObject *root, NSDictionary *payload, NSUInteger remainingMs, NSString **detailOut) {
                if (![transport beginCall:payload[@"callId"] budgetMs:remainingMs]) {
                    PyErr_SetString(PyExc_RuntimeError, "Operation unavailable");
                    return nil;
                }
                PyObject *arguments = MMJSONObjectToPy(payload[@"args"]);
                PyObject *value = arguments
                    ? PyObject_CallMethod(
                        PyTuple_GetItem(root, 0),
                        "invoke",
                        "OsOsk",
                        PyTuple_GetItem(root, 1),
                        [payload[@"method"] UTF8String],
                        arguments,
                        [payload[@"callId"] UTF8String],
                        (unsigned long)remainingMs
                      )
                    : NULL;
                NSString *jsonOut = value ? MMPyResultToJSONString(value) : nil;
                if (!jsonOut && detailOut) {
                    *detailOut = MMFetchPythonErrorDescription();
                }
                Py_XDECREF(value);
                Py_XDECREF(arguments);
                [transport endCall];
                return jsonOut;
            }
            dispose:^(PyObject *root) {
                PyObject *value = PyObject_CallMethod(PyTuple_GetItem(root, 0), "close", "O", PyTuple_GetItem(root, 1));
                Py_XDECREF(value);
                [transport invalidate];
            }
            interrupt:^(NSString *callId) {
                [transport cancelCall:callId];
            }];

        coord.owners[sidCopy] = owner;
        [owner start:^(id _Nullable value, NSString * _Nullable errorCode, NSString * _Nullable detail) {
            (void)value;
            if (errorCode) {
                dispatch_async(coord.registryQueue, ^{
                    if (coord.owners[sidCopy] == owner) {
                        [coord.owners removeObjectForKey:sidCopy];
                    }
                });
                finish(nil, MMPythonMakeError(500, errorCode, detail ?: @"Failed to open Python session"));
            } else {
                finish(@{
                    @"sessionId": sidCopy,
                    @"handle": sidCopy,
                    @"ready": @YES,
                    @"runtime": runtime.version ?: @"",
                }, nil);
            }
        }];
    } onLimit:^{
        finish(nil, MMPythonMakeError(429, @"runtime_limit", @"Python runtime is starting, please retry"));
    }];
}

+ (void)callSessionWithSessionId:(NSString *)sessionId
                          callId:(NSString *)callId
                          method:(NSString *)method
                   argumentsJSON:(NSString *)argumentsJSON
                       timeoutMs:(NSInteger)timeoutMs
                      completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    void (^finish)(NSString *, NSError *) = ^(NSString *jsonStr, NSError *err) {
        if (!completion) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(jsonStr, err);
        });
    };

    static NSSet<NSString *> *allowedMethods = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedMethods = [NSSet setWithArray:@[
            @"home", @"homeVod", @"category", @"search", @"detail", @"play", @"proxy", @"liveContent",
        ]];
    });

    NSString *normCallId = MMNormalizeCallId(callId);
    if (![sessionId isKindOfClass:NSString.class] || sessionId.length == 0 ||
        !MMIsHex32(normCallId) || ![allowedMethods containsObject:method ?: @""]) {
        finish(nil, MMPythonMakeError(400, @"invalid_request", @"Invalid Python call parameters"));
        return;
    }

    NSArray *parsedArgs = @[];
    NSString *trimmedJSON = [argumentsJSON isKindOfClass:NSString.class]
        ? [argumentsJSON stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : @"";
    if (trimmedJSON.length > 0) {
        NSData *jsonData = [trimmedJSON dataUsingEncoding:NSUTF8StringEncoding];
        NSError *parseErr = nil;
        id parsed = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&parseErr] : nil;
        if (parseErr || ![parsed isKindOfClass:NSArray.class]) {
            finish(nil, MMPythonMakeError(400, @"invalid_request", @"argumentsJSON must be a JSON array"));
            return;
        }
        parsedArgs = parsed;
    }

    NSUInteger clampedBudgetMs = (timeoutMs <= 0) ? 15000 : (NSUInteger)MIN(MAX(timeoutMs, (NSInteger)1), (NSInteger)45000);
    NSDictionary *payload = @{
        @"callId": normCallId,
        @"method": [method copy],
        @"args": parsedArgs,
        @"budgetMs": @(clampedBudgetMs),
    };

    MMPythonNativeCoordinator *coord = [MMPythonNativeCoordinator sharedCoordinator];
    dispatch_async(coord.registryQueue, ^{
        MMPythonNativeOwner *owner = coord.owners[sessionId];
        if (!owner) {
            finish(nil, MMPythonMakeError(404, @"invalid_handle", @"Python session not found"));
            return;
        }
        [owner invoke:normCallId
              payload:payload
             budgetMs:clampedBudgetMs
                reply:^(id _Nullable value, NSString * _Nullable errorCode, NSString * _Nullable detail) {
                    if (errorCode) {
                        finish(nil, MMPythonMakeError(500, errorCode, detail ?: @"Python call failed"));
                    } else if ([value isKindOfClass:NSString.class]) {
                        finish((NSString *)value, nil);
                    } else {
                        finish(nil, MMPythonMakeError(500, @"python_error", @"Empty Python result"));
                    }
                }];
    });
}

+ (void)cancelCallWithSessionId:(NSString *)sessionId callId:(NSString *)callId {
    if (![sessionId isKindOfClass:NSString.class] || sessionId.length == 0) {
        return;
    }
    NSString *normCallId = MMNormalizeCallId(callId);
    if (!MMIsHex32(normCallId)) {
        return;
    }
    MMPythonNativeCoordinator *coord = [MMPythonNativeCoordinator sharedCoordinator];
    dispatch_async(coord.registryQueue, ^{
        MMPythonNativeOwner *owner = coord.owners[sessionId];
        if (!owner) return;
        NSString *state = [owner cancel:normCallId];
        if ([state isEqualToString:@"active"]) {
            [owner close:^(id _Nullable value, NSString * _Nullable errorCode, NSString * _Nullable detail) {
                (void)value;
                (void)errorCode;
                (void)detail;
                dispatch_async(coord.registryQueue, ^{
                    if (coord.owners[sessionId] == owner) {
                        [coord.owners removeObjectForKey:sessionId];
                    }
                });
            }];
        }
    });
}

+ (void)closeSessionWithSessionId:(NSString *)sessionId completion:(void (^ _Nullable)(void))completion {
    void (^done)(void) = ^{
        if (!completion) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion();
        });
    };
    if (![sessionId isKindOfClass:NSString.class] || sessionId.length == 0) {
        done();
        return;
    }
    MMPythonNativeCoordinator *coord = [MMPythonNativeCoordinator sharedCoordinator];
    dispatch_async(coord.registryQueue, ^{
        MMPythonNativeOwner *owner = coord.owners[sessionId];
        if (!owner) {
            done();
            return;
        }
        [owner close:^(id _Nullable value, NSString * _Nullable errorCode, NSString * _Nullable detail) {
            (void)value;
            (void)errorCode;
            (void)detail;
            dispatch_async(coord.registryQueue, ^{
                if (coord.owners[sessionId] == owner) {
                    [coord.owners removeObjectForKey:sessionId];
                }
            });
            done();
        }];
    });
}

@end

#else

// ============================================================================
// Light-Simulator / Non-CPython Stub Implementation
// ============================================================================

@implementation MMPythonNativeBridge

+ (BOOL)isRuntimeAvailable {
    return NO;
}

+ (NSDictionary<NSString *, id> *)capabilities {
    return @{
        @"available": @NO,
        @"mode": @"light-simulator",
    };
}

+ (void)openSessionWithSessionId:(NSString *)sessionId
                    packageFiles:(NSDictionary<NSString *, NSData *> *)packageFiles
                     entryModule:(NSString *)entryModule
                    proxyBaseURL:(nullable NSString *)proxyBaseURL
                      completion:(void (^)(NSDictionary<NSString *, id> * _Nullable, NSError * _Nullable))completion {
    [self openSessionWithSessionId:sessionId
                      packageFiles:packageFiles
                       entryModule:entryModule
                         extension:@""
                      proxyBaseURL:proxyBaseURL
                  remoteDescriptor:nil
                        completion:completion];
}

+ (void)openSessionWithSessionId:(NSString *)sessionId
                    packageFiles:(NSDictionary<NSString *, NSData *> *)packageFiles
                     entryModule:(NSString *)entryModule
                       extension:(NSString *)extension
                    proxyBaseURL:(nullable NSString *)proxyBaseURL
                remoteDescriptor:(nullable NSDictionary<NSString *, id> *)remoteDescriptor
                      completion:(void (^)(NSDictionary<NSString *, id> * _Nullable, NSError * _Nullable))completion {
    (void)sessionId;
    (void)packageFiles;
    (void)entryModule;
    (void)extension;
    (void)proxyBaseURL;
    (void)remoteDescriptor;
    if (!completion) return;
    NSError *err = MMPythonMakeError(
        501,
        @"runtime_unavailable",
        @"CPython runtime is unavailable in light-simulator mode"
    );
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, err);
    });
}

+ (void)callSessionWithSessionId:(NSString *)sessionId
                          callId:(NSString *)callId
                          method:(NSString *)method
                   argumentsJSON:(NSString *)argumentsJSON
                       timeoutMs:(NSInteger)timeoutMs
                      completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    (void)sessionId;
    (void)callId;
    (void)method;
    (void)argumentsJSON;
    (void)timeoutMs;
    if (!completion) return;
    NSError *err = MMPythonMakeError(
        501,
        @"runtime_unavailable",
        @"CPython runtime is unavailable in light-simulator mode"
    );
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, err);
    });
}

+ (void)cancelCallWithSessionId:(NSString *)sessionId callId:(NSString *)callId {
    (void)sessionId;
    (void)callId;
}

+ (void)closeSessionWithSessionId:(NSString *)sessionId completion:(void (^ _Nullable)(void))completion {
    (void)sessionId;
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion();
    });
}

@end

#endif
