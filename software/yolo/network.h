/* Module: yolo_network
 * Description: Fixed Tiny graph, checked INT8 model package and CPU graph operations around a selectable convolution backend.
 */
#ifndef YOLO_NETWORK_H
#define YOLO_NETWORK_H
#include <stddef.h>
#include <stdint.h>
#include "conv_schedule.h"
#define YOLO_NETWORK_VERSION 1u
#define YOLO_NETWORK_HEADER_BYTES 128u
#define YOLO_NETWORK_TENSOR_BYTES 32u
#define YOLO_NETWORK_NODE_BYTES 64u
#define YOLO_NETWORK_MAX_TENSORS 512u
#define YOLO_NETWORK_MAX_NODES 512u
#define YOLO_NETWORK_KEEP UINT32_MAX
/* 小端文件：magic[8]="YOLONET1"，随后30个u32。
 * version,total_bytes,tensor_count,node_count,input_id,head[3],tensor_offset,
 * node_offset,data_offset,payload_crc32,input_c,input_h,input_w,reserved[15]。
 * CRC32覆盖[128,total_bytes)，标准IEEE/zlib多项式。
 * tensor=u32[8]:c,h,w,last_use(node index或KEEP),flags(input1/head2),reserved[3]。
 * node=u32[16]:op,out,ninputs,in[4],p[4],data[4],flags。
 * data为文件绝对byte偏移，float32与INT8权重均按4B对齐；无bias用KEEP。
 */
enum yolo_network_op {YOLO_NET_CONV=1,YOLO_NET_BN=2,YOLO_NET_SILU=3,
    YOLO_NET_FOCUS=4,YOLO_NET_ADD=5,YOLO_NET_CONCAT=6,YOLO_NET_MAXPOOL=7,
    YOLO_NET_UPSAMPLE=8,YOLO_NET_SIGMOID=9};
enum yolo_network_error {YOLO_NET_OK=0,YOLO_NET_FORMAT=1,YOLO_NET_CRC=2,
    YOLO_NET_SHAPE=3,YOLO_NET_MEMORY=4,YOLO_NET_BACKEND=5,YOLO_NET_NUMERIC=6};
struct yolo_network_node {uint32_t op,out,ninputs,in[4],p[4],data[4],flags;};
struct yolo_network_tensor {uint32_t c,h,w,last_use,flags;};
struct yolo_network {
    const unsigned char *blob;size_t bytes;
    uint32_t tensor_count,node_count,input_id,head[3],tensor_offset,node_offset,data_offset;
    uint32_t input_c,input_h,input_w;
};
struct yolo_network_allocator {
    void *(*allocate)(void *,size_t);
    void (*release)(void *,void *);
    void *context;
};
typedef int (*yolo_network_conv)(void *,const struct yolo_conv *);
typedef void (*yolo_network_progress)(void *,uint32_t node,uint32_t op);
struct yolo_network_backend {yolo_network_conv convolve;void *context;
    yolo_network_progress progress;void *progress_context;};
struct yolo_detection {float x1,y1,x2,y2,score,objectness,class_probability;uint32_t class_id;};
struct yolo_network_stats {
    uint64_t useful_macs,allocation_peak_bytes;
    uint32_t conv_calls,nodes_executed,candidates,detections,written;
};
struct yolo_network_plan {uint64_t model_bytes,tensor_peak_bytes,scratch_peak_bytes,
    inference_peak_bytes;uint32_t convolution_count,head_locations;};
int yolo_network_open(struct yolo_network *,const void *,size_t);
int yolo_network_model_init(struct yolo_network *,const void *,size_t);
int yolo_network_get_tensor(const struct yolo_network *,uint32_t,struct yolo_network_tensor *);
int yolo_network_get_node(const struct yolo_network *,uint32_t,struct yolo_network_node *);
int yolo_network_memory_plan(const struct yolo_network *,struct yolo_network_plan *);
/* Conv data={OIHW int8,per-output float32 scale,optional float32 bias,0},
 * p={kernel,stride,pad,0}; BN data={gamma,beta,mean,var},eps=1e-3。
 * inference提供allocator并按last_use释放临时tensor；输出框坐标属于网络输入尺寸。
 * 回调必须显式指定；板侧可在回调调用yolo_conv_s8，不存在隐式CPU回退。
 */
int yolo_network_infer_rgb888(const struct yolo_network *,const uint8_t *,size_t,
    struct yolo_network_backend,struct yolo_network_allocator,float confidence,float nms,
    struct yolo_detection *,uint32_t capacity,struct yolo_network_stats *);
/* 以下小算子接口供C定向测试与独立算子移植使用。 */
int yolo_network_quantize(const float *,size_t,int8_t *,float *);
int yolo_network_batchnorm(const float *,float *,uint32_t channels,size_t spatial,
    const float *gamma,const float *beta,const float *mean,const float *variance);
int yolo_network_scalar_conv(void *,const struct yolo_conv *);
int yolo_network_decode(const float *const heads[3],unsigned width,unsigned height,
    float confidence,float nms,struct yolo_detection *,unsigned capacity,
    struct yolo_network_allocator,struct yolo_network_stats *);
int yolo_network_graph_op(uint32_t,const struct yolo_network_tensor *,float *,
    const struct yolo_network_tensor *,const float *const *,uint32_t,const uint32_t *);
#endif
