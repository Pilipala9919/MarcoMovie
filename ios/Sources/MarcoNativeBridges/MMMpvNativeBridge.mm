// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
#import "MMMpvNativeBridge.h"
#import <TargetConditionals.h>

#if defined(MARCO_HAS_MPV) && MARCO_HAS_MPV && TARGET_OS_IOS

#define GLES_SILENCE_DEPRECATION
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <CoreVideo/CoreVideo.h>
#import <dlfcn.h>
#include <atomic>
#include <cmath>
#include <mutex>
#include <string>
#include <vector>
#include "CLibmpv.h"

#ifndef GL_BGRA
#define GL_BGRA 0x80E1
#endif

static const int kMpvRingSlots = 2;
static int kMpvRenderQueueKey = 0;

static void *MMMpvGetGLProcAddress(void *ctx, const char *name) {
    (void)ctx;
    if (!name || name[0] == '\0') {
        return NULL;
    }
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (sym) {
        return sym;
    }
    CFBundleRef glBundle = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengles"));
    if (glBundle) {
        CFStringRef cfName = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
        if (cfName) {
            sym = CFBundleGetFunctionPointerForName(glBundle, cfName);
            CFRelease(cfName);
            if (sym) {
                return sym;
            }
        }
    }
    return dlsym(RTLD_SELF, name);
}

static int MMClampDimension(CGFloat value, int fallback) {
    if (!std::isfinite(value) || value <= 0.0) {
        return fallback;
    }
    int px = (int)std::lround(value);
    if (px < 64) return 64;
    if (px > 3840) return 3840;
    return px;
}

@interface MMMpvNativeBridge () {
    mpv_handle *_mpv;
    mpv_render_context *_renderContext;
    EAGLContext *_eaglContext;
    CVOpenGLESTextureCacheRef _textureCache;
    CVPixelBufferRef _pixelBuffers[kMpvRingSlots];
    CVOpenGLESTextureRef _cvTextures[kMpvRingSlots];
    GLuint _fbos[kMpvRingSlots];
    int _bufferIndex;
    int _width;
    int _height;
    std::atomic<bool> _destroyed;
    std::atomic<bool> _renderPending;
    std::recursive_mutex _mpvMutex;
    std::mutex _callbackMutex;
    dispatch_queue_t _renderQueue;
    dispatch_semaphore_t _eventThreadExited;
    NSThread *_eventThread;
    void (^_onFrameReady)(CVPixelBufferRef pixelBuffer);
    void (^_onEvent)(NSString *eventName, NSDictionary<NSString *, id> *payload);
}
- (void)scheduleRenderFromCallback;
@end

static void MMMpvRenderUpdateCallback(void *cbCtx) {
    if (!cbCtx) {
        return;
    }
    MMMpvNativeBridge *bridge = (__bridge MMMpvNativeBridge *)cbCtx;
    [bridge scheduleRenderFromCallback];
}

@implementation MMMpvNativeBridge

+ (BOOL)isRuntimeAvailable {
    return YES;
}

