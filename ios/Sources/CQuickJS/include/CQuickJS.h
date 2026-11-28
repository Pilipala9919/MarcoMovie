/* Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only */
#ifndef CQUICKJS_UMBRELLA_H
#define CQUICKJS_UMBRELLA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if __has_include("quickjs.h")
#define MARCO_CQUICKJS_AVAILABLE 1
#include "quickjs.h"
#if __has_include("quickjs-libc.h")
#include "quickjs-libc.h"
#endif

static inline JSValue cquickjs_null(void) {
    return JS_NULL;
}

static inline JSValue cquickjs_undefined(void) {
    return JS_UNDEFINED;
}

static inline JSValue cquickjs_false(void) {
    return JS_FALSE;
}

static inline JSValue cquickjs_true(void) {
    return JS_TRUE;
}

static inline JSValue cquickjs_exception(void) {
    return JS_EXCEPTION;
}

static inline JSValue cquickjs_throw_plain_error(JSContext *ctx, const char *message) {
    return JS_ThrowPlainError(ctx, "%s", message ? message : "JavaScript runtime error");
}

static inline JSValue cquickjs_throw_type_error(JSContext *ctx, const char *message) {
    return JS_ThrowTypeError(ctx, "%s", message ? message : "JavaScript type error");
}
#else
#define MARCO_CQUICKJS_AVAILABLE 0
#error "QuickJS-NG headers not synced yet. Run `python3 ios/prepare_ios.py` first."
#endif

int marco_cquickjs_is_linked(void);

#endif /* CQUICKJS_UMBRELLA_H */
