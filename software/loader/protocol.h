/* SPDX-License-Identifier: Apache-2.0 */
#ifndef HGB_LOADER_PROTOCOL_H
#define HGB_LOADER_PROTOCOL_H
#include <stdint.h>
#define HGB_SEGMENTS 8u
#define HGB_BLOCK 128u
#define HGB_CONFIG(xlen) ((xlen) | (1u << 16))
enum { HGB_OK, HGB_TIMEOUT, HGB_HEADER, HGB_CONFIG_ERROR, HGB_RANGE,
       HGB_OVERLAP, HGB_CRC, HGB_CACHE, HGB_READBACK, HGB_UART };
struct hgb_segment { uint32_t address, size, flags, crc; };
uint32_t hgb_crc(uint32_t crc, uint8_t value);
int hgb_receive(uint32_t config, uint32_t *entry);
int loader_get(uint8_t *value);
void loader_put(uint8_t value);
void loader_store(uint32_t address, uint8_t value);
uint8_t loader_load(uint32_t address);
int loader_flush(void);
#endif
