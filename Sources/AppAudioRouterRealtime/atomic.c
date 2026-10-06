#include "AppAudioRouterRealtime.h"

#include <stdatomic.h>
#include <stdlib.h>

typedef struct {
    _Atomic(uint32_t) value;
} AARAtomicUInt32;

void *aar_atomic_u32_create(uint32_t initial_value) {
    AARAtomicUInt32 *storage = malloc(sizeof(AARAtomicUInt32));
    if (storage != NULL) {
        atomic_init(&storage->value, initial_value);
    }
    return storage;
}

void aar_atomic_u32_destroy(void *storage) {
    free(storage);
}

uint32_t aar_atomic_u32_load(const void *storage) {
    const AARAtomicUInt32 *atomic_storage = storage;
    return atomic_load_explicit(&atomic_storage->value, memory_order_relaxed);
}

void aar_atomic_u32_store(void *storage, uint32_t value) {
    AARAtomicUInt32 *atomic_storage = storage;
    atomic_store_explicit(&atomic_storage->value, value, memory_order_relaxed);
}

uint32_t aar_atomic_u32_increment(void *storage) {
    AARAtomicUInt32 *atomic_storage = storage;
    return atomic_fetch_add_explicit(&atomic_storage->value, 1, memory_order_relaxed) + 1;
}
