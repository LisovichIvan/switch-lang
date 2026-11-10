#ifndef SWITCH_LANG_ATOMIC_SUPPORT_H
#define SWITCH_LANG_ATOMIC_SUPPORT_H

#include <stdbool.h>
#include <stdint.h>

typedef struct SwitchLangAtomicUInt64 SwitchLangAtomicUInt64;
SwitchLangAtomicUInt64 *switch_lang_atomic_create(uint64_t initial);
void switch_lang_atomic_destroy(SwitchLangAtomicUInt64 *value);
uint64_t switch_lang_atomic_load(const SwitchLangAtomicUInt64 *value);
void switch_lang_atomic_store(SwitchLangAtomicUInt64 *value, uint64_t desired);
uint64_t switch_lang_atomic_exchange(SwitchLangAtomicUInt64 *value, uint64_t desired);
uint64_t switch_lang_atomic_fetch_add(SwitchLangAtomicUInt64 *value, uint64_t amount);
uint64_t switch_lang_atomic_fetch_or(SwitchLangAtomicUInt64 *value, uint64_t bits);
bool switch_lang_atomic_compare_exchange(SwitchLangAtomicUInt64 *value, uint64_t expected, uint64_t desired);

#endif
