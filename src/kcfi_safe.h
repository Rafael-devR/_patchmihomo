/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef DROID_LKM_KCFI_SAFE_H
#define DROID_LKM_KCFI_SAFE_H

#include <linux/version.h>

#ifdef __clang__
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)
#undef __nocfi
#define __nocfi __attribute__((__no_sanitize__("cfi", "kcfi")))
#else
#undef __nocfi
#define __nocfi __attribute__((__no_sanitize__("cfi")))
#endif
#endif

#endif
