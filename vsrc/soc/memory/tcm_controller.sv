// Module: tcm_controller
// Description: Synchronous byte-write TCM bank with a held local-bus response.
module tcm_controller #(
    parameter logic [31:0] BASE = soc_addr_pkg::ITCM_BASE,
    parameter int unsigned BYTES = soc_config_pkg::ITCM_BYTES,
    parameter string INIT_FILE = ""
) (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response
);
    import core_config_pkg::*;
    import bus_types_pkg::*;
    localparam int WORDS = BYTES / DBUS_BYTES;
    localparam int INDEX_W = $clog2(WORDS);
    logic [XLEN-1:0] mem [WORDS];
    logic [INDEX_W-1:0] word_index;

    // 范围/对齐检查由互连完成；bank 内只做字索引与 byte-enable。
    assign word_index = INDEX_W'((request.addr - XLEN'(BASE)) >> $clog2(DBUS_BYTES));
    assign req_ready = !rsp_valid || rsp_ready;
    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // RAM 不加复位清零，保留 FPGA BRAM 推断；复位只清除协议状态。
    always_ff @(posedge clk) begin
        if (rst) begin
            rsp_valid <= 1'b0;
            response <= '0;
        end else begin
            if (rsp_valid && rsp_ready)
                rsp_valid <= 1'b0;
            if (req_valid && req_ready) begin
                rsp_valid <= 1'b1;
                response.error <= BUS_OK;
                response.rdata <= request.write ? '0 : mem[word_index];
                if (request.write)
                    for (int b = 0; b < DBUS_BYTES; b++)
                        if (request.wstrb[b])
                            mem[word_index][b*8 +: 8] <= request.wdata[b*8 +: 8];
            end
        end
    end
endmodule
