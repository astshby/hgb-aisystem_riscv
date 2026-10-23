#ifndef MM3_H
#define MM3_H
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#ifndef MAX_SEQ_LEN
#define MAX_SEQ_LEN 2048
#endif
#ifndef MAX_NEW_TOKENS
#define MAX_NEW_TOKENS 256
#endif
#if MAX_SEQ_LEN < 1 || MAX_SEQ_LEN > 32768 || MAX_NEW_TOKENS < 0 || MAX_NEW_TOKENS > 32768
#error Invalid context/generation configuration
#endif
#define MM3_HIDDEN 768
#define MM3_INTER 2432
#define MM3_LAYERS 8
#define MM3_HEADS 8
#define MM3_KV_HEADS 4
#define MM3_HEAD_DIM 96
#define MM3_VOCAB 6400
#define MM3_KV_DIM 384
typedef struct { const unsigned char *data; size_t size; void *owned; } Blob;
typedef struct { const char *name; const float *data; uint32_t rows, cols; } Tensor;
typedef struct { const float *f32; uint32_t rows, cols; const char *name; } Linear;
typedef struct {
    Blob blob; Tensor tensors[90]; unsigned ntensors;
    const float *embed, *norm;
    struct { const float *in_norm, *ffn_norm, *q_norm, *k_norm; } layer[MM3_LAYERS];
    float eps, theta; Linear linear[57];
} Model;
typedef struct { const unsigned char *bytes; uint32_t len, special; } Token;
typedef struct { uint32_t left, right, output; } Merge;
typedef struct { uint32_t start, end, kind; } UnicodeRange;
typedef struct {
    Blob blob; Token *tokens; Merge *merges; UnicodeRange *ranges;
    uint32_t nmerges, nranges; int byte_ids[256];
} Tokenizer;
typedef struct { int *ids; size_t count, capacity; } TokenIds;
typedef struct { unsigned char pending[4]; unsigned have, need; FILE *file; int failed; } TextDecoder;
/* 可替换为 MMIO/DMA 后端；当前接口同步完成每个算子。 */
typedef struct {
    void (*gemv)(float *, const float *, const float *, int, int);
    void (*norm)(float *, const float *, const float *, int, float);
    void (*softmax)(float *, int);
    void (*rope)(float *, int, int, float);
    void (*swiglu)(float *, const float *, int);
} Backend;
extern const Backend mm3_cpu_backend;
typedef struct {
    const Model *model; const Backend *backend; int pos, capacity;
    float *keys, *values, *scores;
    float x[MM3_HIDDEN], normed[MM3_HIDDEN], q[MM3_HIDDEN];
    float k[MM3_KV_DIM], v[MM3_KV_DIM], attention[MM3_HIDDEN], temp[MM3_HIDDEN];
    float gate[MM3_INTER], up[MM3_INTER], logits[MM3_VOCAB];
    FILE *trace;

} Runtime;
void *platform_alloc(size_t);
void platform_free(void *);
int platform_read(const char *, Blob *);
void platform_write(const unsigned char *, size_t);
double platform_seconds(void);
uint32_t read_u32(const unsigned char *);
uint64_t read_u64(const unsigned char *);
uint32_t crc32_bytes(const unsigned char *, size_t);
int blob_load(Blob *, const char *, int);
void blob_release(Blob *);
int blob_validate(const Blob *, const char *);
int model_open(Model *, const char *);
void model_close(Model *);
int tokenizer_open(Tokenizer *, const char *);
void tokenizer_close(Tokenizer *);
int tokenizer_encode(const Tokenizer *, const char *, TokenIds *);
void token_ids_free(TokenIds *);
int tokenizer_decode(FILE *, const Tokenizer *, const int *, size_t);
void tokenizer_emit(TextDecoder *, const Tokenizer *, int);
void tokenizer_flush(TextDecoder *);
char *chat_prompt(const char *);
int runtime_init(Runtime *, const Model *, int);
void runtime_close(Runtime *);
int runtime_step(Runtime *, int);
int argmax(const float *, int);
#endif
