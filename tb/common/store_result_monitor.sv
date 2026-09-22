// Module: store_result_monitor
// Description: Passively decodes a completed Store as a testbench PASS/FAIL result.
module store_result_monitor (
    input  logic                                  clk,
    input  logic                                  rst,
    input  logic [core_config_pkg::XLEN-1:0]      result_addr,
    input  logic                                  dmem_store_fire,
    input  logic [core_config_pkg::XLEN-1:0]      dmem_store_addr,
    input  logic [core_config_pkg::XLEN-1:0]      dmem_store_data,
    input  logic [core_config_pkg::DBUS_BYTES-1:0] dmem_store_strb,
    output logic                                  test_done,
    output logic                                  test_pass,
    output logic [31:0]                           test_code
);
    always_ff @(posedge clk) begin
        if (rst) begin
            test_done <= 1'b0;
            test_pass <= 1'b0;
            test_code <= '0;
        end else if (dmem_store_fire && (dmem_store_addr == result_addr) &&
                     (&dmem_store_strb[3:0])) begin
            // riscv-tests 约定 1 为 PASS，其余奇数值编码失败测试号。
            test_done <= 1'b1;
            test_pass <= (dmem_store_data[31:0] == 32'd1);
            test_code <= dmem_store_data[31:0];
        end
    end
endmodule
