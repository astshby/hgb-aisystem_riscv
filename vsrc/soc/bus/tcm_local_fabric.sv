// Module: tcm_local_fabric
// Description: Three-master two-bank TCM arbitration with retained response ownership and D/DMA priority.
module tcm_local_fabric (
    input logic clk, rst,
    input logic [2:0] m_req_valid,
    output logic [2:0] m_req_ready,
    input bus_types_pkg::bus_req_t m_request [3],
    input logic [2:0] m_bank,
    output logic [2:0] m_rsp_valid,
    input logic [2:0] m_rsp_ready,
    output bus_types_pkg::bus_rsp_t m_response [3],
    output logic [1:0] s_req_valid,
    input logic [1:0] s_req_ready,
    output bus_types_pkg::bus_req_t s_request [2],
    input logic [1:0] s_rsp_valid,
    output logic [1:0] s_rsp_ready,
    input bus_types_pkg::bus_rsp_t s_response [2]
);
    import bus_types_pkg::*;
    // bank 0/1 对应 ITCM/DTCM；主端 0/1/2 对应 I/D/DMA。请求已由 router 完整校验。
    logic [2:0] pending_q, m_rsp_fire;
    logic [1:0] busy_q, locked_q;
    logic [1:0] owner_q [2], next_q [2], locked_owner_q [2];
    logic [1:0] s_rsp_fire, s_req_fire, grant_valid, data_ready, dma_turn;
    logic [1:0] grant_owner [2];
    logic [2:0] eligible [2];

    // 返回路由只读取接受沿保存的 bank owner；router 的热响应 FF 吸收上游反压。
    always_comb begin
        m_rsp_valid = '0;
        for (int m = 0; m < 3; m++) m_response[m] = '0;
        s_rsp_ready = '0;
        for (int b = 0; b < 2; b++) begin
            if (busy_q[b]) begin
                m_rsp_valid[owner_q[b]] = s_rsp_valid[b];
                m_response[owner_q[b]] = s_response[b];
                s_rsp_ready[b] = m_rsp_ready[owner_q[b]];
            end
        end
    end
    assign s_rsp_fire = s_rsp_valid & s_rsp_ready;
    assign m_rsp_fire = m_rsp_valid & m_rsp_ready;
    assign s_req_fire = s_req_valid & s_req_ready;

    for (genvar b = 0; b < 2; b++) begin : g_eligibility
        for (genvar m = 0; m < 3; m++) begin : g_master
            // 保留原 D/DMA 同沿交接及涉及 I 的跨 owner 隔拍，本次不改变公平性策略。
            assign eligible[b][m] = m_req_valid[m] && m_bank[m] == 1'(b) &&
                (!pending_q[m] || m_rsp_fire[m]) &&
                (!busy_q[b] || owner_q[b] == 2'(m) ||
                 (m != 0 && owner_q[b] != '0 && s_rsp_fire[b]));
        end
        assign dma_turn[b] = eligible[b][2] && next_q[b] == 2'd2;
        // 此表达式不能改为读取总 grant：D-ready 必须独立于当前 I-valid。
        // 已锁定 D 时新到 DMA 不能压低 D-ready，否则 bank 会接受一笔源端未握手的请求。
        assign data_ready[b] = eligible[b][1] &&
                              (locked_q[b] ? locked_owner_q[b] == 2'd1 : !dma_turn[b]) &&
                              (!busy_q[b] || s_rsp_fire[b]) && s_req_ready[b];
    end

    // 不同 bank 并行；同 bank 沿用轮询、D 优先于 I、反压后锁定请求的规则。
    always_comb begin
        int candidate;
        candidate = 0;
        grant_valid = '0;
        s_req_valid = '0;
        for (int b = 0; b < 2; b++) begin
            grant_owner[b] = '0;
            s_request[b] = '0;
            if (!busy_q[b] || s_rsp_fire[b]) begin
                grant_valid[b] = |eligible[b];
                for (int offset = 2; offset >= 0; offset--) begin
                    candidate = int'(next_q[b]) + offset;
                    if (candidate >= 3) candidate -= 3;
                    if (eligible[b][candidate]) grant_owner[b] = 2'(candidate);
                end
                if (eligible[b][1] && grant_owner[b] == 0) grant_owner[b] = 2'd1;
                // 未接受的 I 可撤回；锁定的空授权到下一沿释放，不组合改授 D。
                if (locked_q[b]) begin
                    grant_valid[b] = eligible[b][locked_owner_q[b]];
                    grant_owner[b] = locked_owner_q[b];
                end
                if (grant_valid[b]) begin
                    s_req_valid[b] = 1'b1;
                    s_request[b] = m_request[grant_owner[b]];
                end
            end
        end
    end
    for (genvar m = 0; m < 3; m++) begin : g_ready
        if (m == 1) begin
            assign m_req_ready[m] = |data_ready;
        end else begin
            always_comb begin
                m_req_ready[m] = 1'b0;
                for (int b = 0; b < 2; b++)
                    if (grant_valid[b] && grant_owner[b] == 2'(m))
                        m_req_ready[m] = s_req_ready[b];
            end
        end
    end

    // owner 只在真实请求握手更新；同沿响应释放与新请求握手时保留新 owner。
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q <= '0;
            busy_q <= '0;
            locked_q <= '0;
            for (int b = 0; b < 2; b++) begin
                owner_q[b] <= '0;
                next_q[b] <= '0;
                locked_owner_q[b] <= '0;
            end
        end else begin
            pending_q <= pending_q & ~m_rsp_fire;
            busy_q <= busy_q & ~s_rsp_fire;
            for (int b = 0; b < 2; b++) begin
                locked_q[b] <= s_req_valid[b] && !s_req_ready[b];
                locked_owner_q[b] <= grant_owner[b];
                if (s_req_fire[b]) begin
                    pending_q[grant_owner[b]] <= 1'b1;
                    busy_q[b] <= 1'b1;
                    owner_q[b] <= grant_owner[b];
                    next_q[b] <= grant_owner[b] == 2'd2 ? '0 : grant_owner[b] + 2'd1;
                end
            end
        end
    end
endmodule
