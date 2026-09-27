// Module: mem_stage
// Description: Joins MDU results, issues memory requests, and carries metadata toward WB.
// DMem rsp 在 WB 响应，MEM 只发出访存请求；MDU rsp 则在本级与元数据拼包
module mem_stage (
    input  logic                              issue_enable,  // 表示当前是否允许访存
    output logic                              request_stall, // 请求尚未被存储器接受
    input  pipeline_pkg::ex_mem_t             in_packet,
    input  logic                              mdu_rsp_valid,
    input  core_types_pkg::xlen_t              mdu_rsp_data,
    output logic                              mdu_rsp_ready,
    output logic                              result_stall, // M 运算结果尚未返回
    output logic                              dmem_req_valid,
    output logic                              dmem_req_write,
    output core_types_pkg::xlen_t             dmem_req_addr,
    output core_types_pkg::xlen_t             dmem_req_wdata,
    output logic [core_config_pkg::DBUS_BYTES-1:0] dmem_req_wstrb,
    input  logic                              dmem_req_ready,
    output pipeline_pkg::mem_wb_t             out_packet,
    output pipeline_pkg::gpr_forward_t        gpr_forward,
    output pipeline_pkg::csr_forward_t        csr_forward
);
    import core_types_pkg::*;
    import pipeline_pkg::*;

    ex_mem_t mdu_packet;
    logic memory_request;
    logic packet_can_advance;
    xlen_t store_wdata;
    logic [core_config_pkg::DBUS_BYTES-1:0] store_wstrb;

    // EX/MEM 后汇合已寄存的 M 结果与元数据；Load 响应仍由 WB 接收。
    mem_mdu u_mem_mdu (
        .in_packet,
        .issue_enable,
        .rsp_valid(mdu_rsp_valid),
        .rsp_data(mdu_rsp_data),
        .rsp_ready(mdu_rsp_ready),
        .result_stall,
        .out_packet(mdu_packet)
    );

    // Store 数据根据地址低位移到对应字节通道。
    store_unit u_store_unit (
        .store_data(mdu_packet.store_data),
        .address(mdu_packet.result),
        .size(mdu_packet.uop.mem_size),
        .bus_wdata(store_wdata),
        .bus_wstrb(store_wstrb)
    );

    // DMem 请求：只有合法且无异常的 Load/Store 才能访问存储器。
    always_comb begin
        memory_request = mdu_packet.valid &&
                         (mdu_packet.uop.mem_read || mdu_packet.uop.mem_write) &&
                         !mdu_packet.exc.valid;
        dmem_req_valid = issue_enable && memory_request;
        dmem_req_write = mdu_packet.uop.mem_write;
        dmem_req_addr = mdu_packet.result;
        dmem_req_wdata = store_wdata;
        dmem_req_wstrb = store_wstrb;

        // 非访存指令直接前进；访存指令必须等请求握手完成。
        packet_can_advance = !memory_request || dmem_req_ready;
        request_stall = dmem_req_valid && !dmem_req_ready;
    end

    // 输出打包：Load 只携带地址进入 WB，返回数据不在 MEM 等待。
    always_comb begin
        out_packet = '0;
        out_packet.valid = issue_enable && mdu_packet.valid && packet_can_advance;
        out_packet.pc = mdu_packet.pc;
        out_packet.seq_pc = mdu_packet.seq_pc;
        out_packet.inst = mdu_packet.inst;
        out_packet.rd = mdu_packet.rd;
        out_packet.result = mdu_packet.result;
        out_packet.csr_addr = mdu_packet.csr_addr;
        out_packet.csr_old = mdu_packet.csr_old;
        out_packet.csr_new = mdu_packet.csr_new;
        out_packet.csr_we = mdu_packet.csr_we;
        out_packet.uop = mdu_packet.uop;
        out_packet.exc = mdu_packet.exc;
    end

    // MEM 前递：Load 必须等待 WB 响应，其他写回结果可直接前递。
    always_comb begin
        unique case (mdu_packet.uop.wb_sel)
            WB_SEQ_PC: gpr_forward.data = mdu_packet.seq_pc;
            WB_CSR:    gpr_forward.data = mdu_packet.csr_old;
            default:   gpr_forward.data = mdu_packet.result;
        endcase
        // Store 不写 GPR；Load 的数据此时尚未返回。
        // 结果可用与能否推进分开：WB 等待时，MEM 中已算好的值仍可供 EX 使用。
        gpr_forward.valid = mdu_packet.valid && mdu_packet.uop.gpr_write &&
                            (mdu_packet.uop.wb_sel != WB_LOAD) &&
                            !mdu_packet.exc.valid;
        gpr_forward.addr = mdu_packet.rd;
    end

    // CSR 前递携带 EX 已完成 WARL 合法化的新值。
    always_comb begin
        csr_forward.valid = mdu_packet.valid && mdu_packet.csr_we &&
                            !mdu_packet.exc.valid;
        csr_forward.addr = mdu_packet.csr_addr;
        csr_forward.data = mdu_packet.csr_new;
    end
endmodule
