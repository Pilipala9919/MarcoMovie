#import "MMPythonSourceRegistry.h"
#import "MMPythonOwner.h"
#import "MMPythonTransport.h"
#include <math.h>

static BOOL MMFields(NSDictionary *value, NSArray *keys) {
    return value && value.count==keys.count && [[NSSet setWithArray:value.allKeys] isEqual:[NSSet setWithArray:keys]];
}
static BOOL MMInteger(id value, NSUInteger max) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return NO;
    double number=[value doubleValue];return isfinite(number) && number>=1 && number<=max && floor(number)==number;
}
static BOOL MMCallID(id value) {
    return [value isKindOfClass:NSString.class] && [value length]==32 &&
        [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location==NSNotFound;
}
static BOOL MMProxy(id value) {
    if (![value isKindOfClass:NSString.class] || [value length]>512) return NO;
    NSURLComponents *url=[NSURLComponents componentsWithString:value];
    NSArray *parts=[url.path componentsSeparatedByString:@"/"];
    NSString *token=parts.count==4?parts[2]:@"";
    NSMutableDictionary *query=[NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in url.queryItems) if (item.value) query[item.name]=item.value;
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    return [url.scheme isEqual:@"http"] && [url.host isEqual:@"127.0.0.1"] && url.port.integerValue>0 && url.port.integerValue<=65535 &&
        !url.user && !url.password && !url.fragment && [url.path isEqual:url.percentEncodedPath] &&
        parts.count==4 && [parts[1] isEqual:@"_spider"] && [parts[3] isEqual:@"proxy"] &&
        token.length==43 && [token rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound &&
        url.queryItems.count==2 && [query[@"do"] isEqual:@"py"] && [query[@"siteKey"] isEqual:token];
}
static id MMFailure(NSString *code) {
    return [FlutterError errorWithCode:code message:@"Python source operation failed" details:nil];
}
static PyObject *MMString(NSString *value) {
    NSData *bytes=[value dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes) { PyErr_SetString(PyExc_ValueError,"Invalid string");return NULL; }
    return PyUnicode_DecodeUTF8((const char *)bytes.bytes,bytes.length,"strict");
}
static PyObject *MMArguments(NSArray *args) {
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:args options:0 error:nil];
    if (!bytes || bytes.length>64*1024) { PyErr_SetString(PyExc_ValueError,"Invalid call arguments");return NULL; }
    PyObject *module=PyImport_ImportModule("json");
    PyObject *text=PyUnicode_DecodeUTF8((const char *)bytes.bytes,bytes.length,"strict");
    PyObject *value=module&&text?PyObject_CallMethod(module,"loads","O",text):NULL;
    Py_XDECREF(text);Py_XDECREF(module);return value;
}
static id MMResult(PyObject *value) {
    PyObject *module=PyImport_ImportModule("json");
    PyObject *text=module?PyObject_CallMethod(module,"dumps","O",value):NULL;
    Py_XDECREF(module);Py_ssize_t size=0;const char *utf8=text?PyUnicode_AsUTF8AndSize(text,&size):NULL;
    id result=nil;
    // A bounded 6 MiB binary proxy body expands to 8 MiB in JSON base64.
    if (utf8 && size<=9*1024*1024) result=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:utf8 length:size] options:NSJSONReadingFragmentsAllowed error:nil];
    Py_XDECREF(text);
    if (!result && !PyErr_Occurred()) PyErr_SetString(PyExc_ValueError,"Result exceeds source protocol limit");
    return result;
}
static PyObject *MMPackage(NSDictionary<NSString *,NSData *> *files) {
    PyObject *result=PyDict_New();if (!result) return NULL;
    for (NSString *name in files) {
        PyObject *key=MMString(name);NSData *data=files[name];
        PyObject *value=PyBytes_FromStringAndSize((const char *)data.bytes,data.length);
        int status=key&&value?PyDict_SetItem(result,key,value):-1;Py_XDECREF(key);Py_XDECREF(value);
        if (status<0) { Py_DECREF(result);return NULL; }
    }
    return result;
}

