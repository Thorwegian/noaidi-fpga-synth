// external_heap.hpp — a scope in which malloc() places every block in the PSRAM
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#pragma once

#include "esp_heap_caps.h"
#include "sdkconfig.h"

// While one of these lives, malloc() places every block in the PSRAM, the
// small ones too: the graph and what its build needs, which the internal
// RAM has no room for beside the firmware's own
// (docs.espressif.com, "Support for External RAM": the size limit under
// which a block goes to internal memory first).
class ExternalHeap {
public:
    ExternalHeap() {
        heap_caps_malloc_extmem_enable(0);
    }
    ~ExternalHeap() {
        heap_caps_malloc_extmem_enable(CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL);
    }
    ExternalHeap(const ExternalHeap &)            = delete;
    ExternalHeap &operator=(const ExternalHeap &) = delete;
};
