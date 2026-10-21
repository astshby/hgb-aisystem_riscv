// Module: ddr_port_arbiter
// Description: Fair single-owner arbitration between an XLEN CPU port and a native 256-bit DMA port.
module ddr_port_arbiter (
    input logic clk, rst,
    input logic cpu_req_valid,
    output logic cpu_req_ready,
    input bus_types_pkg::bus_req_t cpu_request,
    output logic cpu_rsp_valid,
    input logic cpu_rsp_ready,
    output bus_types_pkg::bus_rsp_t cpu_response,
    input logic dma_req_valid,
    output logic dma_req_ready,
    input bus_types_pkg::ddr_req_t dma_request,
    output logic dma_rsp_valid,
    input logic dma_rsp_ready,
    output bus_types_pkg::ddr_rsp_t dma_response,
    output logic req_valid,
    input logic req_ready,
    output bus_types_pkg::ddr_req_t request,
    input logic rsp_valid,
    output logic rsp_ready,
    input bus_types_pkg::ddr_rsp_t response
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    logic busy_q, owner_q, next_q, locked_q, locked_owner_q, selected;
    logic [4:0] cpu_lane, read_lane_q;
    logic req_fire, rsp_fire;
    ddr_req_t expanded;

    // 两请求均有效时轮询；反压期间锁获选主端，另一主端不能更换展示中的载荷。
    // request 握手后锁 owner 到真实 response 握手，不能按请求数量猜测响应归属。
    always_comb begin
        if (locked_q) selected = locked_owner_q;
        else if (cpu_req_valid && dma_req_valid) selected = next_q;
        else selected = dma_req_valid;
        cpu_lane = cpu_request.addr[4:0] & 5'(~(DBUS_BYTES-1));
        expanded = '0;
        expanded.addr = cpu_request.addr;
        expanded.write = cpu_request.write;
        expanded.execute = cpu_request.execute;
        // 非法 RV32 双字访问仍交桥报告 SLVERR，不能经宽口变成合法请求。
        expanded.size = (XLEN == 32 && cpu_request.size == MEM_DWORD) ? 3'd7 : 3'(cpu_request.size);
        expanded.wdata = DDR_DATA_W'(cpu_request.wdata) << (8 * cpu_lane);
        expanded.wstrb = DDR_BEAT_BYTES'(cpu_request.wstrb) << cpu_lane;
        request = selected ? dma_request : expanded;
        req_valid = !rst && !busy_q && (selected ? dma_req_valid : cpu_req_valid);
        cpu_req_ready = !rst && !busy_q && !selected && req_ready;
        dma_req_ready = !rst && !busy_q && selected && req_ready;
        cpu_rsp_valid = !rst && busy_q && !owner_q && rsp_valid;
        dma_rsp_valid = !rst && busy_q && owner_q && rsp_valid;
        rsp_ready = !rst && busy_q && (owner_q ? dma_rsp_ready : cpu_rsp_ready);
        cpu_response = '{rdata:xlen_t'(response.rdata >> (8 * read_lane_q)), error:response.error};
        dma_response = response;
    end
    assign req_fire = req_valid && req_ready;
    assign rsp_fire = rsp_valid && rsp_ready;

    // 不复制请求或响应数据槽；上/下游各自保持 valid 的载荷，仲裁器只保存身份和窄读 lane。
    always_ff @(posedge clk) begin
        if (rst) begin
            busy_q <= 1'b0;
            owner_q <= 1'b0;
            next_q <= 1'b0;
            locked_q <= 1'b0;
            locked_owner_q <= 1'b0;
            read_lane_q <= '0;
        end else begin
            if (!busy_q && req_valid && !req_ready) begin
                locked_q <= 1'b1;
                locked_owner_q <= selected;
            end
            if (req_fire) begin
                busy_q <= 1'b1;
                owner_q <= selected;
                read_lane_q <= cpu_lane;
                locked_q <= 1'b0;
            end else if (rsp_fire) begin
                busy_q <= 1'b0;
                next_q <= !owner_q;
            end
        end
    end
endmodule
