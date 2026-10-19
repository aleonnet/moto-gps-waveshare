// Included by LVGL's lv_assert.h in the native test build only: a failed
// LVGL assertion (e.g. a call on a deleted object) aborts the test process
// instead of halting forever in LVGL's default while(1).
#pragma once
#include <stdlib.h>
#undef LV_ASSERT_HANDLER
#define LV_ASSERT_HANDLER abort();