- (nullable instancetype)initWithRenderSize:(CGSize)size {
    if ((self = [super init])) {
        _destroyed.store(false);
        _renderPending.store(false);
        _bufferIndex = 0;
        _width = MMClampDimension(size.width, 1280);
        _height = MMClampDimension(size.height, 720);
        for (int i = 0; i < kMpvRingSlots; i++) {
            _pixelBuffers[i] = NULL;
            _cvTextures[i] = NULL;
            _fbos[i] = 0;
        }
        _renderQueue = dispatch_queue_create("marco.mpv.native.render", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_renderQueue, &kMpvRenderQueueKey, &kMpvRenderQueueKey, NULL);
        _eventThreadExited = dispatch_semaphore_create(0);

        if (![self setupGLAndMpv]) {
            [self destroy];
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    [self destroy];
}

- (BOOL)setupGLAndMpv {
    _eaglContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!_eaglContext) {
        _eaglContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    }
    if (!_eaglContext) {
        return NO;
    }

    __block BOOL glOk = NO;
    dispatch_sync(_renderQueue, ^{
        if (![EAGLContext setCurrentContext:self->_eaglContext]) {
            return;
        }
        CVReturn cvStatus = CVOpenGLESTextureCacheCreate(
            kCFAllocatorDefault,
            NULL,
            self->_eaglContext,
            NULL,
            &self->_textureCache
        );
        if (cvStatus != kCVReturnSuccess || !self->_textureCache) {
            [EAGLContext setCurrentContext:nil];
            return;
        }
        glOk = [self rebuildFramebuffersOnRenderQueueWidth:self->_width height:self->_height];
        [EAGLContext setCurrentContext:nil];
    });
    if (!glOk) {
        return NO;
    }

    _mpv = mpv_create();
    if (!_mpv) {
        return NO;
    }

    mpv_set_option_string(_mpv, "vo", "libmpv");
    mpv_set_option_string(_mpv, "hwdec", "videotoolbox");
    mpv_set_option_string(_mpv, "hwdec-image-format", "nv12");
    mpv_set_option_string(_mpv, "ao", "audiounit");
    mpv_set_option_string(_mpv, "keep-open", "yes");
    mpv_set_option_string(_mpv, "idle", "yes");
    mpv_set_option_string(_mpv, "osc", "no");
    mpv_set_option_string(_mpv, "osd-level", "0");
    mpv_set_option_string(_mpv, "ytdl", "no");
    mpv_set_option_string(_mpv, "audio-client-name", "Marco Movie");
    mpv_set_option_string(_mpv, "video-timing-offset", "0");

    if (mpv_initialize(_mpv) < 0) {
        return NO;
    }

    mpv_observe_property(_mpv, 1, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(_mpv, 2, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(_mpv, 3, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(_mpv, 4, "paused-for-cache", MPV_FORMAT_FLAG);
    mpv_observe_property(_mpv, 5, "eof-reached", MPV_FORMAT_FLAG);
    mpv_observe_property(_mpv, 6, "video-params/w", MPV_FORMAT_INT64);
    mpv_observe_property(_mpv, 7, "video-params/h", MPV_FORMAT_INT64);
    mpv_observe_property(_mpv, 8, "track-list", MPV_FORMAT_STRING);
    mpv_observe_property(_mpv, 9, "cache-buffering-state", MPV_FORMAT_INT64);
    mpv_observe_property(_mpv, 10, "demuxer-cache-duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(_mpv, 11, "aid", MPV_FORMAT_STRING);
    mpv_observe_property(_mpv, 12, "sid", MPV_FORMAT_STRING);
    mpv_observe_property(_mpv, 13, "speed", MPV_FORMAT_DOUBLE);

    __block int rcStatus = -1;
    dispatch_sync(_renderQueue, ^{
        if (![EAGLContext setCurrentContext:self->_eaglContext]) {
            return;
        }
        mpv_opengl_init_params glInit = {
            .get_proc_address = MMMpvGetGLProcAddress,
            .get_proc_address_ctx = NULL,
        };
        mpv_render_param params[] = {
            { MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL },
            { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &glInit },
            { MPV_RENDER_PARAM_INVALID, NULL },
        };
        rcStatus = mpv_render_context_create(&self->_renderContext, self->_mpv, params);
        if (rcStatus >= 0 && self->_renderContext) {
            mpv_render_context_set_update_callback(
                self->_renderContext,
                MMMpvRenderUpdateCallback,
                (__bridge void *)self
            );
        }
        [EAGLContext setCurrentContext:nil];
    });
    if (rcStatus < 0 || !_renderContext) {
        return NO;
    }

    _eventThread = [[NSThread alloc] initWithTarget:self selector:@selector(eventLoopMain) object:nil];
    _eventThread.name = @"marco-mpv-events";
    [_eventThread start];
    return YES;
}

- (void)releaseFramebuffersOnRenderQueue {
    for (int i = 0; i < kMpvRingSlots; i++) {
        if (_fbos[i] != 0) {
            glDeleteFramebuffers(1, &_fbos[i]);
            _fbos[i] = 0;
        }
        if (_cvTextures[i]) {
            CFRelease(_cvTextures[i]);
            _cvTextures[i] = NULL;
        }
        if (_pixelBuffers[i]) {
            CVPixelBufferRelease(_pixelBuffers[i]);
            _pixelBuffers[i] = NULL;
        }
    }
    if (_textureCache) {
        CVOpenGLESTextureCacheFlush(_textureCache, 0);
    }
}

- (BOOL)rebuildFramebuffersOnRenderQueueWidth:(int)width height:(int)height {
    [self releaseFramebuffersOnRenderQueue];
    _width = width;
    _height = height;
    _bufferIndex = 0;

    NSDictionary *pbAttrs = @{
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    for (int i = 0; i < kMpvRingSlots; i++) {
        CVReturn status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            (size_t)width,
            (size_t)height,
            kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)pbAttrs,
            &_pixelBuffers[i]
        );
        if (status != kCVReturnSuccess || !_pixelBuffers[i]) {
            [self releaseFramebuffersOnRenderQueue];
            return NO;
        }

        status = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            _textureCache,
            _pixelBuffers[i],
            NULL,
            GL_TEXTURE_2D,
            GL_RGBA,
            width,
            height,
            GL_BGRA,
            GL_UNSIGNED_BYTE,
            0,
            &_cvTextures[i]
        );
        if (status != kCVReturnSuccess || !_cvTextures[i]) {
            [self releaseFramebuffersOnRenderQueue];
            return NO;
        }

        GLuint texName = CVOpenGLESTextureGetName(_cvTextures[i]);
        glBindTexture(GL_TEXTURE_2D, texName);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        glGenFramebuffers(1, &_fbos[i]);
        glBindFramebuffer(GL_FRAMEBUFFER, _fbos[i]);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texName, 0);
        GLenum fbStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glBindTexture(GL_TEXTURE_2D, 0);

        if (fbStatus != GL_FRAMEBUFFER_COMPLETE) {
            [self releaseFramebuffersOnRenderQueue];
            return NO;
        }
    }
    return YES;
}

- (void)scheduleRenderFromCallback {
    if (_destroyed.load()) {
        return;
    }
    bool expected = false;
    if (!_renderPending.compare_exchange_strong(expected, true)) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(_renderQueue, ^{
        MMMpvNativeBridge *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_renderPending.store(false);
        [strongSelf renderOnRenderQueue];
    });
}

- (void)renderOnRenderQueue {
    if (_destroyed.load() || !_renderContext || !_eaglContext) {
        return;
    }
    if (![EAGLContext setCurrentContext:_eaglContext]) {
        return;
    }

    uint64_t updateFlags = mpv_render_context_update(_renderContext);
    if ((updateFlags & MPV_RENDER_UPDATE_FRAME) == 0) {
        return;
    }

    int slot = _bufferIndex;
    if (_fbos[slot] == 0 || !_pixelBuffers[slot]) {
        return;
    }

    mpv_opengl_fbo fbo = {
        .fbo = (int)_fbos[slot],
        .w = _width,
        .h = _height,
        .internal_format = 0,
    };
    int flipY = 1;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &fbo },
        { MPV_RENDER_PARAM_FLIP_Y, &flipY },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };

    int err = mpv_render_context_render(_renderContext, params);
    glFlush();
    mpv_render_context_report_swap(_renderContext);

    if (err >= 0) {
        _bufferIndex = (slot + 1) % kMpvRingSlots;
        void (^handler)(CVPixelBufferRef) = nil;
        {
            std::lock_guard<std::mutex> guard(_callbackMutex);
            handler = _onFrameReady;
        }
        if (handler) {
            CVPixelBufferRef pb = CVPixelBufferRetain(_pixelBuffers[slot]);
            handler(pb);
            CVPixelBufferRelease(pb);
        }
    }
}

