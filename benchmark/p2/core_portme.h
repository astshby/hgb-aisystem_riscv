#ifndef P2_CORE_PORTME_H
#define P2_CORE_PORTME_H
#include "../coremark/port/core_portme.h"
#undef MEM_LOCATION
#ifdef P2_TCM
#define MEM_LOCATION "ITCM program; DTCM data/stacks; DMA DTCM to ITCM reserved buffers"
#else
#define MEM_LOCATION "DDR text/rodata/data/bss/stack; TCM control and host mailbox"
#endif
#endif
