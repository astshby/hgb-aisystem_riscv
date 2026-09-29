// Module: machine_timer
// Description: Single-hart MSIP, 64-bit MTIME and MTIMECMP local-bus device.
module machine_timer (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    output logic irq_software, irq_timer
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    logic [63:0] time_q, time_d, compare_q, compare_d, read_value;
    logic software_q, software_d;
    logic [15:0] offset;
    logic is_time, is_compare, is_software, legal, fire;
    int lane_base;

    // 地址布局采用单 hart 常用偏移；MSIP 只允许 32 位，64 位寄存器支持 RV32 分半访问。
    assign offset = request.addr[15:0];
    assign is_time = (offset & 16'hfff8) == 16'hbff8;
    assign is_compare = (offset & 16'hfff8) == 16'h4000;
    assign is_software = offset == 0;
    assign legal = !request.execute && (
        (request.size == MEM_WORD && request.addr[1:0] == 0 &&
         (is_time || is_compare || is_software)) ||
        (XLEN == 64 && request.size == MEM_DWORD && request.addr[2:0] == 0 &&
         (is_time || is_compare)));
    assign req_ready = !rsp_valid || rsp_ready;
    assign fire = req_valid && req_ready && legal;
    assign irq_software = software_q;
    assign irq_timer = time_q >= compare_q;
    assign lane_base = XLEN == 32 && offset[2] ? 4 : 0;

    always_comb begin
        read_value = '0;
        if (is_time) read_value = time_q;
        else if (is_compare) read_value = compare_q;
        else if (is_software) read_value[0] = software_q;
    end

    // 写 MTIME 的当拍停止自增，未选中的字节保持；比较器为无符号 64 位。
    always_comb begin
        time_d = time_q + 64'd1;
        compare_d = compare_q;
        software_d = software_q;
        if (fire && request.write) begin
            if (is_time) time_d = time_q;
            for (int b = 0; b < DBUS_BYTES; b++) begin
                if (request.wstrb[b]) begin
                    if (is_time) time_d[(lane_base+b)*8 +: 8] = request.wdata[b*8 +: 8];
                    if (is_compare) compare_d[(lane_base+b)*8 +: 8] = request.wdata[b*8 +: 8];
                end
            end
            if (is_software && request.wstrb[0]) software_d = request.wdata[0];
        end
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            time_q <= '0;
            compare_q <= '1;
            software_q <= 1'b0;
        end else begin
            time_q <= time_d;
            compare_q <= compare_d;
            software_q <= software_d;
        end
    end

    // Store 同样产生一个完成响应，读返回值在请求沿采样，不随后台计数变化。
    always_ff @(posedge clk) begin
        if (rst) begin
            rsp_valid <= 1'b0;
            response <= '0;
        end else begin
            if (rsp_valid && rsp_ready) rsp_valid <= 1'b0;
            if (req_valid && req_ready) begin
                rsp_valid <= 1'b1;
                response.error <= legal ? BUS_OK : BUS_SLVERR;
                response.rdata <= !legal || request.write ? '0 :
                                  xlen_t'(read_value >> (lane_base*8));
            end
        end
    end
endmodule
