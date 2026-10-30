// Module: tcm_system_target
// Description: System AXI access to the same core-domain TCM banks through an independent fourth local port and once-per-beat write precheck.
module tcm_system_target (
    input logic clk, rst,
    input axi_types_pkg::axi_req_t axi_req,
    output axi_types_pkg::axi_rsp_t axi_rsp,
    output logic [1:0] req_valid,
    input logic [1:0] req_ready,
    output bus_types_pkg::bus_req_t request [2],
    input logic [1:0] rsp_valid,
    output logic [1:0] rsp_ready,
    input logic [63:0] rsp_data [2]
);
    import bus_types_pkg::*;
    logic v, ready, rv, rr, active_q, bank_q, error_q;
    bus_req_t r;
    bus_rsp_t p;
    logic bank, legal, itcm_ok, dtcm_ok;
    axi_bus_target #(.REGISTER_WRITE_CHECK(1), .REGISTER_LOCAL_ADDR(1)) u_target (.clk,.rst,.axi_req,.axi_rsp,.req_valid(v),.req_ready(ready),.request(r),
        .rsp_valid(rv),.rsp_ready(rr),.response(p));
    // 目标已经固定为TCM，只做本地窗口/权限检查，省去全系统目标编码再译回bank。
    tcm_address_decode u_decode (.request(r), .itcm_ok, .dtcm_ok);
    assign bank = dtcm_ok;
    assign legal = itcm_ok || dtcm_ok;
    assign ready = !active_q && (!legal || req_ready[bank]);
    assign rv = active_q && (error_q || rsp_valid[bank_q]);
    assign p = '{rdata:core_types_pkg::xlen_t'(rsp_data[bank_q]),error:error_q ? BUS_SLVERR : BUS_OK};
    for (genvar b = 0; b < 2; b++) begin : g_bank
        assign request[b] = r;
        assign req_valid[b] = v && !active_q && legal && bank == 1'(b);
        assign rsp_ready[b] = rr && active_q && !error_q && bank_q == 1'(b);
    end
    always_ff @(posedge clk) begin
        if (rst) begin active_q <= 0; bank_q <= 0; error_q <= 0; end
        else begin
            if (v && ready) begin active_q <= 1; bank_q <= bank; error_q <= !legal; end
            if (rv && rr) active_q <= 0;
        end
    end
endmodule
