// Module: tb_core_m_wait
// Description: Checks MDU response holding, delayed memory, drained WB operands, and exact retirement.
module tb_core_m_wait;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import rv_asm_pkg::*;

    localparam int LOAD_DELAY = (MUL_IMPL == MUL_SHIFT) ? XLEN + 9 : 9;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic imem_req_valid;
    xlen_t imem_req_addr;
    logic imem_req_ready;
    logic imem_rsp_valid;
    logic [31:0] imem_rsp_data;
    logic imem_rsp_ready;
    logic dmem_req_valid;
    logic dmem_req_write;
    xlen_t dmem_req_addr;
    xlen_t dmem_req_wdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic dmem_req_ready;
    logic dmem_rsp_valid;
    xlen_t dmem_rsp_rdata;
    logic dmem_rsp_ready;
    logic commit_valid;
    xlen_t commit_pc;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic commit_rd_we;
    xlen_t commit_rd_data;
    logic commit_exception;
    logic load_pending_q;
    xlen_t load_data_q;
    int load_delay_q;
    int store_delay_q;
    int loads;
    int stores;
    logic held_result_seen;
    logic drained_operand_seen;
    xlen_t stored_value;
    xlen_t expected [12];
    int retired = 0;

    always #5 clk = ~clk;
    core dut (.*);
    sim_imem #(.DEPTH_WORDS(32)) u_imem (
        .clk, .rst,
        .req_valid(imem_req_valid), .req_addr(imem_req_addr), .req_ready(imem_req_ready),
        .rsp_valid(imem_rsp_valid), .rsp_data(imem_rsp_data), .rsp_ready(imem_rsp_ready)
    );

    // Load 通常等待九拍；移位乘法更慢，延长到 XLEN+9 以覆盖结果早于 Load 返回。
    // 每次 Store 首次可见后等待六拍才接收，禁止重复请求。
    assign dmem_req_ready = !load_pending_q && (!dmem_rsp_valid || dmem_rsp_ready) &&
                           (!dmem_req_write || store_delay_q >= 6);

    always_ff @(posedge clk) begin
        if (rst) begin
            load_pending_q <= 1'b0;
            load_delay_q <= 0;
            store_delay_q <= 0;
            dmem_rsp_valid <= 1'b0;
            dmem_rsp_rdata <= '0;
            load_data_q <= '0;
            loads <= 0;
            stores <= 0;
            stored_value <= '0;
            held_result_seen <= 1'b0;
            drained_operand_seen <= 1'b0;
        end else begin
            if (dut.wb_wait && dut.u_ex_stage.u_ex_mdu.rsp_valid)
                held_result_seen <= 1'b1;
            if (dut.mem_request_stall && commit_valid && commit_rd_we && commit_rd == gpr_addr_t'(5))
                drained_operand_seen <= 1'b1;
            if (dmem_rsp_valid && dmem_rsp_ready)
                dmem_rsp_valid <= 1'b0;
            if (load_pending_q) begin
                if (load_delay_q == 0) begin
                    load_pending_q <= 1'b0;
                    dmem_rsp_valid <= 1'b1;
                    dmem_rsp_rdata <= load_data_q;
                end else
                    load_delay_q <= load_delay_q - 1;
            end
            if (dmem_req_valid && dmem_req_write && !dmem_req_ready)
                store_delay_q <= store_delay_q + 1;
            if (dmem_req_valid && dmem_req_ready) begin
                if (dmem_req_write) begin
                    stores <= stores + 1;
                    store_delay_q <= 0;
                    assert (dmem_req_wstrb[3:0] == 4'b1111)
                        else $fatal(1, "M wait Store lanes");
                    if (dmem_req_addr == xlen_t'(8)) begin
                        assert (stores == 0 && dmem_req_wdata[31:0] == 32'd50)
                            else $fatal(1, "M wait first Store repeated or wrong data");
                        // LW 地址 8 在 RV64 字对齐返回通道的低四字节。
                        stored_value <= xlen_t'(50);
                    end else
                        assert (dmem_req_addr == xlen_t'(16) && stores == 1 &&
                                dmem_req_wdata[31:0] == 32'd7)
                            else $fatal(1, "M wait final Store repeated or wrong data");
                end else begin
                    loads <= loads + 1;
                    load_pending_q <= 1'b1;
                    load_delay_q <= LOAD_DELAY;
                    assert ((dmem_req_addr == '0 && loads == 0) ||
                            (dmem_req_addr == xlen_t'(8) && loads == 1))
                        else $fatal(1, "M wait Load repeated or wrong address");
                    load_data_q <= (dmem_req_addr == '0) ? xlen_t'(41) : stored_value;
                end
            end
        end
    end

    initial begin
        for (int idx = 0; idx < 32; idx++) u_imem.mem[idx] = nop();
        u_imem.mem[0] = enc_addi(1, 0, 7); expected[0] = xlen_t'(7);
        u_imem.mem[1] = enc_lw(2, 0, 0); expected[1] = xlen_t'(41);
        u_imem.mem[2] = enc_mul(3, 1, 1); expected[2] = xlen_t'(49);
        u_imem.mem[3] = enc_addi(4, 3, 1); expected[3] = xlen_t'(50);
        u_imem.mem[4] = enc_addi(5, 0, 9); expected[4] = xlen_t'(9);
        u_imem.mem[5] = enc_sw(4, 0, 8); expected[5] = '0;
        u_imem.mem[6] = enc_div(6, 5, 1); expected[6] = xlen_t'(1);
        u_imem.mem[7] = enc_mul(7, 6, 2); expected[7] = xlen_t'(41);
        u_imem.mem[8] = enc_lw(8, 0, 8); expected[8] = xlen_t'(50);
        u_imem.mem[9] = enc_div(9, 8, 1); expected[9] = xlen_t'(7);
        u_imem.mem[10] = enc_sw(9, 0, 16); expected[10] = '0;
        u_imem.mem[11] = enc_addi(10, 0, 1); expected[11] = xlen_t'(1);
        u_imem.mem[12] = enc_jal(0, 0);
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (int cycles = 0; cycles < 1000; cycles++) begin
            @(negedge clk);
            if (commit_valid) begin
                assert (!commit_exception && commit_pc == xlen_t'(retired*4) &&
                        commit_inst == u_imem.mem[retired])
                    else $fatal(1, "M wait duplicate/out-of-order retirement pc=%h expected=%0d", commit_pc, retired*4);
                if (retired == 5 || retired == 10)
                    assert (!commit_rd_we) else $fatal(1, "Store wrote GPR");
                else
                    assert (commit_rd_we && commit_rd_data == expected[retired])
                        else $fatal(1, "M wait pc=%h got=%h expected=%h", commit_pc, commit_rd_data, expected[retired]);
                retired++;
                if (retired == 12) begin
                    assert (loads == 2 && stores == 2 && held_result_seen && drained_operand_seen)
                        else $fatal(1, "M wait coverage loads=%0d stores=%0d held=%b drained=%b",
                                    loads, stores, held_result_seen, drained_operand_seen);
                    $display("PASS tb_core_m_wait RV%0d cycles=%0d", XLEN, cycles);
                    break;
                end
            end
        end
        assert (retired == 12) else $fatal(1, "M wait program timeout");
        $finish;
    end
endmodule
