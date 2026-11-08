#import "MMPythonOwner.h"
#include <pthread.h>

@interface MMOwnedCall : NSObject
@property(nonatomic,copy) NSString *identity;
@property(nonatomic,copy) NSDictionary *payload;
@property(nonatomic,copy) MMPythonReply reply;
@property(nonatomic,assign) double deadline;
@property(nonatomic,assign) BOOL cancelled;
@end
@implementation MMOwnedCall
@end

@interface MMPythonOwner ()
@property(nonatomic,assign) PyInterpreterState *mainInterpreter;
@property(nonatomic,copy,nullable) MMPythonCreate create;
@property(nonatomic,copy,nullable) MMPythonInvoke invokeSource;
@property(nonatomic,copy,nullable) MMPythonDispose disposeSource;
@property(nonatomic,copy) void (^interrupt)(NSString *);
@property(nonatomic,strong) NSCondition *condition;
@property(nonatomic,strong) NSMutableArray<MMOwnedCall *> *queue;
@property(nonatomic,strong) NSMutableArray *closeReplies;
@property(nonatomic,strong,nullable) MMOwnedCall *running;
@property(nonatomic,strong,nullable) NSThread *worker;
@property(nonatomic,copy,nullable) MMPythonReply openingReply;
@property(nonatomic,assign) BOOL started;
@property(nonatomic,assign) BOOL ready;
@property(nonatomic,assign) BOOL closing;
@property(nonatomic,assign) BOOL finished;
@property(nonatomic,assign) uint64_t workerIdentity;
@property(nonatomic,assign) int64_t interpreterIdentity;
@end

static void MMReply(MMPythonReply reply, id value, NSString *error) {
    // The payload is Foundation data only; no Python object leaves its owner.
    dispatch_async(dispatch_get_main_queue(), ^{ reply(value,error); });
}

