/* SPDX-License-Identifier: Apache-2.0 */
#include <string.h>
#include "protocol.h"
static const uint8_t *input;
static unsigned length, position, fault;
static uint8_t cache[139264], memory[139264];
unsigned test_writes, test_acks;
uint32_t test_entry;
static unsigned index_of(uint32_t a)
{ return a>=0x80000000u ? a-0x80000000u : a-0x0110c000u+131072u; }
int loader_get(uint8_t *v)
{ if (position==length) return HGB_TIMEOUT; *v=input[position++]; return 0; }
void loader_put(uint8_t v) { if (v==6) test_acks++; }
void loader_store(uint32_t a, uint8_t v) { cache[index_of(a)]=v; test_writes++; }
uint8_t loader_load(uint32_t a) { return memory[index_of(a)]; }
int loader_flush(void)
{
    if (fault==1) return 1;
    memcpy(memory,cache,sizeof(memory));
    if (fault==2) memory[0]^=1;
    return 0;
}
int test_receive(const uint8_t *bytes, unsigned count, unsigned config, unsigned fail)
{
    input=bytes; length=count; position=0; fault=fail;
    test_writes=test_acks=0;
    memset(cache,0,sizeof(cache)); memset(memory,0,sizeof(memory));
    return hgb_receive(config,&test_entry);
}
