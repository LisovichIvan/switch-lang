#include "AtomicSupport.h"
#include <stdatomic.h>
#include <stdlib.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_LONG_LOCK_FREE == 2,
               "The event callback requires lock-free 64-bit atomics");

struct SwitchLangAtomicUInt64 { _Atomic uint64_t value; };

SwitchLangAtomicUInt64 *switch_lang_atomic_create(uint64_t initial) {
    SwitchLangAtomicUInt64 *result = malloc(sizeof(*result));
    if (result != NULL) atomic_init(&result->value, initial);
    return result;
}

// SAFETY: Swift's single owner destroys the cell only after listener/worker
// shutdown. Every other operation borrows that live, non-null allocation.
void switch_lang_atomic_destroy(SwitchLangAtomicUInt64 *value) { free(value); }
uint64_t switch_lang_atomic_load(const SwitchLangAtomicUInt64 *value) {
    return atomic_load_explicit(&value->value, memory_order_seq_cst);
}
void switch_lang_atomic_store(SwitchLangAtomicUInt64 *value, uint64_t desired) {
    atomic_store_explicit(&value->value, desired, memory_order_seq_cst);
}
uint64_t switch_lang_atomic_exchange(SwitchLangAtomicUInt64 *value, uint64_t desired) {
    return atomic_exchange_explicit(&value->value, desired, memory_order_seq_cst);
}
uint64_t switch_lang_atomic_fetch_add(SwitchLangAtomicUInt64 *value, uint64_t amount) {
    return atomic_fetch_add_explicit(&value->value, amount, memory_order_seq_cst);
}
uint64_t switch_lang_atomic_fetch_or(SwitchLangAtomicUInt64 *value, uint64_t bits) {
    return atomic_fetch_or_explicit(&value->value, bits, memory_order_seq_cst);
}
bool switch_lang_atomic_compare_exchange(SwitchLangAtomicUInt64 *value, uint64_t expected, uint64_t desired) {
    return atomic_compare_exchange_strong_explicit(&value->value, &expected, desired,
        memory_order_seq_cst, memory_order_seq_cst);
}
