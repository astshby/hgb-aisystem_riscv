// Module: tb_scoreboard_scheduler_metrics
// Description: Checks overlapping RAW/resource observations, accepted operations and recovery boundaries.
module tb_scoreboard_scheduler_metrics;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1, flush = 0, mdu_available = 1;
    branch_recovery_t recovery;
    logic [RETIRE_IDX_W-1:0] head_slot = 0;
    logic [3:0] valid_slots, eligible;
    d2_ex_t packets [4], selected [2];
    retire_gpr_entry_t producers [RETIRE_ENTRIES];
    logic [1:0] accept_count;
    scoreboard_scheduler_metrics #(.DEPTH(4)) dut (.*);
    always #5 clk = ~clk;
    function automatic retire_id_t tag(input int slot);
        return '{slot:RETIRE_IDX_W'(slot), generation:RETIRE_GEN_W'(1)};
    endfunction
    task automatic idle;
        valid_slots = 0; eligible = 0; accept_count = 0; recovery = '0; flush = 0; mdu_available = 1;
        for (int slot = 0; slot < 4; slot++) begin
            packets[slot] = '0; packets[slot].valid = 1; packets[slot].retire_id = tag(slot);
        end
        for (int lane = 0; lane < 2; lane++) selected[lane] = '0;
    endtask
    task automatic tick;
        @(posedge clk); #1; @(negedge clk); idle();
    endtask
    initial begin
        idle(); for (int slot = 0; slot < RETIRE_ENTRIES; slot++) producers[slot] = '0;
        producers[5] = '{valid:1, id:tag(5), kind:RET_LOAD, gpr_write:1, default:'0};
        producers[6] = '{valid:1, id:tag(6), kind:RET_MDU, gpr_write:1, default:'0};
        producers[7] = '{valid:1, id:tag(7), kind:RET_EXEC, gpr_write:1, default:'0};
        tick(); rst = 0; tick();
        valid_slots = 7; eligible = 4; mdu_available = 0;
        packets[0].rs1_dependency = '{pending:1, id:tag(5)};
        packets[1].uop.fu = FU_MULDIV;
        selected[0] = packets[2]; accept_count = 1; tick();
        valid_slots = 15; eligible = 15; selected[0] = packets[0]; selected[1] = packets[1];
        accept_count = 2; tick();
        valid_slots = 7; mdu_available = 0;
        packets[0].rs1_dependency = '{pending:1, id:tag(6)};
        packets[1].uop.fu = FU_MULDIV;
        packets[2].rs1_dependency = '{pending:1, id:tag(7)}; tick();
        valid_slots = 7; mdu_available = 0; flush = 1;
        packets[0].rs1_dependency = '{pending:1, id:tag(5)};
        packets[1].uop.fu = FU_MULDIV; tick();
        valid_slots = 15; recovery = '{valid:1, id:tag(1), pc:'0};
        packets[0].rs1_dependency = '{pending:1, id:tag(5)}; tick();
        assert (dut.cycles == 6 && dut.occupied_cycles == 5 && dut.ready_cycles == 2 && dut.full_cycles == 2 &&
                dut.raw_cycles == 2 && dut.raw_alu_cycles == 1 && dut.raw_mdu_cycles == 1 && dut.raw_load_cycles == 1 &&
                dut.mdu_resource_cycles == 2 && dut.mdu_iq_idle_cycles == 1 && dut.accepted_cycles == 2 &&
                dut.accepted_operations == 3 && dut.bypass_raw_cycles == 1 && dut.bypass_mdu_cycles == 1)
            else $fatal(1, "scheduler metrics counts or flush/recovery boundaries");
        $display("PASS tb_scoreboard_scheduler_metrics XLEN=%0d overlap tagged_RAW MDU_bypass full recovery", XLEN);
        $finish;
    end
endmodule
