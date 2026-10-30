// Module: cpu_memory_adapter
// Description: CPU-only tagged data routes, native IF64 and caches; local TCM ports stay in the core domain.
module cpu_memory_adapter #(
    parameter int unsigned DDR_BYTES = 0,
    parameter bit ICACHE_ENABLE = 1,
    parameter int unsigned ICACHE_BYTES = 4096,
    parameter int unsigned ICACHE_LINE_BYTES = 32,
    parameter bit DCACHE_ENABLE = 1,
    parameter int unsigned DCACHE_BYTES = 4096,
    parameter int unsigned DCACHE_LINE_BYTES = 32,
    parameter bit CACHE_BLOCK_ENABLE = 0
) (
    input logic clk, rst, fence_i_commit, fetch_block,
    input logic imem_req_valid,
    output logic imem_req_ready,
    input core_types_pkg::xlen_t imem_req_addr,
    output logic imem_rsp_valid,
    input logic imem_rsp_ready,
    output logic [63:0] imem_rsp_data,
    output logic imem_rsp_error, imem_rsp_error_1,
    input logic [1:0] data_req_valid,
    output logic [1:0] data_req_ready,
    input scoreboard_pkg::memory_request_t data_request [2],
    output logic [1:0] data_rsp_valid,
    input logic [1:0] data_rsp_ready,
    output scoreboard_pkg::memory_response_t data_response [2],
    output logic [1:0] m_req_valid,
    input logic [1:0] m_req_ready,
    output bus_types_pkg::bus_req_t m_request [2],
    input logic [1:0] m_rsp_valid,
    output logic [1:0] m_rsp_ready,
    input bus_types_pkg::bus_rsp_t m_response [2],
    output logic [2:0] t_req_valid [2],
    input logic [2:0] t_req_ready [2],
    output bus_types_pkg::bus_req_t t_request [2][3],
    input logic [2:0] t_rsp_valid [2],
    output logic [2:0] t_rsp_ready [2],
    input logic [63:0] t_rsp_data [2][3],
    input logic maint_req_valid,
    output logic maint_req_ready,
    input cache_pkg::cache_maint_op_e maint_op,
    output logic maint_rsp_valid,
    input logic maint_rsp_ready,
    output cache_pkg::cache_maint_error_e maint_error,
    output core_types_pkg::xlen_t maint_fault_addr,
    output logic cache_fault_valid,
    output cache_pkg::cache_maint_error_e cache_fault_code,
    output core_types_pkg::xlen_t cache_fault_addr,
    output logic [1:0] cache_rd_cmd_valid,
    input logic [1:0] cache_rd_cmd_ready,
    output block_types_pkg::block_cmd_t cache_rd_cmd [2],
    input logic [1:0] cache_rd_valid,
    output logic [1:0] cache_rd_ready,
    input block_types_pkg::block_r_t cache_rd_data [2],
    output logic [1:0] cache_wr_cmd_valid,
    input logic [1:0] cache_wr_cmd_ready,
    output block_types_pkg::block_cmd_t cache_wr_cmd [2],
    output logic [1:0] cache_wr_valid,
    input logic [1:0] cache_wr_ready,
    output block_types_pkg::block_w_t cache_wr_data [2],
    input logic [1:0] cache_wr_rsp_valid,
    output logic [1:0] cache_wr_rsp_ready,
    input block_types_pkg::block_b_t cache_wr_rsp [2]
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import pipeline_pkg::*;
    typedef enum logic [2:0] {SLOW = 3'b001, ITCM = 3'b010, DTCM = 3'b100} route_e;
    route_e route [2], route_q [2];
    logic [2:0] incoming_route [2], queued_route [2];
    bus_req_t incoming_request [2];
    bus_req_t request [2], dc_request [2], if_request;
    bus_rsp_t response [2], dc_response [2];
    logic [1:0] itcm_ok, dtcm_ok;
    logic [1:0] req_valid, req_ready, rsp_valid, rsp_ready, active_q, available, req_fire, rsp_fire;
    retire_id_t tag_q [2];
    logic [1:0] dc_req_valid, dc_req_ready, dc_rsp_valid, dc_rsp_ready;
    scoreboard_pkg::memory_request_t buffered_request [2];
    logic if_active_q, if_tcm_q, if_select_tcm, if_available, if_req_fire, if_rsp_fire;
    logic ic_req_valid, ic_req_ready, ic_rsp_valid, ic_rsp_ready;
    logic [63:0] ic_rsp_data;
    logic [1:0] ic_rsp_error;

    for (genvar p = 0; p < 2; p++) begin : g_tagged_port
        assign incoming_request[p] = '{addr:data_request[p].address, write:data_request[p].write,
            execute:1'b0, size:data_request[p].size,
            wdata:data_request[p].wdata, wstrb:data_request[p].wstrb};
        // 资格只依赖地址/访问类型，在原有队列入口译码并同槽寄存。
        // active、响应反压、Cache维护仍在出队时判断，不能当作静态资格提前固定。
        tcm_address_decode u_decode (.request(incoming_request[p]),
            .itcm_ok(itcm_ok[p]), .dtcm_ok(dtcm_ok[p]));
        assign incoming_route[p] = {dtcm_ok[p], itcm_ok[p], !(itcm_ok[p] || dtcm_ok[p])};
        assign route[p] = route_e'(queued_route[p]);
        tagged_request_queue #(.META_WIDTH(3)) u_request_queue (
            .clk, .rst, .in_valid(data_req_valid[p]), .in_ready(data_req_ready[p]),
            .in_request(data_request[p]), .out_valid(req_valid[p]), .out_ready(req_ready[p]),
            .out_request(buffered_request[p]), .in_metadata(incoming_route[p]), .out_metadata(queued_route[p])
        );
        assign request[p] = '{addr:buffered_request[p].address, write:buffered_request[p].write,
            execute:1'b0, size:buffered_request[p].size,
            wdata:buffered_request[p].wdata, wstrb:buffered_request[p].wstrb};
        assign rsp_ready[p] = data_rsp_ready[p];
        assign data_rsp_valid[p] = rsp_valid[p];
        assign data_response[p] = '{id:tag_q[p], data:response[p].rdata, error:response[p].error != BUS_OK};
        always_ff @(posedge clk) if (req_fire[p]) tag_q[p] <= buffered_request[p].id;
    end
    assign req_fire = req_valid & req_ready;
    assign rsp_fire = rsp_valid & rsp_ready;
    assign available = ~active_q | rsp_fire;
    for (genvar p = 0; p < 2; p++) begin : g_route
        always_ff @(posedge clk) begin
            if (rst) begin active_q[p] <= 0; route_q[p] <= SLOW; end
            else begin
                if (rsp_fire[p]) active_q[p] <= 0;
                if (req_fire[p]) begin active_q[p] <= 1; route_q[p] <= route[p]; end
            end
        end
    end
    assign if_request = '{addr:imem_req_addr, write:1'b0, execute:1'b1,
                          size:MEM_WORD, wdata:'0, wstrb:'0};
    tcm_address_decode u_if_decode (.request(if_request), .itcm_ok(if_select_tcm), .dtcm_ok());
    assign if_req_fire = imem_req_valid && imem_req_ready;
    assign if_rsp_fire = imem_rsp_valid && imem_rsp_ready;
    assign if_available = !if_active_q || if_rsp_fire;
    assign imem_req_ready = !rst && !fetch_block && if_available && (if_select_tcm ? t_req_ready[0][0] : ic_req_ready);
    assign ic_req_valid = !rst && !fetch_block && if_available && imem_req_valid && !if_select_tcm;
    assign ic_rsp_ready = if_active_q && !if_tcm_q && imem_rsp_ready;
    assign imem_rsp_valid = if_active_q && (if_tcm_q ? t_rsp_valid[0][0] : ic_rsp_valid);
    assign imem_rsp_data = if_tcm_q ? t_rsp_data[0][0] : ic_rsp_data;
    assign imem_rsp_error = !if_tcm_q && ic_rsp_error[0];
    assign imem_rsp_error_1 = !if_tcm_q && ic_rsp_error[1];
    always_ff @(posedge clk) begin
        if (rst) begin if_active_q <= 0; if_tcm_q <= 0; end
        else begin
            if (if_rsp_fire) if_active_q <= 0;
            if (if_req_fire) begin if_active_q <= 1; if_tcm_q <= if_select_tcm; end
        end
    end
    // 当前地址仅选择新的请求；响应由寄存 route/tag 选择，能够跨目标切换并承受反压。
    always_comb begin
        req_ready = 0; rsp_valid = 0; dc_req_valid = 0; dc_rsp_ready = 0;
        for (int b = 0; b < 2; b++) begin
            t_req_valid[b] = 0; t_rsp_ready[b] = 0; t_request[b][0] = if_request;
            for (int p = 0; p < 2; p++) t_request[b][p+1] = request[p];
        end
        t_req_valid[0][0] = !rst && !fetch_block && if_available && imem_req_valid && if_select_tcm;
        t_rsp_ready[0][0] = if_active_q && if_tcm_q && imem_rsp_ready;
        for (int p = 0; p < 2; p++) dc_request[p] = request[p];
        for (int p = 0; p < 2; p++) begin
            response[p] = '0;
            if (!rst && available[p]) begin
                unique case (route[p])
                    ITCM: begin t_req_valid[0][p+1] = req_valid[p]; req_ready[p] = t_req_ready[0][p+1]; end
                    DTCM: begin t_req_valid[1][p+1] = req_valid[p]; req_ready[p] = t_req_ready[1][p+1]; end
                    default: begin
                        dc_req_valid[p] = req_valid[p]; req_ready[p] = dc_req_ready[p];
                    end
                endcase
            end
            if (!rst && active_q[p]) begin
                unique case (route_q[p])
                    ITCM: begin
                        rsp_valid[p] = t_rsp_valid[0][p+1]; t_rsp_ready[0][p+1] = rsp_ready[p];
                        response[p] = '{rdata:xlen_t'(t_rsp_data[0][p+1]), error:BUS_OK};
                    end
                    DTCM: begin
                        rsp_valid[p] = t_rsp_valid[1][p+1]; t_rsp_ready[1][p+1] = rsp_ready[p];
                        response[p] = '{rdata:xlen_t'(t_rsp_data[1][p+1]), error:BUS_OK};
                    end
                    default: begin
                        rsp_valid[p] = dc_rsp_valid[p]; dc_rsp_ready[p] = rsp_ready[p]; response[p] = dc_response[p];
                    end
                endcase
            end
        end
    end
    icache_native #(.ENABLE(ICACHE_ENABLE), .DDR_BYTES(DDR_BYTES), .CACHE_BYTES(ICACHE_BYTES),
                    .LINE_BYTES(ICACHE_LINE_BYTES), .BLOCK_ENABLE(CACHE_BLOCK_ENABLE)) u_icache (
        .clk, .rst, .invalidate(fence_i_commit), .req_valid(ic_req_valid), .req_ready(ic_req_ready),
        .req_addr(imem_req_addr), .rsp_valid(ic_rsp_valid), .rsp_ready(ic_rsp_ready),
        .rsp_data(ic_rsp_data), .rsp_error(ic_rsp_error),
        .mem_req_valid(m_req_valid[0]), .mem_req_ready(m_req_ready[0]), .mem_request(m_request[0]),
        .mem_rsp_valid(m_rsp_valid[0]), .mem_rsp_ready(m_rsp_ready[0]), .mem_response(m_response[0]),
        .rd_cmd_valid(cache_rd_cmd_valid[0]), .rd_cmd_ready(cache_rd_cmd_ready[0]), .rd_cmd(cache_rd_cmd[0]),
        .rd_valid(cache_rd_valid[0]), .rd_ready(cache_rd_ready[0]), .rd_data(cache_rd_data[0])
    );
    assign cache_wr_cmd_valid[0] = 0; assign cache_wr_cmd[0] = '0;
    assign cache_wr_valid[0] = 0; assign cache_wr_data[0] = '0; assign cache_wr_rsp_ready[0] = 0;
    dcache_banked #(.ENABLE(DCACHE_ENABLE), .DDR_BYTES(DDR_BYTES), .CACHE_BYTES(DCACHE_BYTES),
                    .LINE_BYTES(DCACHE_LINE_BYTES), .BLOCK_ENABLE(CACHE_BLOCK_ENABLE)) u_dcache (
        .clk, .rst, .req_valid(dc_req_valid), .req_ready(dc_req_ready), .request(dc_request),
        .rsp_valid(dc_rsp_valid), .rsp_ready(dc_rsp_ready), .response(dc_response),
        .maint_req_valid, .maint_req_ready, .maint_op, .maint_rsp_valid, .maint_rsp_ready, .maint_error, .maint_fault_addr,
        .fault_valid(cache_fault_valid), .fault_code(cache_fault_code), .fault_addr(cache_fault_addr),
        .mem_req_valid(m_req_valid[1]), .mem_req_ready(m_req_ready[1]), .mem_request(m_request[1]),
        .mem_rsp_valid(m_rsp_valid[1]), .mem_rsp_ready(m_rsp_ready[1]), .mem_response(m_response[1]),
        .rd_cmd_valid(cache_rd_cmd_valid[1]), .rd_cmd_ready(cache_rd_cmd_ready[1]), .rd_cmd(cache_rd_cmd[1]),
        .rd_valid(cache_rd_valid[1]), .rd_ready(cache_rd_ready[1]), .rd_data(cache_rd_data[1]),
        .wr_cmd_valid(cache_wr_cmd_valid[1]), .wr_cmd_ready(cache_wr_cmd_ready[1]), .wr_cmd(cache_wr_cmd[1]),
        .wr_valid(cache_wr_valid[1]), .wr_ready(cache_wr_ready[1]), .wr_data(cache_wr_data[1]),
        .wr_rsp_valid(cache_wr_rsp_valid[1]), .wr_rsp_ready(cache_wr_rsp_ready[1]), .wr_rsp(cache_wr_rsp[1])
    );
endmodule
