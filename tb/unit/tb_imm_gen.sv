// Module: tb_imm_gen
// Description: Checks I, S, B, U, and J immediate reconstruction.
module tb_imm_gen;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import rv_asm_pkg::*;

    logic [31:0] inst;
    logic [XLEN-1:0] imm;
    imm_gen dut (.*);

    initial begin
        inst = enc_addi(5'd2, 5'd1, -17); #1;
        assert ($signed(imm) == -17) else $fatal(1, "I immediate");
        inst = enc_sw(5'd2, 5'd1, -12); #1;
        assert ($signed(imm) == -12) else $fatal(1, "S immediate");
        inst = enc_beq(5'd1, 5'd2, -20); #1;
        assert ($signed(imm) == -20) else $fatal(1, "B immediate");
        inst = enc_lui(5'd3, 20'habcde); #1;
        assert (imm[31:12] == 20'habcde) else $fatal(1, "U immediate");
        inst = enc_jal(5'd1, 2046); #1;
        assert ($signed(imm) == 2046) else $fatal(1, "J immediate");
        $display("PASS tb_imm_gen RV%0d", XLEN);
        $finish;
    end
endmodule
