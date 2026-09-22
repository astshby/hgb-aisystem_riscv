// Module: tb_hazard_unit
// Description: Checks load-use dependency qualification and x0 suppression.
module tb_hazard_unit;
    timeunit 1ns;
    timeprecision 1ps;

    import pipeline_pkg::*;

    d2_ex_t producer;
    d1_d2_t consumer;
    logic load_use_stall;
    hazard_unit dut (.*);

    initial begin
        producer = '0;
        consumer = '0;
        producer.valid = 1'b1;
        producer.uop.mem_read = 1'b1;
        producer.uop.gpr_write = 1'b1;
        producer.rd = 5'd4;
        consumer.valid = 1'b1;
        consumer.uop.rs1_used = 1'b1;
        consumer.rs1 = 5'd4;
        #1;
        assert (load_use_stall) else $fatal(1, "missing load-use stall");
        consumer.rs1 = 5'd3; #1;
        assert (!load_use_stall) else $fatal(1, "false dependency");
        producer.rd = '0;
        consumer.rs1 = '0; #1;
        assert (!load_use_stall) else $fatal(1, "x0 dependency");
        producer.rd = 5'd4;
        consumer.rs1 = 5'd4;
        producer.exc.valid = 1'b1; #1;
        assert (!load_use_stall) else $fatal(1, "faulting load dependency");
        $display("PASS tb_hazard_unit");
        $finish;
    end
endmodule