static BOOL MMCallIdentity(NSString *value) {
    return [value isKindOfClass:NSString.class] && value.length==32 &&
        [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location==NSNotFound;
}

@implementation MMPythonOwner
- (instancetype)initWithMainInterpreter:(PyInterpreterState *)mainInterpreter
                                create:(MMPythonCreate)create invoke:(MMPythonInvoke)invoke
                               dispose:(MMPythonDispose)dispose interrupt:(void (^)(NSString *))interrupt {
    if ((self=[super init])) {
        _mainInterpreter=mainInterpreter;_create=[create copy];_invokeSource=[invoke copy];
        _disposeSource=[dispose copy];_interrupt=[interrupt copy];
        _condition=[NSCondition new];_queue=[NSMutableArray array];_closeReplies=[NSMutableArray array];
        _interpreterIdentity=-1;
    }
    return self;
}

- (void)start:(MMPythonReply)reply {
    [self.condition lock];
    if (self.started || self.finished || self.closing || !self.mainInterpreter) {
        [self.condition unlock];MMReply(reply,nil,@"runtime_unavailable");return;
    }
    self.started=YES;self.openingReply=[reply copy];
    self.worker=[[NSThread alloc] initWithTarget:self selector:@selector(workerMain) object:nil];
    self.worker.name=@"native-python-source-owner";self.worker.stackSize=8*1024*1024;
    [self.worker start];[self.condition unlock];
}

- (NSDictionary *)snapshot {
    [self.condition lock];
    NSDictionary *value=@{@"state":self.finished?@"closed":self.closing?@"closing":self.running?@"running":self.ready?@"idle":@"opening",
        @"pending":@(self.queue.count+(self.running?1:0)),@"thread":@(self.workerIdentity),
        @"interpreter":@(self.interpreterIdentity),@"finished":@(self.finished),
        @"activeCall":self.running.identity?:@""};
    [self.condition unlock];return value;
}

- (void)invoke:(NSString *)callId payload:(NSDictionary *)payload budgetMs:(NSUInteger)budgetMs reply:(MMPythonReply)reply {
    if (!MMCallIdentity(callId) || budgetMs<1 || budgetMs>45000 || ![payload isKindOfClass:NSDictionary.class]) {
        MMReply(reply,nil,@"invalid_request");return;
    }
    // Copy bounded JSON before queueing, without sharing mutable channel values.
    NSData *data=nil;NSDictionary *copy=nil;
    @try {
        data=[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (data && data.length<=64*1024) copy=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    } @catch(NSException *exception) { (void)exception; }
    if (!copy) { MMReply(reply,nil,@"invalid_request");return; }
    MMOwnedCall *call=[MMOwnedCall new];call.identity=callId;call.payload=copy;call.reply=reply;
    call.deadline=NSProcessInfo.processInfo.systemUptime+budgetMs/1000.0;
    [self.condition lock];NSString *error=nil;
    if (!self.ready || self.closing || self.finished) error=@"invalid_handle";
    else if (self.queue.count+(self.running?1:0)>=4) error=@"runtime_limit";
    else {
        if ([self.running.identity isEqualToString:callId]) error=@"invalid_request";
        for (MMOwnedCall *pending in self.queue) if ([pending.identity isEqualToString:callId]) error=@"invalid_request";
    }
    if (!error) { [self.queue addObject:call];[self.condition signal]; }
    [self.condition unlock];
    if (error) MMReply(reply,nil,error);
}

- (NSString *)cancel:(NSString *)callId {
    [self.condition lock];MMOwnedCall *removed=nil;
    BOOL active=self.running && [self.running.identity isEqualToString:callId];
    if (active) self.running.cancelled=YES;
    else for (MMOwnedCall *call in self.queue) {
        if ([call.identity isEqualToString:callId]) { removed=call;break; }
    }
    if (removed) { removed.cancelled=YES;[self.queue removeObjectIdenticalTo:removed]; }
    [self.condition unlock];
    if (active) self.interrupt(callId);
    if (removed) MMReply(removed.reply,nil,@"cancelled");
    return active?@"active":removed?@"queued":@"absent";
}

- (void)close:(MMPythonReply)reply {
    [self.condition lock];
    if (self.finished) { [self.condition unlock];MMReply(reply,@YES,nil);return; }
    [self.closeReplies addObject:[reply copy]];self.closing=YES;
    NSArray<MMOwnedCall *> *removed=[self.queue copy];[self.queue removeAllObjects];
    NSString *active=self.running.identity;self.running.cancelled=YES;
    [self.condition signal];BOOL unstarted=!self.started;[self.condition unlock];
    if (active) self.interrupt(active);
    for (MMOwnedCall *call in removed) MMReply(call.reply,nil,@"cancelled");
    if (unstarted) [self finishWithOpenError:@"cancelled"];
}

- (void)finishWithOpenError:(NSString *)error {
    [self.condition lock];self.finished=YES;self.ready=NO;self.closing=YES;
    MMPythonReply opening=self.openingReply;self.openingReply=nil;
    NSArray *replies=[self.closeReplies copy];[self.closeReplies removeAllObjects];
    self.worker=nil;self.create=nil;self.invokeSource=nil;self.disposeSource=nil;
    [self.condition unlock];
    if (opening) MMReply(opening,nil,error?:@"python_error");
    for (MMPythonReply reply in replies) MMReply(reply,@YES,nil);
}

- (void)workerMain {
    @autoreleasepool {
        uint64_t thread=0;pthread_threadid_np(NULL,&thread);
        [self.condition lock];self.workerIdentity=thread;[self.condition unlock];
        // A fresh native thread creates its own main-interpreter bootstrap state.
        // No PyGILState_* calls and no thread state is migrated between OS threads.
        PyThreadState *bootstrap=PyThreadState_New(self.mainInterpreter);
        if (!bootstrap) { [self finishWithOpenError:@"runtime_unavailable"];return; }
        PyThreadState_Swap(bootstrap);
        PyInterpreterConfig config={};config.use_main_obmalloc=0;config.allow_fork=0;
        config.allow_exec=0;config.allow_threads=0;config.allow_daemon_threads=0;
        config.check_multi_interp_extensions=1;config.gil=PyInterpreterConfig_OWN_GIL;
        PyThreadState *state=NULL;PyStatus status=Py_NewInterpreterFromConfig(&state,&config);
        if (PyStatus_Exception(status)) {
            if (!PyThreadState_GetUnchecked()) PyThreadState_Swap(bootstrap);
            PyErr_Clear();PyThreadState_Clear(bootstrap);PyThreadState_DeleteCurrent();
            [self finishWithOpenError:@"runtime_unavailable"];return;
        }
        [self.condition lock];self.interpreterIdentity=PyInterpreterState_GetID(PyThreadState_GetInterpreter(state));
        BOOL closing=self.closing;[self.condition unlock];
        PyObject *source=NULL;
        if (!closing) source=self.create();
        NSString *openError=closing?@"cancelled":source?nil:@"python_error";
        if (PyErr_Occurred()) { PyErr_Clear();openError=@"python_error"; }
        if (!openError) {
            state=PyEval_SaveThread();
            [self.condition lock];self.ready=!self.closing;
            closing=self.closing;
            // An opening cancellation is not settled until Py_EndInterpreter.
            MMPythonReply opening=closing?nil:self.openingReply;
            if (!closing) self.openingReply=nil;
            [self.condition unlock];
            if (closing) openError=@"cancelled";
            if (opening) MMReply(opening,@YES,nil);
            while (YES) {
                @autoreleasepool {
                    [self.condition lock];
                    while (!self.closing && self.queue.count==0) [self.condition wait];
                    if (self.closing) { [self.condition unlock];break; }
                    MMOwnedCall *call=self.queue.firstObject;[self.queue removeObjectAtIndex:0];self.running=call;
                    [self.condition unlock];
                    id value=nil;NSString *error=nil;
                    if (NSProcessInfo.processInfo.systemUptime>=call.deadline) error=@"timeout";
                    else {
                        PyEval_RestoreThread(state);
                        NSUInteger remaining=(NSUInteger)MAX(1.0,(call.deadline-NSProcessInfo.processInfo.systemUptime)*1000.0);
                        value=self.invokeSource(source,call.payload,remaining);
                        if (!value || PyErr_Occurred()) { PyErr_Clear();error=@"python_error";value=nil; }
                        state=PyEval_SaveThread();
                    }
                    [self.condition lock];
                    if (call.cancelled || self.closing) { value=nil;error=@"cancelled"; }
                    else if (NSProcessInfo.processInfo.systemUptime>=call.deadline) { value=nil;error=@"timeout"; }
                    self.running=nil;[self.condition unlock];
                    MMReply(call.reply,value,error);
                }
            }
            PyEval_RestoreThread(state);
        }
        // All cleanup executes on this owner's thread, only after the running
        // callback has returned. A blocked C call never reaches this point early.
        if (source) { self.disposeSource(source);PyErr_Clear();Py_DECREF(source); }
        Py_EndInterpreter(state);
        PyThreadState_Swap(bootstrap);PyThreadState_Clear(bootstrap);PyThreadState_DeleteCurrent();
        [self finishWithOpenError:openError];
    }
}
@end