@interface MMPythonSourceRegistry ()
@property(nonatomic,strong) FlutterMethodChannel *channel;
@property(nonatomic,assign) PyInterpreterState *interpreter;
@property(nonatomic,strong) NSMutableDictionary<NSString *,MMPythonOwner *> *owners;
@end

@implementation MMPythonSourceRegistry
- (instancetype)initWithChannel:(FlutterMethodChannel *)channel interpreter:(PyInterpreterState *)interpreter {
    if ((self=[super init])) { _channel=channel;_interpreter=interpreter;_owners=[NSMutableDictionary dictionary]; }
    return self;
}
- (NSDictionary *)snapshot {
    NSAssert(NSThread.isMainThread,@"Source registry requires the platform thread");
    NSMutableDictionary *states=[NSMutableDictionary dictionary];NSUInteger allocated=0;
    for (NSString *handle in self.owners) {
        NSDictionary *state=[self.owners[handle] snapshot];states[handle]=state;
        if (![state[@"finished"] boolValue]) allocated++;
    }
    return @{@"allocated":@(allocated),@"owners":states};
}
- (void)handle:(FlutterMethodCall *)call result:(FlutterResult)reply {
    NSAssert(NSThread.isMainThread,@"Source registry requires the platform thread");
    NSDictionary *args=[call.arguments isKindOfClass:NSDictionary.class]?call.arguments:nil;
    if (!MMInteger(args[@"version"],1)) { reply(MMFailure(@"invalid_request"));return; }
    if ([call.method isEqual:@"python.open"]) {
        NSArray *fields=args[@"remote"]?@[@"version",@"entry",@"files",@"extension",@"proxy",@"remote"]:@[@"version",@"entry",@"files",@"extension",@"proxy"];
        if (!MMFields(args,fields) ||
                ![args[@"entry"] isKindOfClass:NSString.class] || [args[@"entry"] length]>1024 ||
                ![args[@"entry"] hasSuffix:@".py"] || ![args[@"files"] isKindOfClass:NSDictionary.class] ||
                ![args[@"extension"] isKindOfClass:NSString.class] || [args[@"extension"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>64*1024 || !MMProxy(args[@"proxy"])) {
            reply(MMFailure(@"invalid_request"));return;
        }
        NSDictionary *provided=args[@"files"];
        if (provided.count<1 || provided.count>256 || !provided[args[@"entry"]]) { reply(MMFailure(@"invalid_request"));return; }
        NSMutableDictionary<NSString *,NSData *> *files=[NSMutableDictionary dictionary];NSUInteger total=0;
        for (id name in provided) {
            id value=provided[name];
            if (![name isKindOfClass:NSString.class] || [name length]==0 || [name length]>1024 || ![value isKindOfClass:FlutterStandardTypedData.class]) {
                reply(MMFailure(@"invalid_request"));return;
            }
            NSData *bytes=[value data];total+=bytes.length;
            if (bytes.length>2*1024*1024 || total>6*1024*1024) { reply(MMFailure(@"invalid_request"));return; }
            files[[name copy]]=[bytes copy];
        }
        // Path normalization, module conflicts and reserved names are validated
        // by the trusted shared loader before the source is ever imported.
        if (!self.interpreter) { reply(MMFailure(@"runtime_unavailable"));return; }
        if ([[self snapshot][@"allocated"] unsignedIntegerValue]>=2 || self.owners.count>=8) { reply(MMFailure(@"runtime_limit"));return; }
        id remote=args[@"remote"]?:NSNull.null;
        if (remote!=NSNull.null && (![remote isKindOfClass:NSDictionary.class] ||
                !MMFields(remote,@[@"url",@"headers"]) || ![remote[@"url"] isKindOfClass:NSString.class] ||
                ![remote[@"headers"] isKindOfClass:NSDictionary.class] || [remote[@"url"] length]>16384)) {
            reply(MMFailure(@"invalid_request"));return;
        }
        NSString *entry=[args[@"entry"] copy],*extension=[args[@"extension"] copy],*proxy=[args[@"proxy"] copy];
        NSString *handle=NSUUID.UUID.UUIDString.lowercaseString;
        MMPythonTransport *transport=[[MMPythonTransport alloc] initWithChannel:self.channel handle:handle];
        MMPythonOwner *owner=[[MMPythonOwner alloc] initWithMainInterpreter:self.interpreter create:^PyObject *{
            PyObject *module=PyImport_ImportModule("native_source_entry");
            PyObject *package=module?MMPackage(files):NULL;
            PyObject *entryValue=MMString(entry),*extensionValue=MMString(extension),*proxyValue=MMString(proxy);
            PyObject *bridge=package?MMCreatePythonTransportBridge(transport):NULL;
            PyObject *options=MMArguments(@[remote]);
            PyObject *source=module&&package&&entryValue&&extensionValue&&proxyValue&&bridge&&options?
                PyObject_CallMethod(module,"create","OOOOOO",entryValue,package,extensionValue,proxyValue,bridge,PyList_GetItem(options,0)):NULL;
            PyObject *root=source?PyTuple_Pack(2,module,source):NULL;
            Py_XDECREF(source);Py_XDECREF(options);Py_XDECREF(bridge);Py_XDECREF(proxyValue);Py_XDECREF(extensionValue);
            Py_XDECREF(entryValue);Py_XDECREF(package);Py_XDECREF(module);return root;
        } invoke:^id(PyObject *root, NSDictionary *payload, NSUInteger remaining) {
            if (![transport beginCall:payload[@"callId"] budgetMs:remaining]) { PyErr_SetString(PyExc_RuntimeError,"Operation unavailable");return nil; }
            PyObject *arguments=MMArguments(payload[@"args"]);
            PyObject *value=arguments?PyObject_CallMethod(PyTuple_GetItem(root,0),"invoke","OsOsk",PyTuple_GetItem(root,1),
                [payload[@"method"] UTF8String],arguments,[payload[@"callId"] UTF8String],(unsigned long)remaining):NULL;
            id result=value?MMResult(value):nil;
            Py_XDECREF(value);Py_XDECREF(arguments);[transport endCall];return result;
        } dispose:^(PyObject *root) {
            PyObject *value=PyObject_CallMethod(PyTuple_GetItem(root,0),"close","O",PyTuple_GetItem(root,1));
            Py_XDECREF(value);[transport endCall];
        } interrupt:^(NSString *callId) { [transport cancelCall:callId]; }];
        self.owners[handle]=owner;
        [owner start:^(id value, NSString *error) {
            if (error) { [self.owners removeObjectForKey:handle];reply(MMFailure(error)); }
            else reply(@{@"handle":handle});
        }];return;
    }
    NSString *handle=[args[@"handle"] isKindOfClass:NSString.class]?args[@"handle"]:nil;
    MMPythonOwner *owner=handle?self.owners[handle]:nil;
    if ([call.method isEqual:@"python.close"] && MMFields(args,@[@"version",@"handle"])) {
        if (!owner) { reply(@{@"closed":@YES});return; }
        [owner close:^(id value, NSString *error) {
            [self.owners removeObjectForKey:handle];reply(error?MMFailure(error):@{@"closed":@YES});
        }];return;
    }
    if (!owner) { reply(MMFailure(@"invalid_handle"));return; }
    if ([call.method isEqual:@"python.cancel"] && MMFields(args,@[@"version",@"handle",@"callId"]) && MMCallID(args[@"callId"])) {
        NSString *state=[owner cancel:args[@"callId"]];
        if ([state isEqual:@"active"]) [owner close:^(id value, NSString *error) {}];
        reply(@{@"cancelled":state});return;
    }
    if ([call.method isEqual:@"python.call"] && MMFields(args,@[@"version",@"handle",@"callId",@"method",@"args",@"budgetMs"]) &&
            MMCallID(args[@"callId"]) && MMInteger(args[@"budgetMs"],45000) && [args[@"args"] isKindOfClass:NSArray.class] &&
            [@[@"home",@"homeVod",@"category",@"search",@"detail",@"play",@"proxy",@"liveContent"] containsObject:args[@"method"]?:NSNull.null]) {
        [owner invoke:args[@"callId"] payload:args budgetMs:[args[@"budgetMs"] unsignedIntegerValue] reply:^(id value, NSString *error) {
            reply(error?MMFailure(error):value);
        }];return;
    }
    reply(MMFailure(@"invalid_request"));
}
@end
