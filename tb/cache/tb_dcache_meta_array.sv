// Module: tb_dcache_meta_array
// Description: Checks independent probe, line-update and LRU-touch ways against a metadata reference.
module tb_dcache_meta_array #(
    parameter int SETS = 64
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int SET_W = $clog2(SETS), TAG_W = 12;
    localparam logic [4:0] INVALIDATE = 5'b10000, INSTALL = 5'b01000;
    localparam logic [4:0] TOUCH = 5'b00100, DIRTY = 5'b00010, CLEAN = 5'b00001;
    logic clk = 0, rst = 1;
    logic [SET_W-1:0] lookup_set = '0;
    logic [TAG_W-1:0] lookup_tag = '0, install_tag = '0;
    logic hit, hit_way, victim_way;
    logic probe_way = 0, probe_valid, probe_dirty;
    logic [TAG_W-1:0] probe_tag;
    logic invalidate_entry = 0, install = 0, touch = 0, mark_dirty = 0, mark_clean = 0;
    logic update_way = 0, touch_way = 0;
    bit model_valid [SETS][2], model_dirty [SETS][2], model_lru [SETS];
    bit [TAG_W-1:0] model_tag [SETS][2];
    logic [31:0] random_state = 32'hc001_d00d;
    int checks = 0;
    always #5 clk = ~clk;

    dcache_meta_array #(.SETS(SETS), .TAG_W(TAG_W)) dut (.*);

    task automatic check_read;
        bit match0, match1, expected_victim;
        match0 = model_valid[lookup_set][0] && model_tag[lookup_set][0] == lookup_tag;
        match1 = model_valid[lookup_set][1] && model_tag[lookup_set][1] == lookup_tag;
        if (!model_valid[lookup_set][0]) expected_victim = 0;
        else if (!model_valid[lookup_set][1]) expected_victim = 1;
        else expected_victim = model_lru[lookup_set];
        assert (hit == (match0 || match1) && hit_way == match1 && victim_way == expected_victim)
            else $fatal(1, "metadata lookup/LRU mismatch check=%0d set=%0d", checks, lookup_set);
        assert (probe_valid == model_valid[lookup_set][probe_way] &&
                probe_dirty == (model_valid[lookup_set][probe_way] && model_dirty[lookup_set][probe_way]))
            else $fatal(1, "metadata probe status mismatch check=%0d", checks);
        if (probe_valid)
            assert (probe_tag == model_tag[lookup_set][probe_way])
                else $fatal(1, "metadata probe tag mismatch check=%0d", checks);
        checks++;
    endtask

    // 在下降沿驱动，分别检查写入沿前后的读结果；参考数组不读取 DUT 内部状态。
    task automatic cycle(input int set_index, input logic [TAG_W-1:0] tag_value,
                         input bit probe, input bit line_way, input bit lru_way,
                         input logic [4:0] controls, input bit reset_value = 0);
        @(negedge clk);
        rst = reset_value;
        lookup_set = SET_W'(set_index);
        lookup_tag = tag_value;
        install_tag = tag_value;
        probe_way = probe;
        update_way = line_way;
        touch_way = lru_way;
        {invalidate_entry, install, touch, mark_dirty, mark_clean} = controls;
        #1;
        check_read();
        @(posedge clk);
        if (rst) begin
            for (int s = 0; s < SETS; s++) begin
                model_valid[s][0] = 0; model_valid[s][1] = 0;
                model_dirty[s][0] = 0; model_dirty[s][1] = 0;
                model_lru[s] = 0;
            end
        end else begin
            // 保留原有重叠优先级：install 覆盖 invalidate，mark_dirty 覆盖 mark_clean。
            if (invalidate_entry) begin
                model_valid[lookup_set][update_way] = 0;
                model_dirty[lookup_set][update_way] = 0;
            end
            if (install) begin
                model_valid[lookup_set][update_way] = 1;
                model_dirty[lookup_set][update_way] = 0;
                model_tag[lookup_set][update_way] = install_tag;
            end
            if (mark_clean) model_dirty[lookup_set][update_way] = 0;
            if (mark_dirty) model_dirty[lookup_set][update_way] = 1;
            if (touch) model_lru[lookup_set] = !touch_way;
        end
        #1;
        check_read();
    endtask

    initial begin
        repeat (3) @(posedge clk);
        for (int s = 0; s < SETS; s++) begin
            cycle(s, TAG_W'(2*s+1), 0, 0, 1, INSTALL | TOUCH);
            cycle(s, TAG_W'(2*s+2), 1, 1, 0, INSTALL | TOUCH);
            cycle(s, TAG_W'(2*s+1), 0, 1, 0, DIRTY | TOUCH);
            cycle(s, TAG_W'(2*s+2), 1, 0, 1, INVALIDATE | TOUCH);
            cycle(s, TAG_W'(2*s+1), 0, 0, 1, INSTALL | DIRTY | CLEAN | TOUCH | INVALIDATE);
            cycle(s, TAG_W'(2*s+2), 1, 1, 0, CLEAN | TOUCH);
        end

        // 同 tag 同组的人工重叠保持 way 1 命中优先；实际控制器不应安装重复行。
        cycle(0, TAG_W'(12'h777), 0, 0, 1, INSTALL);
        cycle(0, TAG_W'(12'h777), 1, 1, 0, INSTALL);
        for (int n = 0; n < 512; n++) begin
            random_state = {random_state[30:0], random_state[31] ^ random_state[21] ^
                                                random_state[1] ^ random_state[0]};
            cycle(int'(random_state[15:8]) % SETS, random_state[27:16],
                  random_state[0], random_state[1], random_state[2], random_state[7:3]);
        end
        for (int s = 0; s < SETS; s++) begin
            cycle(s, model_tag[s][0], 0, 1, 0, '0);
            cycle(s, model_tag[s][1], 1, 0, 1, '0);
        end
        cycle(0, '1, 0, 0, 1, '1, 1);
        cycle(0, '1, 0, 0, 1, '0);
        $display("PASS tb_dcache_meta_array RV%0d SETS=%0d checks=%0d",
                 core_config_pkg::XLEN, SETS, checks);
        $finish;
    end
endmodule
