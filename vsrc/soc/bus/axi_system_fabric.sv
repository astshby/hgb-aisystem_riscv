// Module: axi_system_fabric
// Description: Buffered per-target AXI4 arbitration with master-prefixed IDs and ordered W ownership.
module axi_system_fabric #(
    parameter int MASTERS = 4,
    parameter int DDR_BYTES = 0,
    parameter int FLASH_BYTES = 0,
    parameter bit VIDEO_ENABLE = 1'b0,
    parameter int NPU_BYTES = 0,
    parameter int TARGETS = 7
) (
    input logic clk, rst,
    input axi_types_pkg::axi_req_t m_req [MASTERS],
    output axi_types_pkg::axi_rsp_t m_rsp [MASTERS],
    output axi_types_pkg::axi_req_t s_req [TARGETS],
    input axi_types_pkg::axi_rsp_t s_rsp [TARGETS]
);
    import axi_types_pkg::*;
    import soc_addr_pkg::*;
    // 目标固定为 ERROR、ROM、TCM、DDR、MMIO、Flash、可选 NPU SRAM。
    typedef logic [2:0] target_t;
    typedef logic [AXI_MASTER_W-1:0] owner_t;
    typedef struct packed {owner_t owner; logic [7:0] len;} write_owner_t;
    typedef struct packed {target_t target; axi_a_t address;} decoded_address_t;
    axi_req_t raw_req [MASTERS], in_req [MASTERS], out_req [TARGETS];
    axi_rsp_t raw_rsp [MASTERS];
    decoded_address_t decoded_ar [MASTERS], decoded_aw [MASTERS];
    axi_rsp_t in_rsp [MASTERS], out_rsp [TARGETS];
    target_t rd_target [MASTERS], wr_target [MASTERS];
    owner_t rd_next_q [TARGETS], wr_next_q [TARGETS];
    target_t r_next_q [MASTERS], b_next_q [MASTERS];
    logic [TARGETS-1:0] ar_locked_q, aw_locked_q;
    owner_t ar_owner_q [TARGETS], aw_owner_q [TARGETS];
    logic [MASTERS-1:0] r_locked_q, b_locked_q;
    target_t r_owner_q [MASTERS], b_owner_q [MASTERS];
    target_t r_selected [MASTERS], b_selected [MASTERS];
    logic [3:0] rd_busy_q [MASTERS], wr_busy_q [MASTERS];
    logic [MASTERS-1:0] aw_fire, ar_fire, b_fire, rlast_fire;
    logic [TARGETS-1:0] target_aw_fire, target_ar_fire;
    owner_t aw_owner [TARGETS], ar_owner [TARGETS];
    logic [MASTERS-1:0] route_valid, route_ready, route_pop;
    target_t route_head [MASTERS];
    logic [TARGETS-1:0] owner_valid, owner_ready, owner_pop;
    write_owner_t owner_in [TARGETS], owner_head [TARGETS];
    logic [7:0] write_beat_q [TARGETS];
    logic [MASTERS-1:0] ar_eligible [TARGETS], aw_eligible [TARGETS];
    logic [MASTERS-1:0] ar_grant [TARGETS], aw_grant [TARGETS], w_grant [TARGETS];
    logic [TARGETS-1:0] r_eligible [MASTERS], b_eligible [MASTERS];
    logic [TARGETS-1:0] r_grant [MASTERS], b_grant [MASTERS];

    function automatic logic fits(input logic [31:0] addr, input logic [32:0] limit,
                                  input logic [31:0] base, input int unsigned bytes);
        return bytes != 0 && {1'b0,addr} >= {1'b0,base} && limit <= {1'b0,base}+33'(bytes);
    endfunction
    function automatic target_t decode(input axi_a_t a, input logic writing);
        logic [32:0] limit;
        limit = {1'b0,a.addr} + ((33'(a.len)+1) << a.size);
        // 当前主端只产生对齐的 SINGLE/INCR，拒绝跨页、锁和超过四拍的突发。
        if (a.lock || a.size > 5 || a.len > 3 || a.burst != 2'b01 ||
            (a.addr & ((32'd1 << a.size)-1)) != 0 || limit > 33'h100000000 ||
            33'(a.addr[31:12]) != ((limit-1) >> 12)) return 0;
        if (fits(a.addr, limit, ROM_BASE, 16384) && !writing) return 1;
        if (fits(a.addr, limit, ITCM_BASE, 65536) ||
            fits(a.addr, limit, DTCM_BASE, 65536)) return 2;
        if (fits(a.addr, limit, DDR_BASE, DDR_BYTES)) return 3;
        if (!a.prot[2] && a.len == 0 && a.size <= 3 &&
            (fits(a.addr, limit, MTIME_BASE, 65536) ||
             fits(a.addr, limit, IRQ_BASE, 4194304) ||
             fits(a.addr, limit, UART0_BASE, VIDEO_ENABLE ? 32'h00080000 : 32'h00070000))) return 4;
        if (!writing && !a.prot[2] && fits(a.addr, limit, FLASH_BASE, FLASH_BYTES)) return 5;
        if (!a.prot[2] && fits(a.addr, limit, NPU_SRAM_BASE, NPU_BYTES)) return 6;
        return 0;
    endfunction
    // 固定编号并行屏蔽轮询起点之前的请求，前缀归约只选中最先的一项。
    function automatic logic [MASTERS-1:0] choose_master(
        input logic [MASTERS-1:0] eligible, input owner_t first);
        logic [MASTERS-1:0] masked, candidates, grant;
        for (int i = 0; i < MASTERS; i++) masked[i] = eligible[i] && owner_t'(i) >= first;
        candidates = |masked ? masked : eligible;
        for (int i = 0; i < MASTERS; i++)
            grant[i] = candidates[i] && !(|(candidates & ((MASTERS'(1) << i)-1'b1)));
        return grant;
    endfunction
    // 固定编号并行屏蔽轮询起点之前的请求，前缀归约只选中最先的一项。
    function automatic logic [TARGETS-1:0] choose_target(
        input logic [TARGETS-1:0] eligible, input target_t first);
        logic [TARGETS-1:0] masked, candidates, grant;
        for (int i = 0; i < TARGETS; i++) masked[i] = eligible[i] && target_t'(i) >= first;
        candidates = |masked ? masked : eligible;
        for (int i = 0; i < TARGETS; i++)
            grant[i] = candidates[i] && !(|(candidates & ((TARGETS'(1) << i)-1'b1)));
        return grant;
    endfunction
    for (genvar m = 0; m < MASTERS; m++) begin : g_master
        axi_register_slice u_entry (.clk, .rst, .s_req(m_req[m]), .s_rsp(m_rsp[m]),
                                    .m_req(raw_req[m]), .m_rsp(raw_rsp[m]));
        logic ar_valid, aw_valid, ar_ready, aw_ready;
        // 范围/权限译码独立寄存，下一拍才仲裁；宽地址加法不和多主端选择串联。
        rv_fifo #(.WIDTH($bits(decoded_address_t))) u_ar_decode (
            .clk,.rst,.in_valid(raw_req[m].ar_valid),.in_ready(ar_ready),
            .in_data({decode(raw_req[m].ar,1'b0),raw_req[m].ar}),
            .out_valid(ar_valid),.out_ready(in_rsp[m].ar_ready),.out_data(decoded_ar[m]),.occupancy());
        rv_fifo #(.WIDTH($bits(decoded_address_t))) u_aw_decode (
            .clk,.rst,.in_valid(raw_req[m].aw_valid),.in_ready(aw_ready),
            .in_data({decode(raw_req[m].aw,1'b1),raw_req[m].aw}),
            .out_valid(aw_valid),.out_ready(in_rsp[m].aw_ready),.out_data(decoded_aw[m]),.occupancy());
        always_comb begin
            in_req[m]=raw_req[m];
            in_req[m].ar_valid=ar_valid; in_req[m].ar=decoded_ar[m].address;
            in_req[m].aw_valid=aw_valid; in_req[m].aw=decoded_aw[m].address;
            raw_rsp[m]=in_rsp[m];
            raw_rsp[m].ar_ready=ar_ready; raw_rsp[m].aw_ready=aw_ready;
        end
        assign rd_target[m] = decoded_ar[m].target;
        assign wr_target[m] = decoded_aw[m].target;
        rv_fifo #(.WIDTH($bits(target_t)), .DEPTH(4)) u_write_route (
            .clk, .rst, .in_valid(aw_fire[m]), .in_ready(route_ready[m]), .in_data(wr_target[m]),
            .out_valid(route_valid[m]), .out_ready(route_pop[m]), .out_data(route_head[m]), .occupancy()
        );
        // 每个本地 ID 独立占槽。响应真正交还入口缓冲后释放，跨目标同 ID 不重排。
        always_ff @(posedge clk) begin
            if (rst) begin
                rd_busy_q[m] <= '0; wr_busy_q[m] <= '0;
                r_next_q[m] <= '0; b_next_q[m] <= '0;
                r_locked_q[m] <= 0; b_locked_q[m] <= 0; r_owner_q[m] <= 0; b_owner_q[m] <= 0;
            end else begin
                if (in_rsp[m].r_valid) begin r_locked_q[m] <= !in_req[m].r_ready; r_owner_q[m] <= r_selected[m]; end
                if (in_rsp[m].b_valid) begin b_locked_q[m] <= !in_req[m].b_ready; b_owner_q[m] <= b_selected[m]; end
                if (rlast_fire[m]) rd_busy_q[m][in_rsp[m].r.id[1:0]] <= 1'b0;
                if (b_fire[m]) wr_busy_q[m][in_rsp[m].b.id[1:0]] <= 1'b0;
                if (ar_fire[m]) rd_busy_q[m][in_req[m].ar.id[1:0]] <= 1'b1;
                if (aw_fire[m]) wr_busy_q[m][in_req[m].aw.id[1:0]] <= 1'b1;
                for (int t = 0; t < TARGETS; t++) begin
                    if (out_rsp[t].r_valid && out_req[t].r_ready && int'(out_rsp[t].r.id[3:2]) == m)
                        r_next_q[m] <= target_t'(t == TARGETS-1 ? 0 : t+1);
                    if (out_rsp[t].b_valid && out_req[t].b_ready && int'(out_rsp[t].b.id[3:2]) == m)
                        b_next_q[m] <= target_t'(t == TARGETS-1 ? 0 : t+1);
                end
            end
        end
    end
    for (genvar t = 0; t < TARGETS; t++) begin : g_target
        axi_register_slice u_exit (.clk, .rst, .s_req(out_req[t]), .s_rsp(out_rsp[t]),
                                   .m_req(s_req[t]), .m_rsp(s_rsp[t]));
        assign owner_in[t] = '{owner:aw_owner[t], len:out_req[t].aw.len};
        rv_fifo #(.WIDTH($bits(write_owner_t)), .DEPTH(4)) u_write_owner (
            .clk, .rst, .in_valid(target_aw_fire[t]), .in_ready(owner_ready[t]), .in_data(owner_in[t]),
            .out_valid(owner_valid[t]), .out_ready(owner_pop[t]), .out_data(owner_head[t]), .occupancy()
        );
        always_ff @(posedge clk) begin
            if (rst) begin
                rd_next_q[t] <= '0; wr_next_q[t] <= '0; write_beat_q[t] <= '0;
                ar_locked_q[t] <= 0; aw_locked_q[t] <= 0; ar_owner_q[t] <= 0; aw_owner_q[t] <= 0;
            end
            else begin
                if (out_req[t].ar_valid) begin ar_locked_q[t] <= !out_rsp[t].ar_ready; ar_owner_q[t] <= ar_owner[t]; end
                if (out_req[t].aw_valid) begin aw_locked_q[t] <= !out_rsp[t].aw_ready; aw_owner_q[t] <= aw_owner[t]; end
                if (target_ar_fire[t]) rd_next_q[t] <= ar_owner[t] == owner_t'(MASTERS-1) ? '0 : ar_owner[t]+1'b1;
                if (target_aw_fire[t]) wr_next_q[t] <= aw_owner[t] == owner_t'(MASTERS-1) ? '0 : aw_owner[t]+1'b1;
                if (out_req[t].w_valid && out_rsp[t].w_ready)
                    write_beat_q[t] <= owner_pop[t] ? '0 : write_beat_q[t]+1'b1;
            end
        end
    end

    // 资格只读固定主端/目标，避免旋转索引把宽载荷和 ready 串成优先选择链。
    // 锁定请求先限制候选，轮询起点和反压期间的 owner 与原协议相同。
    for (genvar t = 0; t < TARGETS; t++) begin : g_address_grant
        for (genvar m = 0; m < MASTERS; m++) begin : g_master_candidate
            assign ar_eligible[t][m] = in_req[m].ar_valid && rd_target[m] == target_t'(t) &&
                !rd_busy_q[m][in_req[m].ar.id[1:0]] && (!ar_locked_q[t] || ar_owner_q[t] == owner_t'(m));
            assign aw_eligible[t][m] = in_req[m].aw_valid && wr_target[m] == target_t'(t) &&
                !wr_busy_q[m][in_req[m].aw.id[1:0]] && route_ready[m] && owner_ready[t] &&
                (!aw_locked_q[t] || aw_owner_q[t] == owner_t'(m));
            // W 无 ID，必须同时匹配主端目标队列和目标 owner 队列。
            assign w_grant[t][m] = owner_valid[t] && owner_head[t].owner == owner_t'(m) &&
                route_valid[m] && route_head[m] == target_t'(t);
        end
        assign ar_grant[t] = choose_master(ar_eligible[t], rd_next_q[t]);
        assign aw_grant[t] = choose_master(aw_eligible[t], wr_next_q[t]);
    end
    for (genvar m = 0; m < MASTERS; m++) begin : g_response_grant
        for (genvar t = 0; t < TARGETS; t++) begin : g_target_candidate
            assign r_eligible[m][t] = out_rsp[t].r_valid && out_rsp[t].r.id[3:2] == owner_t'(m) &&
                (!r_locked_q[m] || r_owner_q[m] == target_t'(t));
            assign b_eligible[m][t] = out_rsp[t].b_valid && out_rsp[t].b.id[3:2] == owner_t'(m) &&
                (!b_locked_q[m] || b_owner_q[m] == target_t'(t));
        end
        assign r_grant[m] = choose_target(r_eligible[m], r_next_q[m]);
        assign b_grant[m] = choose_target(b_eligible[m], b_next_q[m]);
    end

    // 仲裁只进入出口 FIFO；即使新主端到达，已经展示给设备的地址/载荷也不会改变。
    // 独热授权分别归约载荷和窄握手；AW 同拍登记两份 W 顺序，仍可每拍接受。
    always_comb begin
        aw_fire = '0; ar_fire = '0; b_fire = '0; rlast_fire = '0;
        target_aw_fire = '0; target_ar_fire = '0;
        route_pop = '0; owner_pop = '0;
        for (int m = 0; m < MASTERS; m++) begin
            in_rsp[m] = '0; r_selected[m] = 0; b_selected[m] = 0;
        end
        for (int t = 0; t < TARGETS; t++) begin
            out_req[t] = '0;
            aw_owner[t] = '0; ar_owner[t] = '0;
            out_req[t].ar_valid = |ar_grant[t];
            out_req[t].aw_valid = |aw_grant[t];
            target_ar_fire[t] = out_req[t].ar_valid && out_rsp[t].ar_ready;
            target_aw_fire[t] = out_req[t].aw_valid && out_rsp[t].aw_ready;
            for (int m = 0; m < MASTERS; m++) begin
                out_req[t].ar |= in_req[m].ar & {$bits(axi_a_t){ar_grant[t][m]}};
                out_req[t].aw |= in_req[m].aw & {$bits(axi_a_t){aw_grant[t][m]}};
                ar_owner[t] |= owner_t'(m) & {AXI_MASTER_W{ar_grant[t][m]}};
                aw_owner[t] |= owner_t'(m) & {AXI_MASTER_W{aw_grant[t][m]}};
                in_rsp[m].ar_ready |= ar_grant[t][m] && out_rsp[t].ar_ready;
                in_rsp[m].aw_ready |= aw_grant[t][m] && out_rsp[t].aw_ready;
                ar_fire[m] |= ar_grant[t][m] && out_rsp[t].ar_ready;
                aw_fire[m] |= aw_grant[t][m] && out_rsp[t].aw_ready;
                out_req[t].w_valid |= w_grant[t][m] && in_req[m].w_valid;
                out_req[t].w |= in_req[m].w & {$bits(axi_w_t){w_grant[t][m]}};
                in_rsp[m].w_ready |= w_grant[t][m] && out_rsp[t].w_ready;
                // 以 AWLEN 消耗数据数量，错误 WLAST 留给目标报告，不能偷用下一笔 W。
                route_pop[m] |= w_grant[t][m] && in_req[m].w_valid && out_rsp[t].w_ready &&
                    write_beat_q[t] == owner_head[t].len;
            end
            out_req[t].ar.id[3:2] = ar_owner[t];
            out_req[t].aw.id[3:2] = aw_owner[t];
            owner_pop[t] = out_req[t].w_valid && out_rsp[t].w_ready && write_beat_q[t] == owner_head[t].len;
        end
        for (int m = 0; m < MASTERS; m++) begin
            in_rsp[m].r_valid = |r_grant[m];
            in_rsp[m].b_valid = |b_grant[m];
            rlast_fire[m] = in_req[m].r_ready;
            b_fire[m] = in_rsp[m].b_valid && in_req[m].b_ready;
            for (int t = 0; t < TARGETS; t++) begin
                in_rsp[m].r |= out_rsp[t].r & {$bits(axi_r_t){r_grant[m][t]}};
                in_rsp[m].b |= out_rsp[t].b & {$bits(axi_b_t){b_grant[m][t]}};
                r_selected[m] |= target_t'(t) & {3{r_grant[m][t]}};
                b_selected[m] |= target_t'(t) & {3{b_grant[m][t]}};
                out_req[t].r_ready |= r_grant[m][t] && in_req[m].r_ready;
                out_req[t].b_ready |= b_grant[m][t] && in_req[m].b_ready;
            end
            in_rsp[m].r.id[3:2] = '0;
            in_rsp[m].b.id[3:2] = '0;
            rlast_fire[m] &= in_rsp[m].r_valid && in_rsp[m].r.last;
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst) begin
        for (int t = 0; t < TARGETS; t++) begin
            assert ($onehot0(ar_grant[t]) && $onehot0(aw_grant[t]) && $onehot0(w_grant[t]))
                else $fatal(1, "fabric address/data grants overlap");
        end
        for (int m = 0; m < MASTERS; m++) begin
            assert ($onehot0(r_grant[m]) && $onehot0(b_grant[m]))
                else $fatal(1, "fabric response grants overlap");
        end
    end
    initial assert (MASTERS > 0 && MASTERS <= 4 && TARGETS == 7)
        else $fatal(1, "unsupported AXI fabric geometry");
`endif
endmodule
