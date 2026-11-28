// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
#import "MMCatpawNativeBridge.h"

#if defined(MARCO_HAS_CATPAW) && MARCO_HAS_CATPAW

#import <NodeMobile/NodeMobile.h>
#include <cstring>
#include <vector>

@implementation MMCatpawNativeBridge

static BOOL sStarted = NO;
static BOOL sExited = NO;
static NSString *sRuntimeRoot = nil;

+ (BOOL)isRuntimeAvailable {
    return YES;
}

+ (BOOL)startWithRoot:(NSString *)root
               script:(NSString *)script
                ready:(NSString *)ready
                error:(NSError * _Nullable * _Nullable)error {
    NSString *failure = nil;
    if (![root isKindOfClass:[NSString class]] || !root.isAbsolutePath ||
        ![script isKindOfClass:[NSString class]] || ![ready isKindOfClass:[NSString class]] ||
        ![script isEqualToString:[root stringByAppendingPathComponent:@"host.cjs"]] ||
        ![ready isEqualToString:[root stringByAppendingPathComponent:@"ready.json"]]) {
        failure = @"invalid_path";
    } else {
        @synchronized(self) {
            if (sExited || (sStarted && ![sRuntimeRoot isEqualToString:root])) {
                failure = @"restart_required";
            } else if (!sStarted) {
                [[NSFileManager defaultManager] removeItemAtPath:ready error:nil];
                [[NSFileManager defaultManager] removeItemAtPath:[root stringByAppendingPathComponent:@"rebind.json"]
                                                           error:nil];
                sRuntimeRoot = [root copy];
                sStarted = YES;
                NSArray<NSString *> *arguments = @[@"node", @"--jitless", script, root, ready, @"--embedded"];
                NSThread *thread = [[NSThread alloc] initWithBlock:^{
                    @autoreleasepool {
                        size_t totalBytes = 0;
                        for (NSString *arg in arguments) {
                            totalBytes += strlen(arg.UTF8String) + 1;
                        }
                        std::vector<char> buffer(totalBytes);
                        std::vector<char *> argv(arguments.count + 1, nullptr);
                        char *cursor = buffer.data();
                        for (NSUInteger i = 0; i < arguments.count; i++) {
                            argv[i] = cursor;
                            size_t len = strlen(arguments[i].UTF8String) + 1;
                            memcpy(cursor, arguments[i].UTF8String, len);
                            cursor += len;
                        }
                        node_start((int)arguments.count, argv.data());
                        @synchronized(self) {
                            sExited = YES;
                        }
                    }
                }];
                thread.stackSize = 8 * 1024 * 1024;
                thread.name = @"catpaw-node";
                [thread start];
            }
        }
    }

    if (failure && error) {
        *error = [NSError errorWithDomain:@"marco_movie.catpaw"
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: failure}];
    }
    return failure == nil;
}

+ (NSDictionary<NSString *, NSNumber *> *)status {
    @synchronized(self) {
        return @{
            @"started": @(sStarted),
            @"exited": @(sExited),
            @"available": @YES,
        };
    }
}

@end

#else

@implementation MMCatpawNativeBridge

+ (BOOL)isRuntimeAvailable {
    return NO;
}

+ (BOOL)startWithRoot:(NSString *)root
               script:(NSString *)script
                ready:(NSString *)ready
                error:(NSError * _Nullable * _Nullable)error {
    (void)root;
    (void)script;
    (void)ready;
    if (error) {
        *error = [NSError errorWithDomain:@"marco_movie.catpaw"
                                     code:2
                                 userInfo:@{
                                     NSLocalizedDescriptionKey: @"CatPaw NodeMobile runtime is unavailable in light-simulator mode"
                                 }];
    }
    return NO;
}

+ (NSDictionary<NSString *, NSNumber *> *)status {
    return @{
        @"started": @NO,
        @"exited": @NO,
        @"available": @NO,
    };
}

@end

#endif
