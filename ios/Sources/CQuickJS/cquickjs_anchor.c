/* Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only */
#include "include/CQuickJS.h"

int marco_cquickjs_is_linked(void) {
#if MARCO_CQUICKJS_AVAILABLE
    return 1;
#else
    return 0;
#endif
}
