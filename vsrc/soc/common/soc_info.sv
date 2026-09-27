// Module: soc_info
// Description: Read-only identification, clock, and local-memory capacity registers.
module soc_info #(
    parameter logic [31:0] CLOCK_HZ = 50000000
) (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response
);
    logic [31:0] read_data, write_data, write_mask;
    logic access_error, access_fire;
    mmio_endpoint u_mmio (
        .clk, .rst, .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready,
        .response, .read_data, .access_error, .access_fire, .write_data, .write_mask
    );
    always_comb begin
        access_error = request.write;
        read_data = '0;
        case (request.addr[11:0])
            12'h000: read_data = 32'(core_config_pkg::XLEN);
            12'h004: read_data = CLOCK_HZ;
            12'h008: read_data = soc_config_pkg::ITCM_BYTES;
            12'h00c: read_data = soc_config_pkg::DTCM_BYTES;
            default: access_error = 1'b1;
        endcase
    end
endmodule
