#ifndef MM3_CONFIG_H
#define MM3_CONFIG_H
/* 唯一配置源：修改后运行 make mm3-config。生成文件不得手工修改。 */
/* 下列为模型固定尺寸，必须与锁定权重一致；不是并行度开关。 */
#define MM3_HIDDEN_SIZE 768
#define MM3_FFN_SIZE 2432
#define MM3_HEAD_DIM 96
#define MM3_QUERY_HEADS 8
#define MM3_KV_HEADS 4
#define MM3_VOCAB_SIZE 6400
/* 硬件容量；可以增大，但要考虑片上存储和仿真资源。 */
#define MM3_MAX_VECTOR 2432
#define MM3_NORM_MAX_LEN 768
#define MM3_SEQ_CAP 64
/* DDR 容量与单层测试命令上限。 */
#define MM3_DDR_BYTES 134217728
#define MM3_MAX_COMMANDS 256
#define MM3_GEMM_MAX_M 16
#define MM3_GEMM_MAX_N 96
#define MM3_GEMM_MAX_K 96
/* 并行度：GEMV 保持原算法；GEMM 行/列为真实 PE 数量。 */
#define MM3_GEMV_LANES 16
#define MM3_VEC_LANES 8
#define MM3_GEMM_ROWS 8
#define MM3_GEMM_COLS 8
/* 倒平方根：两个奇偶分区，每区 2^LUT_BITS 项，默认共 512 项。 */
#define MM3_RSQRT_LUT_BITS 8
#define MM3_RSQRT_ITERS 2
/* 简测默认：一个 Token、第一层、位置零；不执行完整八层生成。 */
#define MM3_TEST_TOKEN_ID 1
#define MM3_TEST_LAYER 0
#define MM3_TEST_POSITION 0
#define MM3_TEST_ATTN_LEN 4
#define MM3_TIMEOUT_CYCLES 50000000
#endif