- (void)emitEvent:(NSString *)eventName payload:(NSDictionary<NSString *, id> *)payload {
    void (^handler)(NSString *, NSDictionary<NSString *, id> *) = nil;
    {
        std::lock_guard<std::mutex> guard(_callbackMutex);
        handler = _onEvent;
    }
    if (!handler) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(eventName, payload);
    });
}

- (void)eventLoopMain {
    @autoreleasepool {
        while (!_destroyed.load() && _mpv != NULL) {
            mpv_event *ev = mpv_wait_event(_mpv, 0.25);
            if (!ev || ev->event_id == MPV_EVENT_NONE) {
                continue;
            }
            if (_destroyed.load()) {
                break;
            }
            @autoreleasepool {
                switch (ev->event_id) {
                    case MPV_EVENT_START_FILE:
                        [self emitEvent:@"start-file" payload:@{}];
                        break;
                    case MPV_EVENT_FILE_LOADED:
                        [self emitEvent:@"file-loaded" payload:@{}];
                        break;
                    case MPV_EVENT_PLAYBACK_RESTART:
                        [self emitEvent:@"playback-restart" payload:@{}];
                        break;
                    case MPV_EVENT_SEEK:
                        [self emitEvent:@"seek" payload:@{}];
                        break;
                    case MPV_EVENT_VIDEO_RECONFIG:
                        [self emitEvent:@"video-reconfig" payload:@{}];
                        break;
                    case MPV_EVENT_AUDIO_RECONFIG:
                        [self emitEvent:@"audio-reconfig" payload:@{}];
                        break;
                    case MPV_EVENT_END_FILE: {
                        NSMutableDictionary<NSString *, id> *payload = [NSMutableDictionary dictionary];
                        if (ev->data) {
                            const mpv_event_end_file *ef = (const mpv_event_end_file *)ev->data;
                            payload[@"reason"] = @((int)ef->reason);
                            payload[@"error"] = @(ef->error);
                            const char *errText = mpv_error_string(ef->error);
                            if (errText) {
                                payload[@"errorString"] = [NSString stringWithUTF8String:errText];
                            }
                        }
                        [self emitEvent:@"end-file" payload:payload];
                        break;
                    }
                    case MPV_EVENT_PROPERTY_CHANGE: {
                        if (ev->data) {
                            const mpv_event_property *prop = (const mpv_event_property *)ev->data;
                            NSString *propName = prop->name ? [NSString stringWithUTF8String:prop->name] : @"";
                            NSMutableDictionary<NSString *, id> *payload = [NSMutableDictionary dictionary];
                            payload[@"name"] = propName;
                            if (prop->data) {
                                switch (prop->format) {
                                    case MPV_FORMAT_DOUBLE:
                                        payload[@"value"] = @(*(const double *)prop->data);
                                        break;
                                    case MPV_FORMAT_INT64:
                                        payload[@"value"] = @(*(const int64_t *)prop->data);
                                        break;
                                    case MPV_FORMAT_FLAG:
                                        payload[@"value"] = @((*(const int *)prop->data) != 0);
                                        break;
                                    case MPV_FORMAT_STRING:
                                    case MPV_FORMAT_OSD_STRING: {
                                        const char *strVal = *(const char * const *)prop->data;
                                        if (strVal) {
                                            payload[@"value"] = [NSString stringWithUTF8String:strVal];
                                        }
                                        break;
                                    }
                                    default:
                                        break;
                                }
                            }
                            [self emitEvent:@"property-change" payload:payload];
                        }
                        break;
                    }
                    case MPV_EVENT_LOG_MESSAGE: {
                        if (ev->data) {
                            const mpv_event_log_message *msg = (const mpv_event_log_message *)ev->data;
                            [self emitEvent:@"log-message" payload:@{
                                @"prefix": msg->prefix ? [NSString stringWithUTF8String:msg->prefix] : @"",
                                @"level": msg->level ? [NSString stringWithUTF8String:msg->level] : @"",
                                @"text": msg->text ? [NSString stringWithUTF8String:msg->text] : @"",
                            }];
                        }
                        break;
                    }
                    case MPV_EVENT_SHUTDOWN:
                        [self emitEvent:@"shutdown" payload:@{}];
                        goto exit_loop;
                    default:
                        break;
                }
            }
        }
    exit_loop:
        dispatch_semaphore_signal(_eventThreadExited);
    }
}

