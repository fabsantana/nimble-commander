#pragma once

#include <mach/mach.h>
#include <atomic>
#include <mutex>

class spinlock
{
    std::atomic_flag __flag = ATOMIC_FLAG_INIT ;
public:
    inline void lock() noexcept {
        while( __flag.test_and_set(std::memory_order_acquire) ) {
            swtch_pri(0); // talking to Mach directly
        }
    }
    inline void unlock() noexcept {
        __flag.clear(std::memory_order_release);
    }
};

#define __LOCK_GUARD_TOKENPASTE(x, y) x ## y
#define __LOCK_GUARD_TOKENPASTE2(x, y) __LOCK_GUARD_TOKENPASTE(x, y)
#define LOCK_GUARD(lock_object) int __LOCK_GUARD_TOKENPASTE2(__lock_guard_runs_, __LINE__) = 1; \
    for(std::lock_guard<decltype(lock_object)> __LOCK_GUARD_TOKENPASTE2(__lock_guard_, __LINE__)(lock_object); \
        __LOCK_GUARD_TOKENPASTE2(__lock_guard_runs_, __LINE__) != 0; \
        --__LOCK_GUARD_TOKENPASTE2(__lock_guard_runs_, __LINE__) \
        )
