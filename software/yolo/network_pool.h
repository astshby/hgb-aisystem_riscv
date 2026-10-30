/* Module: yolo_network_pool
 * Description: Reusable, 16-byte-aligned DDR arena with first-fit allocation and adjacent free-block merging.
 */
#ifndef YOLO_NETWORK_POOL_H
#define YOLO_NETWORK_POOL_H
#include <stddef.h>

struct yolo_network_pool {
    void *first;
    size_t bytes, live, peak;
};
int yolo_network_pool_init(struct yolo_network_pool *, void *memory, size_t bytes);
void *yolo_network_pool_allocate(void *context, size_t bytes);
void yolo_network_pool_release(void *context, void *memory);
size_t yolo_network_pool_free_bytes(const struct yolo_network_pool *);
#endif
