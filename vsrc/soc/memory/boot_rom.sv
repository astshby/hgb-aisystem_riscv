// Module: boot_rom
// Description: Registered reset trampoline with a repeating JALR tail into the preloaded ITCM image.
module boot_rom (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import soc_addr_pkg::*;
    import bus_types_pkg::*;
    localparam logic [31:0] BOOT_LUI = {ITCM_BASE[31:12], 5'd5, 7'h37};
    localparam logic [31:0] BOOT_JUMP = 32'h00028067;
    xlen_t rom_word;

    // 当前只负责跳转；镜像预加载由仿真/FPGA 初始化完成，不假装具备下载器。
    // word 0 之外的每个字都重复 JALR：第二次取指字丢失或被重复时，下一条仍是跳转，
    // 用已装载的 x5 进入 ITCM，不会沿 ROM 顺序滑到 0x4000 才以取指错误暴露故障。
    always_comb begin
        rom_word = (XLEN == 64) ? XLEN'({BOOT_JUMP, BOOT_JUMP}) : XLEN'(BOOT_JUMP);
        if ((request.addr >> $clog2(DBUS_BYTES)) == 0)
            rom_word = (XLEN == 64) ? XLEN'({BOOT_JUMP, BOOT_LUI}) : XLEN'(BOOT_LUI);
    end
    assign req_ready = !rsp_valid || rsp_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            rsp_valid <= 1'b0;
            response <= '0;
        end else begin
            if (rsp_valid && rsp_ready)
                rsp_valid <= 1'b0;
            if (req_valid && req_ready) begin
                rsp_valid <= 1'b1;
                response.rdata <= rom_word;
                response.error <= BUS_OK;
            end
        end
    end
endmodule
