#ifndef APP_AUDIO_ROUTER_REALTIME_H
#define APP_AUDIO_ROUTER_REALTIME_H

#include <stdint.h>

void *aar_atomic_u32_create(uint32_t initial_value);
void aar_atomic_u32_destroy(void *storage);
uint32_t aar_atomic_u32_load(const void *storage);
void aar_atomic_u32_store(void *storage, uint32_t value);
uint32_t aar_atomic_u32_increment(void *storage);

#endif
