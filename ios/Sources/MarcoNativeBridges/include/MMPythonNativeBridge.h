// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Zero-Flutter native CPython 3.14 runtime bridge with per-session own-GIL
/// subinterpreters and ephemeral URLSession HTTP transport.
@interface MMPythonNativeBridge : NSObject

+ (BOOL)isRuntimeAvailable;

+ (NSDictionary<NSString *, id> *)capabilities;

+ (void)openSessionWithSessionId:(NSString *)sessionId
                    packageFiles:(NSDictionary<NSString *, NSData *> *)packageFiles
                     entryModule:(NSString *)entryModule
                    proxyBaseURL:(nullable NSString *)proxyBaseURL
                      completion:(void (^)(NSDictionary<NSString *, id> * _Nullable result,
                                           NSError * _Nullable error))completion;

+ (void)openSessionWithSessionId:(NSString *)sessionId
                    packageFiles:(NSDictionary<NSString *, NSData *> *)packageFiles
                     entryModule:(NSString *)entryModule
                       extension:(NSString *)extension
                    proxyBaseURL:(nullable NSString *)proxyBaseURL
                remoteDescriptor:(nullable NSDictionary<NSString *, id> *)remoteDescriptor
                      completion:(void (^)(NSDictionary<NSString *, id> * _Nullable result,
                                           NSError * _Nullable error))completion;

+ (void)callSessionWithSessionId:(NSString *)sessionId
                          callId:(NSString *)callId
                          method:(NSString *)method
                   argumentsJSON:(NSString *)argumentsJSON
                       timeoutMs:(NSInteger)timeoutMs
                      completion:(void (^)(NSString * _Nullable jsonResult,
                                           NSError * _Nullable error))completion;

+ (void)cancelCallWithSessionId:(NSString *)sessionId
                         callId:(NSString *)callId;

+ (void)closeSessionWithSessionId:(NSString *)sessionId
                       completion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
