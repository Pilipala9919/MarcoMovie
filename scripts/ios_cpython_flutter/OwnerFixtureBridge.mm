#import "OwnerFixtureBridge.h"
#import "MMPythonOwner.h"
#import "FlutterPythonTransport.h"

static BOOL MMKeys(NSDictionary *args, NSArray *keys) {
    return args.count==keys.count && [[NSSet setWithArray:args.allKeys] isEqual:[NSSet setWithArray:keys]];
}
static BOOL MMHex(NSString *text, NSUInteger size) {
    return [text isKindOfClass:NSString.class] && text.length==size &&
        [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location==NSNotFound;
}
static BOOL MMLoopback(NSURLComponents *url) {
    return url && [url.scheme isEqual:@"http"] && [url.host isEqual:@"127.0.0.1"] &&
        url.port.integerValue>0 && url.port.integerValue<=65535 && !url.user && !url.password && !url.fragment &&
        [url.path isEqual:url.percentEncodedPath];
}
static id MMError(NSString *code) {
    return [FlutterError errorWithCode:code message:@"Owned source operation failed" details:nil];
}
static PyObject *MMFromJSON(id input) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:input options:0 error:nil];
    if (!data || data.length>64*1024) { PyErr_SetString(PyExc_ValueError,"Invalid arguments");return NULL; }
    PyObject *json=PyImport_ImportModule("json");
    PyObject *text=PyUnicode_DecodeUTF8((const char *)data.bytes,data.length,"strict");
    PyObject *value=json&&text?PyObject_CallMethod(json,"loads","O",text):NULL;
    Py_XDECREF(text);Py_XDECREF(json);return value;
}
static id MMToJSON(PyObject *input) {
    PyObject *json=PyImport_ImportModule("json");
    PyObject *text=json?PyObject_CallMethod(json,"dumps","O",input):NULL;
    Py_XDECREF(json);Py_ssize_t size=0;
    const char *utf8=text?PyUnicode_AsUTF8AndSize(text,&size):NULL;id value=nil;
    if (utf8 && size<=1024*1024) value=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:utf8 length:size] options:NSJSONReadingFragmentsAllowed error:nil];
    Py_XDECREF(text);
    if (!value && !PyErr_Occurred()) PyErr_SetString(PyExc_ValueError,"Invalid result");
    return value;
}
static void MMBlockCapsuleFree(PyObject *capsule) {
    void *pointer=PyCapsule_GetPointer(capsule,"owned.fixture.channel");
    if (pointer) CFRelease(pointer);else PyErr_Clear();
}
static PyObject *MMBlock(PyObject *capsule, PyObject *unused) {
    (void)unused;
    void *pointer=PyCapsule_GetPointer(capsule,"owned.fixture.channel");
    if (!pointer) return NULL;
    FlutterMethodChannel *channel=(__bridge FlutterMethodChannel *)pointer;
    dispatch_async(dispatch_get_main_queue(),^{ [channel invokeMethod:@"owner.blockEntered" arguments:nil]; });
    // Intentionally retain this interpreter's GIL inside a bounded C callback.
    // Cancellation cannot stop it; another owner's interpreter must still work.
    [NSThread sleepForTimeInterval:3];
    Py_RETURN_TRUE;
}
static PyMethodDef MMBlockDefinition={"native_block",MMBlock,METH_NOARGS,"Owned bounded C-block fixture"};

@interface OwnerFixtureBridge ()
@property(nonatomic,strong) FlutterMethodChannel *channel;
@property(nonatomic,assign) PyInterpreterState *interpreter;
@property(nonatomic,strong) NSMutableDictionary<NSString *,MMPythonOwner *> *owners;
@end