#pragma mark - Public Control API

- (void)setOptionString:(NSString *)name value:(NSString *)value {
    std::lock_guard<std::recursive_mutex> guard(_mpvMutex);
    if (_destroyed.load() || !_mpv || !name || !value) return;
    mpv_set_option_string(_mpv, name.UTF8String, value.UTF8String);
}

- (void)setPropertyString:(NSString *)name value:(NSString *)value {
    std::lock_guard<std::recursive_mutex> guard(_mpvMutex);
    if (_destroyed.load() || !_mpv || !name || !value) return;
    mpv_set_property_string(_mpv, name.UTF8String, value.UTF8String);
}

- (nullable NSString *)getPropertyString:(NSString *)name {
    std::lock_guard<std::recursive_mutex> guard(_mpvMutex);
    if (_destroyed.load() || !_mpv || !name) return nil;
    char *raw = mpv_get_property_string(_mpv, name.UTF8String);
    if (!raw) return nil;
    NSString *result = [NSString stringWithUTF8String:raw];
    mpv_free(raw);
    return result;
}

- (double)getPropertyDouble:(NSString *)name defaultValue:(double)defaultValue {
    std::lock_guard<std::recursive_mutex> guard(_mpvMutex);
    if (_destroyed.load() || !_mpv || !name) return defaultValue;
    double value = defaultValue;
    if (mpv_get_property(_mpv, name.UTF8String, MPV_FORMAT_DOUBLE, &value) < 0) {
        return defaultValue;
    }
    return value;
}

