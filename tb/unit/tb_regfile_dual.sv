// Module: tb_regfile_dual
// Description: Checks four read ports and ordered dual writes against an independent register model.
module tb_regfile_dual;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;

    logic clk = 1'b0;
    gpr_addr_t rs1_addr, rs2_addr, rs1_addr_1, rs2_addr_1;
    xlen_t rs1_data, rs2_data, rs1_data_1, rs2_data_1;
    logic write_enable, write_enable_1;
    gpr_addr_t write_addr, write_addr_1;
    xlen_t write_data, write_data_1;
    xlen_t model [32];
    logic [31:0] random_state = 32'h72ea192b;
    int checks, collisions, read_through, xzero;
    always #5 clk = ~clk;
    regfile dut (.*);

    function automatic logic [31:0] random_word;
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        return random_state;
    endfunction

    task automatic check_reads(input bit before_edge);
        xlen_t expected [4];
        gpr_addr_t addresses [4];
        xlen_t observed [4];
        addresses = '{rs1_addr, rs2_addr, rs1_addr_1, rs2_addr_1};
        observed = '{rs1_data, rs2_data, rs1_data_1, rs2_data_1};
        for (int port = 0; port < 4; port++) begin
            expected[port] = model[addresses[port]];
            if (before_edge && write_enable && write_addr != '0 && write_addr == addresses[port]) begin
                expected[port] = write_data;
                read_through++;
            end
            if (before_edge && ISSUE_WIDTH == 2 && write_enable_1 &&
                write_addr_1 != '0 && write_addr_1 == addresses[port]) begin
                expected[port] = write_data_1;
                read_through++;
            end
            if (addresses[port] == '0 || (port >= 2 && ISSUE_WIDTH == 1)) expected[port] = '0;
            assert (observed[port] == expected[port])
                else $fatal(1, "GPR port=%0d addr=%0d before=%0d got=%h expected=%h", port,
                            addresses[port], before_edge, observed[port], expected[port]);
            checks++;
        end
    endtask

    task automatic cycle;
        #1;
        check_reads(1'b1);
        @(posedge clk);
        if (write_enable && write_addr != '0) model[write_addr] = write_data;
        // 软件按退休顺序写两次，明确年轻写者覆盖老写者；不借用DUT内部寄存数组。
        if (ISSUE_WIDTH == 2 && write_enable_1 && write_addr_1 != '0) model[write_addr_1] = write_data_1;
        if (write_enable && write_enable_1 && write_addr == write_addr_1 && write_addr != '0) collisions++;
        if ((write_enable && write_addr == '0) || (write_enable_1 && write_addr_1 == '0)) xzero++;
        #1;
        check_reads(1'b0);
        @(negedge clk);
    endtask

    initial begin
        checks = 0; collisions = 0; read_through = 0; xzero = 0;
        foreach (model[index]) model[index] = '0;
        rs1_addr = '0; rs2_addr = '0; rs1_addr_1 = '0; rs2_addr_1 = '0;
        write_enable = 1'b0; write_enable_1 = 1'b0;
        write_addr = '0; write_addr_1 = '0; write_data = '0; write_data_1 = '0;
        @(negedge clk);
        // 无复位数据阵列先逐项初始化；不把仿真器默认零当作硬件契约。
        for (int index = 1; index < 32; index++) begin
            write_enable = 1'b1; write_addr = gpr_addr_t'(index); write_data = '0;
            cycle();
        end
        for (int iteration = 0; iteration < 2000; iteration++) begin
            write_enable = 1'(random_word()); write_enable_1 = 1'(random_word());
            write_addr = gpr_addr_t'(random_word()); write_addr_1 = gpr_addr_t'(random_word());
            write_data = xlen_t'({random_word(), random_word()});
            write_data_1 = xlen_t'({random_word(), random_word()});
            rs1_addr = gpr_addr_t'(random_word()); rs2_addr = gpr_addr_t'(random_word());
            rs1_addr_1 = gpr_addr_t'(random_word()); rs2_addr_1 = gpr_addr_t'(random_word());
            if (iteration % 4 == 0) begin
                write_enable = 1'b1; write_enable_1 = 1'b1;
                write_addr_1 = write_addr;
                rs1_addr = write_addr; rs2_addr = write_addr;
                rs1_addr_1 = write_addr; rs2_addr_1 = write_addr;
            end
            cycle();
        end
        assert (collisions > 100 && read_through > 100 && xzero > 10) else $fatal(1, "GPR coverage");
        $display("PASS tb_regfile_dual RV%0d issue=%0d checks=%0d collisions=%0d bypass=%0d x0=%0d",
                 XLEN, ISSUE_WIDTH, checks, collisions, read_through, xzero);
        $finish;
    end
endmodule