@implementation OwnerFixtureBridge
- (instancetype)initWithChannel:(FlutterMethodChannel *)channel interpreter:(PyInterpreterState *)interpreter {
    if ((self=[super init])) { _channel=channel;_interpreter=interpreter;_owners=[NSMutableDictionary dictionary]; }
    return self;
}
- (void)handle:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSAssert(NSThread.isMainThread,@"Owner registry belongs to the Flutter platform thread");
    NSDictionary *args=[call.arguments isKindOfClass:NSDictionary.class]?call.arguments:nil;
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.pilipala.experimental.cpythonflutter"] ||
            ![args[@"version"] isEqual:@1] || CFGetTypeID((__bridge CFTypeRef)args[@"version"])==CFBooleanGetTypeID()) {
        result(MMError(@"invalid_request"));return;
    }
    if ([call.method isEqual:@"actorStatus"] && MMKeys(args,@[@"version"])) {
        NSMutableDictionary *states=[NSMutableDictionary dictionary];NSUInteger allocated=0;
        for (NSString *handle in self.owners) {
            NSDictionary *state=[self.owners[handle] snapshot];states[handle]=state;
            if (![state[@"finished"] boolValue]) allocated++;
        }
        result(@{@"owners":states,@"allocated":@(allocated)});return;
    }
    if ([call.method isEqual:@"openActor"]) {
        NSURLComponents *origin=[args[@"origin"] isKindOfClass:NSString.class]?[NSURLComponents componentsWithString:args[@"origin"]]:nil;
        NSURLComponents *proxy=[args[@"proxy"] isKindOfClass:NSString.class]?[NSURLComponents componentsWithString:args[@"proxy"]]:nil;
        NSArray *parts=[proxy.path componentsSeparatedByString:@"/"];
        NSMutableDictionary *query=[NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in proxy.queryItems) if (item.value) query[item.name]=item.value;
        NSString *token=parts.count==4?parts[2]:@"";
        NSCharacterSet *tokenSet=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
        BOOL valid=MMKeys(args,@[@"version",@"source",@"origin",@"proxy"]) && [args[@"source"] isEqual:@"native-source-v1"] &&
            MMLoopback(origin) && !origin.query && origin.path.length==33 && [origin.path hasPrefix:@"/"] && MMHex([origin.path substringFromIndex:1],32) &&
            MMLoopback(proxy) && parts.count==4 && [parts[1] isEqual:@"_spider"] && [parts[3] isEqual:@"proxy"] &&
            token.length==43 && [token rangeOfCharacterFromSet:tokenSet.invertedSet].location==NSNotFound &&
            proxy.queryItems.count==2 && [query[@"do"] isEqual:@"py"] && [query[@"siteKey"] isEqual:token];
        if (!valid) { result(MMError(@"invalid_request"));return; }
        // Closed records are retained until release so callers can acknowledge
        // cleanup. Bound those records too; never evict a still-running owner.
        NSUInteger allocated=0;
        for (MMPythonOwner *owner in self.owners.allValues) if (![[owner snapshot][@"finished"] boolValue]) allocated++;
        if (allocated>=2 || self.owners.count>=8) { result(MMError(@"runtime_limit"));return; }
        NSString *address=[args[@"origin"] copy],*proxyURL=[args[@"proxy"] copy];
        FlutterPythonTransport *transport=[[FlutterPythonTransport alloc] initWithChannel:self.channel];
        FlutterMethodChannel *channel=self.channel;
        MMPythonOwner *owner=[[MMPythonOwner alloc] initWithMainInterpreter:self.interpreter create:^PyObject *{
            PyObject *module=PyImport_ImportModule("source_session_fixture");
            PyObject *capsule=module?PyCapsule_New((void *)CFBridgingRetain(channel),"owned.fixture.channel",MMBlockCapsuleFree):NULL;
            PyObject *block=capsule?PyCFunction_New(&MMBlockDefinition,capsule):NULL;
            if (block && PyObject_SetAttrString(module,"native_block",block)<0) { Py_CLEAR(block); }
            Py_XDECREF(block);Py_XDECREF(capsule);
            PyObject *bridge=module?MMCreateFixtureTransportBridge(transport):NULL;
            PyObject *source=bridge?PyObject_CallMethod(module,"create","ssO",address.UTF8String,proxyURL.UTF8String,bridge):NULL;
            PyObject *root=source?PyTuple_Pack(2,module,source):NULL;
            Py_XDECREF(source);Py_XDECREF(bridge);Py_XDECREF(module);return root;
        } invoke:^id(PyObject *root, NSDictionary *payload, NSUInteger remaining) {
            if (![transport beginOrigins:@[address]]) { PyErr_SetString(PyExc_RuntimeError,"Transport busy");return nil; }
            PyObject *arguments=MMFromJSON(payload[@"args"]);
            PyObject *value=arguments?PyObject_CallMethod(PyTuple_GetItem(root,0),"dispatch_owned","OsOsk",
                PyTuple_GetItem(root,1),[payload[@"method"] UTF8String],arguments,[payload[@"callId"] UTF8String],(unsigned long)remaining):NULL;
            id output=value?MMToJSON(value):nil;
            Py_XDECREF(value);Py_XDECREF(arguments);[transport endProbe];return output;
        } dispose:^(PyObject *root) {
            PyObject *closed=PyObject_CallMethod(PyTuple_GetItem(root,0),"close","O",PyTuple_GetItem(root,1));
            Py_XDECREF(closed);[transport endProbe];
        } interrupt:^(NSString *callId) { [transport cancelCall:callId]; }];
        NSString *handle=NSUUID.UUID.UUIDString.lowercaseString;self.owners[handle]=owner;
        [owner start:^(id value, NSString *error) {
            if (error) { [self.owners removeObjectForKey:handle];result(MMError(error)); }
            else result(@{@"handle":handle});
        }];return;
    }
    NSString *handle=[args[@"handle"] isKindOfClass:NSString.class]?args[@"handle"]:nil;
    MMPythonOwner *owner=handle?self.owners[handle]:nil;
    if ([call.method isEqual:@"releaseActor"] && MMKeys(args,@[@"version",@"handle"])) {
        if (!owner) { result(@{@"released":@NO});return; }
        [owner close:^(id value, NSString *error) {
            [self.owners removeObjectForKey:handle];result(error?MMError(error):@{@"released":@YES});
        }];return;
    }
    if (!owner) { result(MMError(@"invalid_handle"));return; }
    if ([call.method isEqual:@"cancelActor"] && MMKeys(args,@[@"version",@"handle",@"callId"]) && MMHex(args[@"callId"],32)) {
        NSString *state=[owner cancel:args[@"callId"]];
        // Active cancellation retires this interpreter. Keep its registry slot
        // occupied until execution actually returns and destruction finishes.
        if ([state isEqual:@"active"]) [owner close:^(id value, NSString *error) {}];
        result(@{@"cancelled":state});return;
    }
    if ([call.method isEqual:@"callActor"] && MMKeys(args,@[@"version",@"handle",@"method",@"args",@"callId",@"budgetMs"]) &&
            [args[@"args"] isKindOfClass:NSArray.class] && [args[@"budgetMs"] isKindOfClass:NSNumber.class] &&
            CFGetTypeID((__bridge CFTypeRef)args[@"budgetMs"])!=CFBooleanGetTypeID() &&
            [@[@"home",@"homeVod",@"category",@"search",@"detail",@"play",@"proxy",@"liveContent"] containsObject:args[@"method"]?:NSNull.null] &&
            [args[@"budgetMs"] doubleValue]==[args[@"budgetMs"] unsignedIntegerValue]) {
        [owner invoke:args[@"callId"] payload:args budgetMs:[args[@"budgetMs"] unsignedIntegerValue] reply:^(id value, NSString *error) {
            result(error?MMError(error):value);
        }];return;
    }
    result(MMError(@"invalid_request"));
}
@end
