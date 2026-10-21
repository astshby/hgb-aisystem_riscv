// Module: sim_dmem_dual
// Description: One-cycle tagged dual-port simulation RAM with byte writes and same-word arbitration.
module sim_dmem_dual #(
    parameter int unsigned DEPTH_WORDS = 4096
) (
    input logic clk, rst,
    input logic [1:0] req_valid,
    output logic [1:0] req_ready,
    input scoreboard_pkg::memory_request_t request [2],
    output logic [1:0] rsp_valid,
    input logic [1:0] rsp_ready,
    output scoreboard_pkg::memory_response_t response [2]
);
    import core_config_pkg::*;
    logic [XLEN-1:0] mem [DEPTH_WORDS];
    logic [$clog2(DEPTH_WORDS)-1:0] index [2];
    assign index[0] = request[0].address[$clog2(DBUS_BYTES) +: $clog2(DEPTH_WORDS)];
    assign index[1] = request[1].address[$clog2(DBUS_BYTES) +: $clog2(DEPTH_WORDS)];
    assign req_ready[0] = !rst && (!rsp_valid[0] || rsp_ready[0]);
    // 同字的读写不能依赖仿真器的 NBA 更新顺序；较低端口优先，其余请求保留。
    assign req_ready[1] = !rst && (!rsp_valid[1] || rsp_ready[1]) &&
        !(req_valid[0] && req_ready[0] && index[0] == index[1] && (request[0].write || request[1].write));
    always_ff @(posedge clk) begin
        if (rst) rsp_valid <= 0;
        else begin
            for (int lane = 0; lane < 2; lane++) begin
                if (rsp_ready[lane]) rsp_valid[lane] <= 0;
                if (req_valid[lane] && req_ready[lane]) begin
                    rsp_valid[lane] <= 1;
                    response[lane] <= '{id:request[lane].id, data:mem[index[lane]], error:1'b0};
                    if (request[lane].write)
                        for (int byte_no = 0; byte_no < DBUS_BYTES; byte_no++)
                            if (request[lane].wstrb[byte_no])
                                mem[index[lane]][8*byte_no +: 8] <= request[lane].wdata[8*byte_no +: 8];
                end
            end
        end
    end
endmodule
