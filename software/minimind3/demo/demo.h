/* Module: mm3_demo_api
 * Description: Persistent integer inference session and bounded UART framing services.
 */
#ifndef MM3_DEMO_H
#define MM3_DEMO_H
#include "integer.h"
#define MM3_DEMO_PROMPT_BYTES 512u
int mm3_demo_getbyte(void);
void mm3_demo_putbyte(unsigned char value);
void mm3_demo_puts(const char *text);
void mm3_demo_u64(uint64_t value);
void mm3_demo_capture(int token);
int mm3_demo_emit(void);
void mm3_demo_request_begin(void);
void mm3_demo_request_end(void);
uint64_t mm3_demo_live_bytes(void);
int mm3_demo_backend(IRuntime *runtime, int accelerated);
int mm3_demo_session(const char *model, const char *tokenizer, unsigned maximum, int raw, int accelerated);
#endif
