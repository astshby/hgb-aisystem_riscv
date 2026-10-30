/* Module: yolo_network_pool
 * Description: Arena metadata lives in DDR; releasing a tensor immediately merges adjacent free blocks.
 */
#include "network_pool.h"
#include <stdint.h>

struct block { size_t bytes; struct block *next; unsigned available; };
#define ALIGNMENT 16u
static size_t header_bytes(void) { return (sizeof(struct block)+ALIGNMENT-1u)&~(size_t)(ALIGNMENT-1u); }

int yolo_network_pool_init(struct yolo_network_pool *pool, void *memory, size_t bytes)
{
    if (!pool || !memory) return 1;
    uintptr_t original=(uintptr_t)memory, aligned=(original+ALIGNMENT-1u)&~(uintptr_t)(ALIGNMENT-1u);
    size_t skipped=(size_t)(aligned-original), header=header_bytes();
    if (aligned<original || bytes<skipped+header+ALIGNMENT) return 1;
    bytes=(bytes-skipped)&~(size_t)(ALIGNMENT-1u);
    struct block *first=(struct block *)aligned;
    first->bytes=bytes-header; first->next=0; first->available=1;
    pool->first=first; pool->bytes=bytes; pool->live=pool->peak=0;
    return 0;
}

void *yolo_network_pool_allocate(void *context, size_t bytes)
{
    struct yolo_network_pool *pool=context;
    if (!pool || !bytes || bytes>SIZE_MAX-(ALIGNMENT-1u)) return 0;
    bytes=(bytes+ALIGNMENT-1u)&~(size_t)(ALIGNMENT-1u);
    size_t header=header_bytes();
    for (struct block *b=pool->first; b; b=b->next) {
        if (!b->available || b->bytes<bytes) continue;
        if (b->bytes-bytes>=header+ALIGNMENT) {
            struct block *tail=(struct block *)((unsigned char *)b+header+bytes);
            tail->bytes=b->bytes-bytes-header; tail->next=b->next; tail->available=1;
            b->next=tail; b->bytes=bytes;
        }
        b->available=0; pool->live+=b->bytes;
        if (pool->live>pool->peak) pool->peak=pool->live;
        return (unsigned char *)b+header;
    }
    return 0;
}

void yolo_network_pool_release(void *context, void *memory)
{
    struct yolo_network_pool *pool=context;
    if (!pool || !memory) return;
    size_t header=header_bytes();
    for (struct block *b=pool->first; b; b=b->next) {
        if ((unsigned char *)b+header==(unsigned char *)memory) {
            if (b->available) return;
            b->available=1; pool->live-=b->bytes;
            break;
        }
    }
    for (struct block *b=pool->first; b && b->next;) {
        if (b->available && b->next->available) {
            b->bytes+=header+b->next->bytes; b->next=b->next->next;
        } else b=b->next;
    }
}

size_t yolo_network_pool_free_bytes(const struct yolo_network_pool *pool)
{
    size_t bytes=0;
    for (const struct block *b=pool->first; b; b=b->next)
        if (b->available) bytes+=b->bytes;
    return bytes;
}
