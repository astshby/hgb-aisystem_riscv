// Module: tb_core_m
// Description: Checks every M instruction, forwarding, load-use, zero registers, and single retirement.
module tb_core_m;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic commit_valid;
    xlen_t commit_pc;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic commit_rd_we;
    xlen_t commit_rd_data;
    logic commit_exception;
    logic dmem_store_fire;
    xlen_t dmem_store_addr;
    xlen_t dmem_store_data;
    logic [DBUS_BYTES-1:0] dmem_store_strb;
    logic [31:0] program_inst [128];
    xlen_t expected_data [128];
    logic expected_write [128];
    int program_size = 0;
    int retired = 0;
    int stores = 0;
    int m_waits = 0;
    int load_bubbles = 0;
    xlen_t minimum;
    xlen_t misa;

    always #5 clk = ~clk;
    sim_cpu_top dut (.*);

    task automatic append(input logic [31:0] inst, input xlen_t expected, input logic writes = 1'b1);
        program_inst[program_size] = inst;
        expected_data[program_size] = expected;
        expected_write[program_size] = writes && (inst[11:7] != 5'd0);
        dut.u_imem.mem[program_size] = inst;
        program_size++;
    endtask

    initial begin
        for (int idx = 0; idx < 128; idx++) dut.u_imem.mem[idx] = nop();
        minimum = xlen_t'(1) << (XLEN-1);
        misa = ((XLEN == 32) ? xlen_t'(1) : xlen_t'(2)) << (XLEN-2);
        misa = misa | xlen_t'(32'h1100);

        append(enc_addi(1, 0, -7), xlen_t'(-7));
        append(enc_addi(2, 0, 3), xlen_t'(3));
        append(enc_addi(3, 0, 100), xlen_t'(100));
        append(enc_mul(4, 1, 2), xlen_t'(-21));
        append(enc_addi(5, 4, 1), xlen_t'(-20));
        append(enc_mulh(6, 1, 2), '1);
        append(enc_mulhsu(7, 1, 2), '1);
        append(enc_mulhu(8, 1, 2), xlen_t'(2));
        append(enc_div(9, 1, 2), xlen_t'(-2));
        append(enc_rem(10, 1, 2), '1);
        append(enc_divu(11, 1, 2), xlen_t'(-7) / xlen_t'(3));
        append(enc_remu(12, 1, 2), '0);
        append(enc_mul(13, 9, 2), xlen_t'(-6));
        append(enc_div(14, 4, 2), xlen_t'(-7));
        append(enc_div(15, 1, 0), '1);
        append(enc_rem(16, 1, 0), xlen_t'(-7));
        append(enc_mul(0, 1, 2), '0);
        append(enc_addi(31, 0, 0), '0);
        append(enc_addi(20, 0, 1), xlen_t'(1));
        append(enc_slli(20, 20, XLEN-1), minimum);
        append(enc_addi(21, 0, -1), '1);
        append(enc_div(22, 20, 21), minimum);
        append(enc_rem(23, 20, 21), '0);
        append(enc_mulh(24, 20, 20), xlen_t'(1) << (XLEN-2));
        append(enc_mulhsu(25, 20, 20), xlen_t'(3) << (XLEN-2));
        append(enc_mulhu(26, 20, 20), xlen_t'(1) << (XLEN-2));
        append(enc_sw(13, 0, 0), '0, 1'b0);
        append(enc_lw(27, 0, 0), xlen_t'(-6));
        append(enc_mul(28, 27, 2), xlen_t'(-18));
        append(enc_csrrs(29, CSR_MISA, 0), misa);
        append(enc_addi(30, 0, -21), xlen_t'(-21));
        append(enc_bne(4, 30, 12), '0, 1'b0); // M 结果参与分支，正确路径不跳转。

        if (XLEN == 64) begin
            // 高 32 位刻意含噪声，检查 W 运算只观察低 32 位。
            append(enc_addi(1, 0, -1), '1);
            append(enc_addi(2, 0, 7), xlen_t'(7));
            append(enc_slli(2, 2, 32), xlen_t'(64'h0000_0007_0000_0000));
            append(enc_addi(2, 2, 3), xlen_t'(64'h0000_0007_0000_0003));
            append(enc_lui(3, 20'h80000), xlen_t'($signed(32'h8000_0000)));
            append(enc_addi(3, 3, -1), xlen_t'(64'hffff_ffff_7fff_ffff));
            append(enc_mulw(4, 3, 2), xlen_t'(32'h7fff_fffd));
            append(enc_divw(5, 3, 2), xlen_t'(715827882));
            append(enc_divuw(6, 1, 2), xlen_t'(1431655765));
            append(enc_remw(7, 3, 2), xlen_t'(1));
            append(enc_remuw(8, 1, 2), '0);
            append(enc_addi(9, 0, 1), xlen_t'(1));
            append(enc_divuw(10, 1, 9), '1); // UW 的结果也必须符号扩展。
            append(enc_remuw(11, 1, 0), '1);
            append(enc_lui(12, 20'h80000), xlen_t'($signed(32'h8000_0000)));
            append(enc_divw(13, 12, 1), xlen_t'($signed(32'h8000_0000)));
            append(enc_remw(14, 12, 1), '0);
        end
        append(enc_addi(30, 0, 1), xlen_t'(1));
        dut.u_imem.mem[program_size] = enc_jal(0, 0);

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (int cycles = 0; cycles < 5000; cycles++) begin
            @(negedge clk);
            if (dut.u_core.execution_stall) m_waits++;
            if (dut.u_core.load_use_stall) load_bubbles++;
            if (dmem_store_fire) begin
                stores++;
                assert (dmem_store_addr == '0 && dmem_store_data[31:0] == 32'hffff_fffa &&
                        dmem_store_strb[3:0] == 4'b1111)
                    else $fatal(1, "M store data/lanes");
            end
            if (commit_valid) begin
                assert (!commit_exception && commit_pc == xlen_t'(retired * 4) &&
                        commit_inst == program_inst[retired])
                    else $fatal(1, "M instruction retired twice/out of order pc=%h expected=%0d", commit_pc, retired*4);
                assert (commit_rd_we == expected_write[retired])
                    else $fatal(1, "M GPR write qualification pc=%h", commit_pc);
                if (commit_rd_we)
                    assert (commit_rd == program_inst[retired][11:7] &&
                            commit_rd_data == expected_data[retired])
                        else $fatal(1, "M pc=%h got=%h expected=%h", commit_pc, commit_rd_data, expected_data[retired]);
                retired++;
                if (retired == program_size) begin
                    assert (stores == 1 && m_waits > 0 && load_bubbles > 0)
                        else $fatal(1, "M pipeline coverage incomplete");
                    $display("PASS tb_core_m RV%0d retired=%0d cycles=%0d", XLEN, retired, cycles);
                    break;
                end
            end
        end
        assert (retired == program_size) else $fatal(1, "M program timeout");
        $finish;
    end
endmodule
