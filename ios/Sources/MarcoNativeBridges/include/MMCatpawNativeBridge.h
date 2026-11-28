// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Zero-Flutter embedded NodeMobile (--jitless) runtime host for CatPaw/DRPY2.
@interface MMCatpawNativeBridge : NSObject

+ (BOOL)isRuntimeAvailable;

+ (BOOL)startWithRoot:(NSString *)root
               script:(NSString *)script
                ready:(NSString *)ready
                error:(NSError * _Nullable * _Nullable)error;

+ (NSDictionary<NSString *, NSNumber *> *)status;

@end

NS_ASSUME_NONNULL_END
