// Module: cache_port
// Description: Routes validated DDR accesses to the cache and preserves the uncached response path.
module cache_port #(
    parameter bit ENABLE = 1'b1,
    parameter bit INSTRUCTION = 1'b1,
    parameter int unsigned DDR_BYTES = 0,
    parameter int unsigned LINE_BYTES = 32
) (
    input logic clk, rst, invalidate,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    output logic cache_req_valid,
    input logic cache_req_ready,
    output bus_types_pkg::bus_req_t cache_request,
    input logic cache_rsp_valid,
    output logic cache_rsp_ready,
    input bus_types_pkg::bus_rsp_t cache_response,
    input logic refill_req_valid,
    output logic refill_req_ready,
    input bus_types_pkg::bus_req_t refill_request,
    output logic refill_rsp_valid,
    output bus_types_pkg::bus_rsp_t refill_response,
    output logic mem_req_valid,
    input logic mem_req_ready,
    output bus_types_pkg::bus_req_t mem_request,
    input logic mem_rsp_valid,
    output logic mem_rsp_ready,
    input bus_types_pkg::bus_rsp_t mem_response
);
    import core_types_pkg::*;
    import bus_types_pkg::*;
    bus_target_e target;
    bus_error_e access_error;
    logic active_q, cached_q, available, cacheable, request_fire, response_fire;
    logic buffer_valid_q;
    bus_rsp_t buffer_q;
    logic [64:0] line_base, line_end;

    // 命中不能绕过原有的完整 XLEN 地址、对齐和执行权限检查。
    address_decode #(.DDR_BYTES(DDR_BYTES)) u_decode (
        .request, .target, .error(access_error)
    );
    always_comb begin
        line_base = 65'(request.addr) & ~65'(LINE_BYTES-1);
        line_end = line_base + 65'(LINE_BYTES);
        cacheable = ENABLE && (INSTRUCTION ? request.execute && !request.write : !request.execute) &&
                    access_error == BUS_OK && target == TARGET_DDR &&
                    line_base >= 65'(soc_addr_pkg::DDR_BASE) &&
                    line_end <= 65'(soc_addr_pkg::DDR_BASE) + 65'(DDR_BYTES) &&
                    line_end <= (65'd1 << soc_config_pkg::PHYS_ADDR_W);
    end

    // 响应按接受时的通路归属返回，不随下一条请求地址变化。旁路不额外经过 LOOKUP。
    assign rsp_valid = active_q && (cached_q ? cache_rsp_valid : (buffer_valid_q || mem_rsp_valid));
    assign response = cached_q ? cache_response : (buffer_valid_q ? buffer_q : mem_response);
    assign response_fire = rsp_valid && rsp_ready;
    assign available = !active_q || (!cached_q && response_fire);
    assign req_ready = !rst && !invalidate && available && (cacheable ? cache_req_ready : mem_req_ready);
    assign request_fire = req_valid && req_ready;
    assign cache_req_valid = !rst && !invalidate && available && req_valid && cacheable;
    assign cache_request = request;
    assign cache_rsp_ready = active_q && cached_q && rsp_ready;

    // 在途填行独占本主端口；一次只下发一笔子事务，响应握手不依赖 CPU 的反压。
    assign mem_req_valid = active_q && cached_q ? refill_req_valid :
                           (!rst && !invalidate && available && req_valid && !cacheable);
    assign mem_request = active_q && cached_q ? refill_request : request;
    assign refill_req_ready = active_q && cached_q && mem_req_ready;
    assign refill_rsp_valid = active_q && cached_q && mem_rsp_valid;
    assign refill_response = mem_response;
    assign mem_rsp_ready = 1'b1;

    // I 响应旁路优先，反压时保存一份；Core 每端口一笔在途，缓冲未消费前不会再发请求。
    // 互连 I-rsp-ready 恒为 1，切断 IF 输出反压经共享 bank 返回 MEM-ready 的组合环。
    always_ff @(posedge clk) begin
        if (rst) begin
            buffer_valid_q <= 1'b0;
            buffer_q <= '0;
        end else begin
            if (response_fire) buffer_valid_q <= 1'b0;
            if (active_q && !cached_q && mem_rsp_valid && !rsp_ready) begin
                buffer_valid_q <= 1'b1;
                buffer_q <= mem_response;
            end
        end
    end

    // 旧旁路响应与新请求可以同拍交接，保留 TCM 的一拍延迟与连续传输能力。
    always_ff @(posedge clk) begin
        if (rst) begin
            active_q <= 1'b0;
            cached_q <= 1'b0;
        end else begin
            if (response_fire) active_q <= 1'b0;
            if (request_fire) begin
                active_q <= 1'b1;
                cached_q <= cacheable;
            end
        end
    end
endmodule
