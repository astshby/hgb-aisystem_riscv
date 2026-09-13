// Module: if_stage
// Description: Issues ordered fetch requests, buffers responses, and kills redirected paths.
// if阶段模块：发出有序的取指请求，缓冲响应，并在重定向时丢弃旧路径。
module if_stage (
    input  logic                              clk,
    input  logic                              rst,
    input  logic                              fetch_request_enable, // IF 是否可以发出新请求（用于 ECALL、EBREAK、MRET）
    input  logic                              out_ready, // D1 可以接收 out_packet
    input  logic                              flush, // 序列化清除取指，但不直接修改 PC
    input  pipeline_pkg::redirect_t           redirect,
    input  pipeline_pkg::pred_info_t          prediction,
    output pipeline_pkg::if_d1_t              out_packet,
    output logic                              imem_req_valid,
    output logic [core_config_pkg::XLEN-1:0]  imem_req_addr,
    input  logic                              imem_req_ready,
    input  logic                              imem_rsp_valid,
    input  logic [31:0]                       imem_rsp_data,
    output logic                              imem_rsp_ready
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;

    // IF 最多保留一个未完成请求和一个已返回但 D1 尚未接收的响应。
    xlen_t pc_q;
    if_d1_t request_q; // 已接受请求的 PC/seq_pc/预测元数据
    if_d1_t buffer_q; // D1 暂停时保存已经返回的指令
    logic request_killed_q; // redirect/flush 后等待并丢弃旧路径响应

    if_d1_t response_packet;
    logic response_can_buffer;
    logic response_fire;
    logic response_usable;
    logic request_fire;

    // 组合部分
    // IMEM 请求与响应接口：req_valid/rsp_ready 由 IF 发出，其余由 IMEM/Cache 返回。
    always_comb begin
        // response_fire 是 response 响应握手，request_fire 是 request 请求握手。
        imem_req_valid = fetch_request_enable && !redirect.valid && !flush &&
                         (!request_q.valid || response_fire);
        imem_req_addr = pc_q;
        // 空闲：请求被杀死、正在清空，或者返回数据能够交给 D1/Buffer。
        imem_rsp_ready = request_q.valid &&
                         (request_killed_q || redirect.valid || flush || response_can_buffer);
    end

    // 握手与响应组包：被 kill 或正处于清空周期的响应只能消费，不能进入流水线。
    always_comb begin
        response_can_buffer = !buffer_q.valid || out_ready;
        request_fire = imem_req_valid && imem_req_ready;
        response_fire = imem_rsp_valid && imem_rsp_ready;
        response_usable = response_fire && !request_killed_q &&
                          !redirect.valid && !flush;
        response_packet = request_q;
        response_packet.inst = imem_rsp_data;
        response_packet.valid = response_usable;
    end

    // 输出选择：buffer 优先，否则允许新响应直接送往 D1。
    always_comb begin
        out_packet = buffer_q;
        if (!buffer_q.valid)
            out_packet = response_packet;
        if (redirect.valid || flush)
            out_packet.valid = 1'b0;
    end

    // 时序部分
    // PC 状态：只有请求真正被接受后才推进；redirect 优先切换取指地址。
    always_ff @(posedge clk) begin
        if (rst)
            pc_q <= RESET_VECTOR;
        else if (redirect.valid)
            pc_q <= redirect.pc;
        else if (request_fire)
            pc_q <= prediction.taken ? prediction.target : pc_q + xlen_t'(4);
    end

    // Request 状态：清空时若请求尚未返回，必须保留 kill 标志直到旧响应被消费。
    always_ff @(posedge clk) begin
        if (rst) begin
            request_q <= '0;
            request_killed_q <= 1'b0;
        end else if (redirect.valid || flush) begin
            if (request_q.valid && !response_fire)
                request_killed_q <= 1'b1;
            else begin
                request_q.valid <= 1'b0;
                request_killed_q <= 1'b0;
            end
        end else begin
            // 响应完成先释放旧槽，同拍的新请求可在下面重新占用。
            if (response_fire) begin
                request_q.valid <= 1'b0;
                request_killed_q <= 1'b0;
            end
            if (request_fire) begin
                request_q.valid <= 1'b1;
                request_q.pc <= pc_q;
                request_q.seq_pc <= pc_q + xlen_t'(4);
                request_q.inst <= '0;
                request_q.pred <= prediction;
                request_killed_q <= 1'b0;
            end
        end
    end

    // Buffer 状态：覆盖“旧包出队且新响应同拍到达”的连续传输情况。
    // 处理 b1q1 与 b0q0；b1q0 保持，b0q1 在 D1 暂停时保存返回包。
    always_ff @(posedge clk) begin
        if (rst || redirect.valid || flush)
            buffer_q <= '0;
        else if (buffer_q.valid && out_ready) begin
            if (response_usable)
                buffer_q <= response_packet;
            else
                buffer_q.valid <= 1'b0;
        end else if (!buffer_q.valid && !out_ready && response_usable)
            buffer_q <= response_packet;
    end
endmodule