- (BOOL)getPropertyFlag:(NSString *)name defaultValue:(BOOL)defaultValue {
    std::lock_guard<std::recursive_mutex> guard(_mpvMutex);
    if (_destroyed.load() || !_mpv || !name) return defaultValue;
    int flag = defaultValue ? 1 : 0;
    if (mpv_get_property(_mpv, name.UTF8String, MPV_FORMAT_FLAG, &flag) < 0) {
        return defaultValue;
    }
    return flag != 0;
}

- (void)command:(NSArray<NSString *> *)args {
    std::lock_guard<std::recursive_mutex> guard(_mpvMutex);
    if (_destroyed.load() || !_mpv || args.count == 0) return;
    std::vector<std::string> storage;
    storage.reserve(args.count);
    std::vector<const char *> cargs;
    cargs.reserve(args.count + 1);
    for (NSString *arg in args) {
        storage.emplace_back(arg.UTF8String ?: "");
        cargs.push_back(storage.back().c_str());
    }
    cargs.push_back(NULL);
    mpv_command_async(_mpv, 0, cargs.data());
}

- (void)setOnFrameReady:(void (^ _Nullable)(CVPixelBufferRef))handler {
    std::lock_guard<std::mutex> guard(_callbackMutex);
    _onFrameReady = [handler copy];
}

- (void)setOnEvent:(void (^ _Nullable)(NSString *, NSDictionary<NSString *, id> *))handler {
    std::lock_guard<std::mutex> guard(_callbackMutex);
    _onEvent = [handler copy];
}

