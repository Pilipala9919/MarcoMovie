// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Zero-Flutter hardware-accelerated libmpv bridge producing IOSurface/Metal-compatible
/// CVPixelBuffer frames for zero-copy CAMetalLayer presentation.
@interface MMMpvNativeBridge : NSObject

+ (BOOL)isRuntimeAvailable;

- (nullable instancetype)initWithRenderSize:(CGSize)size;

- (void)setOptionString:(NSString *)name value:(NSString *)value;
- (void)setPropertyString:(NSString *)name value:(NSString *)value;
- (nullable NSString *)getPropertyString:(NSString *)name;
- (double)getPropertyDouble:(NSString *)name defaultValue:(double)defaultValue;
- (BOOL)getPropertyFlag:(NSString *)name defaultValue:(BOOL)defaultValue;
- (void)command:(NSArray<NSString *> *)args;

- (void)setOnFrameReady:(void (^ _Nullable)(CVPixelBufferRef pixelBuffer))handler;
- (void)setOnEvent:(void (^ _Nullable)(NSString *eventName, NSDictionary<NSString *, id> *payload))handler;

- (void)resizeDrawable:(CGSize)size;
- (void)renderIfNeeded;
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
