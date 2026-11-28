/* Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only */
#include "include/CLibmpv.h"

int marco_clibmpv_is_linked(void) {
#if defined(MARCO_HAS_MPV) && MARCO_HAS_MPV
    return 1;
#else
    return 0;
#endif
}