- (void)resizeDrawable:(CGSize)size {
    int newW = MMClampDimension(size.width, _width);
    int newH = MMClampDimension(size.height, _height);
    __weak typeof(self) weakSelf = self;
    dispatch_async(_renderQueue, ^{
        MMMpvNativeBridge *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_destroyed.load() || !strongSelf->_eaglContext) return;
        if (strongSelf->_width == newW && strongSelf->_height == newH) return;
        if ([EAGLContext setCurrentContext:strongSelf->_eaglContext]) {
            [strongSelf rebuildFramebuffersOnRenderQueueWidth:newW height:newH];
            [strongSelf renderOnRenderQueue];
        }
    });
}

- (void)renderIfNeeded {
    if (_destroyed.load()) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(_renderQueue, ^{
        MMMpvNativeBridge *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf renderOnRenderQueue];
    });
}

- (void)destroy {
    bool expected = false;
    if (!_destroyed.compare_exchange_strong(expected, true)) {
        return;
    }

    {
        std::lock_guard<std::mutex> guard(_callbackMutex);
        _onFrameReady = nil;
        _onEvent = nil;
    }

    mpv_handle *mpvToDestroy = NULL;
    {
        std::lock_guard<std::recursive_mutex> guard(_mpvMutex);
        if (_mpv) {
            mpv_wakeup(_mpv);
        }
    }

    if (_eventThread) {
        dispatch_semaphore_wait(_eventThreadExited, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
        _eventThread = nil;
    }

    if (_renderQueue) {
        dispatch_block_t glCleanup = ^{
            if (self->_eaglContext) {
                [EAGLContext setCurrentContext:self->_eaglContext];
            }
            if (self->_renderContext) {
                mpv_render_context_set_update_callback(self->_renderContext, NULL, NULL);
                mpv_render_context_free(self->_renderContext);
                self->_renderContext = NULL;
            }
            [self releaseFramebuffersOnRenderQueue];
            if (self->_textureCache) {
                CFRelease(self->_textureCache);
                self->_textureCache = NULL;
            }
            [EAGLContext setCurrentContext:nil];
            self->_eaglContext = nil;
        };
        if (dispatch_get_specific(&kMpvRenderQueueKey) == &kMpvRenderQueueKey) {
            glCleanup();
        } else {
            dispatch_sync(_renderQueue, glCleanup);
        }
    }

    {
        std::lock_guard<std::recursive_mutex> guard(_mpvMutex);
        mpvToDestroy = _mpv;
        _mpv = NULL;
    }
    if (mpvToDestroy) {
        mpv_terminate_destroy(mpvToDestroy);
    }
}

@end

#else

// ============================================================================
// Light-Simulator / Non-MPV Stub Implementation
// ============================================================================

@implementation MMMpvNativeBridge

+ (BOOL)isRuntimeAvailable {
    return NO;
}

- (nullable instancetype)initWithRenderSize:(CGSize)size {
    (void)size;
    return nil;
}

- (void)setOptionString:(NSString *)name value:(NSString *)value {
    (void)name;
    (void)value;
}

- (void)setPropertyString:(NSString *)name value:(NSString *)value {
    (void)name;
    (void)value;
}

- (nullable NSString *)getPropertyString:(NSString *)name {
    (void)name;
    return nil;
}

- (double)getPropertyDouble:(NSString *)name defaultValue:(double)defaultValue {
    (void)name;
    return defaultValue;
}

- (BOOL)getPropertyFlag:(NSString *)name defaultValue:(BOOL)defaultValue {
    (void)name;
    return defaultValue;
}

- (void)command:(NSArray<NSString *> *)args {
    (void)args;
}

- (void)setOnFrameReady:(void (^ _Nullable)(CVPixelBufferRef))handler {
    (void)handler;
}

- (void)setOnEvent:(void (^ _Nullable)(NSString *, NSDictionary<NSString *, id> *))handler {
    (void)handler;
}

- (void)resizeDrawable:(CGSize)size {
    (void)size;
}

- (void)renderIfNeeded {
}

- (void)destroy {
}

@end

#endif
