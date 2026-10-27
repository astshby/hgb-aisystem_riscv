// Module: tb_dma_block
// Description: Real DMA, local TCM, block fabric and AXI memory checked against independent byte and transaction models.
module tb_dma_block;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import soc_addr_pkg::*;
    localparam int BYTES = 65536;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;
    logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 0, irq;
    bus_req_t request = '0;
    bus_rsp_t response;
    logic [1:0] m_req_valid, m_req_ready, m_rsp_valid, m_rsp_ready;
    bus_req_t m_request [2];
    bus_rsp_t m_response [2];
    logic [15:0] s_req_valid, s_req_ready, s_rsp_valid, s_rsp_ready;
    bus_req_t s_request [16];
    bus_rsp_t s_response [16];
    bus_error_e s_error [16];
    logic wide_req_valid, wide_req_ready, wide_rsp_valid, wide_rsp_ready;
    ddr_req_t wide_request;
    ddr_rsp_t wide_response;
    logic blk_rd_cmd_valid, blk_rd_cmd_ready, blk_rd_valid, blk_rd_ready;
    block_cmd_t blk_rd_cmd;
    block_r_t blk_rd_data;
    logic blk_wr_cmd_valid, blk_wr_cmd_ready, blk_wr_valid, blk_wr_ready, blk_wr_rsp_valid, blk_wr_rsp_ready;
    block_cmd_t blk_wr_cmd;
    block_w_t blk_wr_data;
    block_b_t blk_wr_rsp;
    logic f_rd_cmd_ready, f_rd_valid, f_wr_cmd_ready, f_wr_ready, f_wr_rsp_valid;
    block_r_t f_rd_data;
    block_b_t f_wr_rsp;
    logic [1:0] cache_rd_cmd_valid, cache_rd_cmd_ready, cache_rd_valid, cache_rd_ready;
    block_cmd_t cache_rd_cmd [2];
    block_r_t cache_rd_data [2];
    logic [1:0] cache_wr_cmd_ready, cache_wr_ready, cache_wr_rsp_valid;
    block_cmd_t cache_wr_cmd [2];
    block_w_t cache_wr_data [2];
    block_b_t cache_wr_rsp [2];
    logic rd_cmd_valid, rd_cmd_ready, rd_valid, rd_ready;
    block_cmd_t rd_cmd;
    block_r_t rd_data;
    logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid, wr_rsp_ready;
    block_cmd_t wr_cmd;
    block_w_t wr_data;
    block_b_t wr_rsp;
    logic awvalid, awready, awid, awlock, wvalid, wready, wlast;
    logic arvalid, arready, arid, arlock, bvalid, bready, bid, rvalid, rready, rid, rlast;
    logic [31:0] awaddr, araddr;
    logic [7:0] awlen, arlen;
    logic [2:0] awsize, arsize, awprot, arprot;
    logic [1:0] awburst, arburst, bresp, rresp;
    logic [3:0] awcache, awqos, awregion, arcache, arqos, arregion;
    logic [255:0] wdata, rdata;
    logic [31:0] wstrb;
    logic [31:0] fault_read_addr = '1, fault_write_addr = '1;
    byte unsigned golden [3*BYTES];
    typedef struct packed {
        logic [31:0] offset;
        int bytes;
        logic ready, failed;
    } model_block_t;
    model_block_t blocks[$], removed;
    block_cmd_t read_owner_cmd, write_owner_cmd;
    bus_req_t narrow_owner;
    logic read_owner = 0, write_owner = 0, narrow_pending = 0;
    int read_index, write_index, planned, confirmed, model_code, model_fault_offset;
    logic [31:0] model_fault_addr, source_address, destination_address;
    int length, test_mode = 0, test_cycles, checks = 0, case_number = 0;
    int block_reads, block_writes, read_errors, write_errors, error_order, first_error_order;
    int multi_reads, multi_writes, outstanding_overlap, physical_overlap, max_blocks;
    int narrow_reads, narrow_writes, held_read_error, held_write_error, simultaneous_errors;
    int competitor_reads, competitor_beats;
    logic physical_read_owner, physical_write_owner;
    logic case_active = 0, release_gate = 0, competition = 0, competitor_active;
    logic hold_read_cmd, hold_write_cmd, hold_read_data, hold_write_data, hold_write_response;
    logic observed_error, expected_config_error;
    logic [31:0] random_state = 32'h5344_1282;

    dma_controller #(.DDR_BYTES(BYTES), .WIDE_ENABLE(1), .BLOCK_ENABLE(1)) dut (
        .clk, .rst, .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready, .response, .irq,
        .master_req_valid(m_req_valid[0]), .master_req_ready(m_req_ready[0]), .master_request(m_request[0]),
        .master_rsp_valid(m_rsp_valid[0]), .master_rsp_ready(m_rsp_ready[0]), .master_response(m_response[0]),
        .wide_req_valid, .wide_req_ready, .wide_request, .wide_rsp_valid, .wide_rsp_ready, .wide_response,
        .blk_rd_cmd_valid, .blk_rd_cmd_ready, .blk_rd_cmd, .blk_rd_valid, .blk_rd_ready, .blk_rd_data,
        .blk_wr_cmd_valid, .blk_wr_cmd_ready, .blk_wr_cmd, .blk_wr_valid, .blk_wr_ready, .blk_wr_data,
        .blk_wr_rsp_valid, .blk_wr_rsp_ready, .blk_wr_rsp
    );
    assign m_req_valid[1] = 0;
    assign m_request[1] = '0;
    assign m_rsp_ready[1] = 1;
    bus_interconnect #(.MASTERS(2), .PRESENT(16'h400d), .DDR_BYTES(BYTES)) local_fabric (
        .clk, .rst, .m_req_valid, .m_req_ready, .m_request, .m_rsp_valid, .m_rsp_ready, .m_response,
        .s_req_valid, .s_req_ready, .s_request, .s_error, .s_rsp_valid, .s_rsp_ready, .s_response
    );
    bus_error_slave local_error (.clk, .rst, .req_valid(s_req_valid[0]), .req_ready(s_req_ready[0]),
        .req_error(s_error[0]), .rsp_valid(s_rsp_valid[0]), .rsp_ready(s_rsp_ready[0]), .response(s_response[0]));
    tcm_controller #(.BASE(ITCM_BASE), .BYTES(BYTES)) itcm (.clk, .rst,
        .req_valid(s_req_valid[2]), .req_ready(s_req_ready[2]), .request(s_request[2]),
        .rsp_valid(s_rsp_valid[2]), .rsp_ready(s_rsp_ready[2]), .response(s_response[2]));
    tcm_controller #(.BASE(DTCM_BASE), .BYTES(BYTES)) dtcm (.clk, .rst,
        .req_valid(s_req_valid[3]), .req_ready(s_req_ready[3]), .request(s_request[3]),
        .rsp_valid(s_rsp_valid[3]), .rsp_ready(s_rsp_ready[3]), .response(s_response[3]));
    for (genvar target = 1; target < 14; target++) begin : g_absent
        if (target != 2 && target != 3) begin
            assign s_req_ready[target] = 0;
            assign s_rsp_valid[target] = 0;
            assign s_response[target] = '0;
        end
    end

    // 门控只在case开始时拉低，并在确定事件后单向释放；不会撤回已经展示的响应valid。
    assign hold_read_cmd = !release_gate &&
        ((test_mode == 4 && blk_rd_cmd.addr == xlen_t'(32'(source_address+128))) || test_mode == 8);
    assign hold_write_cmd = !release_gate && test_mode == 1;
    assign hold_read_data = !release_gate &&
        (((test_mode == 3 || test_mode == 5) && read_owner_cmd.addr == xlen_t'(32'(source_address+128))) || test_mode == 7);
    assign hold_write_data = !release_gate && (test_mode == 9 || test_mode == 12);
    assign hold_write_response = !release_gate && (test_mode == 2 || test_mode == 5 || test_mode == 6 || test_mode == 10);
    assign blk_rd_cmd_ready = f_rd_cmd_ready && !hold_read_cmd;
    assign blk_rd_valid = f_rd_valid && !hold_read_data;
    assign blk_rd_data = f_rd_data;
    assign blk_wr_cmd_ready = f_wr_cmd_ready && !hold_write_cmd;
    assign blk_wr_ready = f_wr_ready && !hold_write_data;
    assign blk_wr_rsp_valid = f_wr_rsp_valid && !hold_write_response;
    assign blk_wr_rsp = f_wr_rsp;
    ddr_block_fabric #(.DDR_BYTES(BYTES)) fabric (
        .clk, .rst,
        .cpu_req_valid(s_req_valid[14]), .cpu_req_ready(s_req_ready[14]), .cpu_request(s_request[14]),
        .cpu_rsp_valid(s_rsp_valid[14]), .cpu_rsp_ready(s_rsp_ready[14]), .cpu_response(s_response[14]),
        .dma_req_valid(wide_req_valid), .dma_req_ready(wide_req_ready), .dma_request(wide_request),
        .dma_rsp_valid(wide_rsp_valid), .dma_rsp_ready(wide_rsp_ready), .dma_response(wide_response),
        .cache_rd_cmd_valid, .cache_rd_cmd_ready, .cache_rd_cmd, .cache_rd_valid, .cache_rd_ready, .cache_rd_data,
        .cache_wr_cmd_valid(2'b0), .cache_wr_cmd_ready, .cache_wr_cmd,
        .cache_wr_valid(2'b0), .cache_wr_ready, .cache_wr_data,
        .cache_wr_rsp_valid, .cache_wr_rsp_ready(2'b11), .cache_wr_rsp,
        .dma_block_rd_cmd_valid(blk_rd_cmd_valid && !hold_read_cmd), .dma_block_rd_cmd_ready(f_rd_cmd_ready), .dma_block_rd_cmd(blk_rd_cmd),
        .dma_block_rd_valid(f_rd_valid), .dma_block_rd_ready(blk_rd_ready && !hold_read_data), .dma_block_rd_data(f_rd_data),
        .dma_block_wr_cmd_valid(blk_wr_cmd_valid && !hold_write_cmd), .dma_block_wr_cmd_ready(f_wr_cmd_ready), .dma_block_wr_cmd(blk_wr_cmd),
        .dma_block_wr_valid(blk_wr_valid && !hold_write_data), .dma_block_wr_ready(f_wr_ready), .dma_block_wr_data(blk_wr_data),
        .dma_block_wr_rsp_valid(f_wr_rsp_valid), .dma_block_wr_rsp_ready(blk_wr_rsp_ready && !hold_write_response), .dma_block_wr_rsp(f_wr_rsp),
        .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data,
        .wr_cmd_valid, .wr_cmd_ready, .wr_cmd, .wr_valid, .wr_ready, .wr_data, .wr_rsp_valid, .wr_rsp_ready, .wr_rsp
    );
    block_to_axi #(.DDR_BYTES(BYTES)) bridge (.*);
    axi_block_memory_model #(.BYTES(BYTES)) memory (
        .clk, .rst, .fault_read_addr, .fault_write_addr,
        .awvalid, .awready, .awid, .awaddr, .awlen, .awsize,
        .wvalid, .wready, .wdata, .wstrb, .wlast, .bvalid, .bready, .bid, .bresp,
        .arvalid, .arready, .arid, .araddr, .arlen, .arsize,
        .rvalid, .rready, .rid, .rdata, .rresp, .rlast
    );

    function automatic int byte_index(input logic [31:0] address);
        if (address >= DDR_BASE && address < DDR_BASE+BYTES) return int'(address-DDR_BASE);
        if (address >= ITCM_BASE && address < ITCM_BASE+BYTES) return BYTES+int'(address-ITCM_BASE);
        if (address >= DTCM_BASE && address < DTCM_BASE+BYTES) return 2*BYTES+int'(address-DTCM_BASE);
        $fatal(1, "Reference address outside memory %h", address);
        return 0;
    endfunction
    function automatic int expected_block_bytes(input int offset);
        int bytes;
        bytes = ((length-offset)/32)*32;
        if (bytes > 128) bytes = 128;
        if (bytes > 4096-int'((source_address+32'(offset))%4096)) bytes = 4096-int'((source_address+32'(offset))%4096);
        if (bytes > 4096-int'((destination_address+32'(offset))%4096)) bytes = 4096-int'((destination_address+32'(offset))%4096);
        return bytes;
    endfunction
    function automatic logic [31:0] random_word;
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        return random_state;
    endfunction
    task automatic record_error(input int offset, code, input logic [31:0] address);
        if (model_code == 0 || offset < model_fault_offset) begin
            model_code = code;
            model_fault_offset = offset;
            model_fault_addr = address;
        end
    endtask

    // cache client读取同一份DDR，不模拟第二个RAM；持续竞争下也必须最终完成DMA。
    assign cache_rd_cmd_valid = {1'b0, competition && !competitor_active};
    assign cache_rd_ready = 2'b11;
    always_comb begin
        cache_rd_cmd[0] = '{addr:xlen_t'(32'(DDR_BASE+32'he000)), len:8'd1, size:3'd5, execute:1'b0};
        cache_rd_cmd[1] = '0;
        for (int i = 0; i < 2; i++) begin cache_wr_cmd[i] = '0; cache_wr_data[i] = '0; end
    end
    always_ff @(posedge clk) begin
        if (rst) begin competitor_active <= 0; competitor_beats <= 0; competitor_reads <= 0; end
        else begin
            if (cache_rd_cmd_valid[0] && cache_rd_cmd_ready[0]) begin competitor_active <= 1; competitor_beats <= 0; end
            if (cache_rd_valid[0]) begin
                assert (cache_rd_data[0].error == BUS_OK && cache_rd_data[0].last == (competitor_beats == 1))
                    else $fatal(1, "Competing read framing/error");
                for (int lane = 0; lane < 32; lane++)
                    assert (cache_rd_data[0].data[lane*8 +: 8] == golden['he000+competitor_beats*32+lane])
                        else $fatal(1, "Competing reader got DMA data");
                competitor_beats <= competitor_beats + 1;
                if (cache_rd_data[0].last) begin competitor_active <= 0; competitor_reads <= competitor_reads + 1; end
            end
        end
    end

    // 独立命令队列从握手构建；不用DUT的槽/指针/计数器作预期。
    always @(posedge clk) if (!rst && case_active) begin
        int offset, amount, source_byte, destination_byte;
        model_block_t item;
        test_cycles++;
        assert (!wide_req_valid) else $fatal(1, "BLOCK1 leaked legacy wide request");
        if (read_owner && write_owner) outstanding_overlap++;
        if (physical_read_owner && physical_write_owner) physical_overlap++;
        if (arvalid && arready) physical_read_owner = 1;
        if (rvalid && rready && rlast) physical_read_owner = 0;
        if (awvalid && awready) physical_write_owner = 1;
        if (bvalid && bready) physical_write_owner = 0;
        if (blk_rd_cmd_valid && !blk_rd_cmd_ready && blk_wr_rsp_valid && blk_wr_rsp_ready && blk_wr_rsp.error != BUS_OK)
            held_read_error++;
        if (blk_wr_cmd_valid && !blk_wr_cmd_ready && blk_rd_valid && blk_rd_ready && blk_rd_data.error != BUS_OK)
            held_write_error++;
        if (blk_rd_valid && blk_rd_ready && blk_rd_data.error != BUS_OK &&
            blk_wr_rsp_valid && blk_wr_rsp_ready && blk_wr_rsp.error != BUS_OK) simultaneous_errors++;
        if (blk_rd_cmd_valid && blk_rd_cmd_ready) begin
            assert (!read_owner && !narrow_pending && !expected_config_error && blocks.size() < 2)
                else $fatal(1, "Read owner/capacity violation");
            amount = expected_block_bytes(planned);
            assert (blk_rd_cmd.addr == xlen_t'(32'(source_address+32'(planned))) && blk_rd_cmd.size == 5 &&
                    !blk_rd_cmd.execute && (int'(blk_rd_cmd.len)+1)*32 == amount && amount >= 32)
                else $fatal(1, "Block planner mismatch read=%h planned=%0d bytes=%0d len=%0d", blk_rd_cmd.addr, planned, amount, blk_rd_cmd.len);
            item = '{offset:32'(planned), bytes:amount, ready:1'b0, failed:1'b0};
            blocks.push_back(item);
            if (blocks.size() > max_blocks) max_blocks = blocks.size();
            planned += amount;
            read_owner_cmd = blk_rd_cmd; read_owner = 1; read_index = 0;
            block_reads++; if (blk_rd_cmd.len != 0) multi_reads++;
        end
        if (blk_rd_valid && blk_rd_ready) begin
            assert (read_owner && blk_rd_data.last == (read_index == int'(read_owner_cmd.len)))
                else $fatal(1, "Read owner/last mismatch");
            offset = int'(read_owner_cmd.addr)-int'(source_address);
            for (int i = 0; i < blocks.size(); i++) if (blocks[i].offset == 32'(offset)) begin
                if (blk_rd_data.error != BUS_OK) begin
                    blocks[i].failed = 1;
                    record_error(offset, blk_rd_data.error == BUS_DECERR ? 2 : 3, 32'(read_owner_cmd.addr));
                    read_errors++; error_order++;
                    if (first_error_order == 0) first_error_order = 1;
                end
                if (blk_rd_data.last) blocks[i].ready = 1;
            end
            if (blk_rd_data.last) read_owner = 0;
            read_index++;
        end
        if (blk_wr_cmd_valid && blk_wr_cmd_ready) begin
            assert (!write_owner && !narrow_pending && blocks.size() > 0 && blocks[0].ready && !blocks[0].failed)
                else $fatal(1, "Write of incomplete/failed block or duplicate owner");
            assert (blk_wr_cmd.addr == xlen_t'(32'(destination_address+32'(confirmed))) &&
                    blocks[0].offset == 32'(confirmed) && (int'(blk_wr_cmd.len)+1)*32 == blocks[0].bytes &&
                    blk_wr_cmd.size == 5 && !blk_wr_cmd.execute)
                else $fatal(1, "Write not oldest confirmed-prefix successor");
            write_owner_cmd = blk_wr_cmd; write_owner = 1; write_index = 0;
            block_writes++; if (blk_wr_cmd.len != 0) multi_writes++;
        end
        if (blk_wr_valid && blk_wr_ready) begin
            assert (write_owner && blk_wr_data.strb == '1 && blk_wr_data.last == (write_index == int'(write_owner_cmd.len)))
                else $fatal(1, "W owner/mask/last mismatch");
            offset = int'(write_owner_cmd.addr)-int'(destination_address)+write_index*32;
            for (int lane = 0; lane < 32; lane++) begin
                source_byte = byte_index(source_address+32'(offset+lane));
                destination_byte = byte_index(destination_address+32'(offset+lane));
                assert (blk_wr_data.data[lane*8 +: 8] == golden[source_byte]) else $fatal(1, "DMA block byte mismatch");
                if (32'(write_owner_cmd.addr)+32'(write_index*32) != fault_write_addr)
                    golden[destination_byte] = golden[source_byte];
            end
            write_index++;
        end
        if (blk_wr_rsp_valid && blk_wr_rsp_ready) begin
            assert (write_owner && write_index == int'(write_owner_cmd.len)+1) else $fatal(1, "B before W or no owner");
            if (blk_wr_rsp.error == BUS_OK) confirmed += blocks[0].bytes;
            else begin
                record_error(int'(blocks[0].offset), blk_wr_rsp.error == BUS_DECERR ? 4 : 5, 32'(write_owner_cmd.addr));
                write_errors++; error_order++;
                if (first_error_order == 0) first_error_order = 2;
            end
            removed = blocks.pop_front();
            write_owner = 0;
        end
        if (m_req_valid[0] && m_req_ready[0]) begin
            assert (!narrow_pending && !read_owner && !write_owner && blocks.size() == 0 && planned == confirmed && !expected_config_error)
                else $fatal(1, "Narrow fallback crossed outstanding block");
            amount = ((source_address+32'(confirmed))%DBUS_BYTES == 0 &&
                      (destination_address+32'(confirmed))%DBUS_BYTES == 0 && length-confirmed >= DBUS_BYTES) ? DBUS_BYTES : 1;
            assert (m_request[0].addr == xlen_t'(32'((m_request[0].write ? destination_address : source_address)+32'(confirmed))) &&
                    (1 << int'(m_request[0].size)) == amount) else $fatal(1, "Narrow address/width mismatch");
            narrow_owner = m_request[0]; narrow_pending = 1;
            if (m_request[0].write) begin
                for (int lane = 0; lane < DBUS_BYTES; lane++) begin
                    int base, index;
                    base = int'(m_request[0].addr) & ~(DBUS_BYTES-1);
                    index = base+lane-int'(destination_address);
                    assert (m_request[0].wstrb[lane] == (index >= confirmed && index < confirmed+amount))
                        else $fatal(1, "Narrow strobe mismatch");
                    if (m_request[0].wstrb[lane]) begin
                        assert (m_request[0].wdata[lane*8 +: 8] == golden[byte_index(source_address+32'(index))])
                            else $fatal(1, "Narrow byte lane mismatch");
                        if (32'(m_request[0].addr) != fault_write_addr)
                            golden[byte_index(32'(base+lane))] = golden[byte_index(source_address+32'(index))];
                    end
                end
                narrow_writes++;
            end else narrow_reads++;
        end
        if (m_rsp_valid[0] && m_rsp_ready[0]) begin
            assert (narrow_pending) else $fatal(1, "Narrow response without owner");
            if (m_response[0].error != BUS_OK)
                record_error(confirmed, narrow_owner.write ? 5 : 3, 32'(narrow_owner.addr));
            else if (narrow_owner.write) begin confirmed += (1 << int'(narrow_owner.size)); planned = confirmed; end
            narrow_pending = 0;
        end
    end

    // 所有展示包独立采样；任何另一方向错误都不能让valid提前撤回或改写payload。
    logic held_rc = 0, held_wc = 0, held_w = 0, held_n = 0;
    block_cmd_t saved_rc, saved_wc;
    block_w_t saved_w;
    bus_req_t saved_n;
    always_ff @(posedge clk) begin
        if (rst) begin held_rc <= 0; held_wc <= 0; held_w <= 0; held_n <= 0; end
        else begin
            if (held_rc) assert (blk_rd_cmd_valid && blk_rd_cmd == saved_rc) else $fatal(1, "Read offer withdrawn");
            if (held_wc) assert (blk_wr_cmd_valid && blk_wr_cmd == saved_wc) else $fatal(1, "Write offer withdrawn");
            if (held_w) assert (blk_wr_valid && blk_wr_data == saved_w) else $fatal(1, "W changed while blocked");
            if (held_n) assert (m_req_valid[0] && m_request[0] == saved_n) else $fatal(1, "Narrow offer changed");
            held_rc <= blk_rd_cmd_valid && !blk_rd_cmd_ready; saved_rc <= blk_rd_cmd;
            held_wc <= blk_wr_cmd_valid && !blk_wr_cmd_ready; saved_wc <= blk_wr_cmd;
            held_w <= blk_wr_valid && !blk_wr_ready; saved_w <= blk_wr_data;
            held_n <= m_req_valid[0] && !m_req_ready[0]; saved_n <= m_request[0];
        end
    end

    task automatic tick;
        @(posedge clk); @(negedge clk); #1;
    endtask
    task automatic access(input bit writing, input int offset, input logic [31:0] value,
                          output logic [31:0] result, input bus_error_e expected = BUS_OK);
        request = '0; request.addr = xlen_t'(32'(DMA_BASE+32'(offset))); request.size = MEM_WORD;
        request.write = writing;
        request.wdata = xlen_t'(value) << (8*(offset%DBUS_BYTES));
        request.wstrb = DBUS_BYTES'(15 << (offset%DBUS_BYTES));
        req_valid = 1;
        do tick(); while (!rsp_valid && !req_ready);
        // mmio_endpoint ready可同沿释放响应；请求只维持到第一次接受。
        req_valid = 0;
        while (!rsp_valid) tick();
        assert (response.error == expected) else $fatal(1, "MMIO offset=%h error=%0d expected=%0d", offset, response.error, expected);
        result = 32'(response.rdata >> (8*(offset%DBUS_BYTES)));
        rsp_ready = 1; tick(); rsp_ready = 0;
    endtask
    task automatic write_reg(input int offset, input logic [31:0] value, input bus_error_e expected = BUS_OK);
        logic [31:0] ignored;
        access(1, offset, value, ignored, expected);
    endtask
    task automatic initialize_case(input logic [31:0] src, dst, input int bytes, mode,
                                   input logic [31:0] read_fault = '1, write_fault = '1);
        case_active = 0; competition = 0;
        while (competitor_active) tick();
        source_address = src; destination_address = dst; length = bytes; test_mode = mode;
        fault_read_addr = read_fault; fault_write_addr = write_fault; release_gate = 0;
        for (int i = 0; i < BYTES; i++) begin
            // 高地址位参与花样，避免相隔256B的源/目的初值相同掩盖漏写。
            golden[i] = 8'((i*13+case_number*7+3) ^ (i>>8));
            golden[BYTES+i] = 8'((i*19+case_number*3+5) ^ (i>>8));
            golden[2*BYTES+i] = 8'((i*23+case_number*11+9) ^ (i>>8));
            memory.mem[i/DBUS_BYTES][(i%DBUS_BYTES)*8 +: 8] = golden[i];
            itcm.mem[i/DBUS_BYTES][(i%DBUS_BYTES)*8 +: 8] = golden[BYTES+i];
            dtcm.mem[i/DBUS_BYTES][(i%DBUS_BYTES)*8 +: 8] = golden[2*BYTES+i];
        end
        blocks.delete(); read_owner = 0; write_owner = 0; narrow_pending = 0;
        planned = 0; confirmed = 0; model_code = 0; model_fault_offset = 0; model_fault_addr = 0;
        test_cycles = 0; block_reads = 0; block_writes = 0; multi_reads = 0; multi_writes = 0;
        read_errors = 0; write_errors = 0; error_order = 0; first_error_order = 0;
        outstanding_overlap = 0; physical_overlap = 0; max_blocks = 0;
        physical_read_owner = 0; physical_write_owner = 0; narrow_reads = 0; narrow_writes = 0;
        held_read_error = 0; held_write_error = 0; simultaneous_errors = 0;
        expected_config_error = 0;
        case_active = 1;
        write_reg(0, src); write_reg(4, dst); write_reg(8, 32'(bytes));
    endtask
    task automatic wait_finished;
        logic [31:0] status, bytes, code, fault;
        status = 1;
        for (int timeout = 0; timeout < 15000 && status[0]; timeout++) begin
            if ((test_mode == 1 || test_mode == 2 || test_mode == 12) && read_errors > 0) release_gate = 1;
            if ((test_mode == 3 || test_mode == 4) && write_errors > 0) release_gate = 1;
            if (test_mode == 5 && f_rd_valid && f_wr_rsp_valid && read_owner_cmd.addr == xlen_t'(32'(source_address+128))) release_gate = 1;
            if ((test_mode == 6 || test_mode == 7) && test_cycles > 100) release_gate = 1;
            access(0, 16, 0, status);
        end
        assert (!status[0]) else $fatal(1, "DMA timeout case=%0d mode=%0d model=%0d", case_number, test_mode, model_code);
        assert (!read_owner && !write_owner && !narrow_pending && !physical_read_owner && !physical_write_owner)
            else $fatal(1, "DMA finished with an external owner");
        access(0, 20, 0, bytes); access(0, 24, 0, fault); access(0, 28, 0, code);
        assert (bytes == 32'(confirmed) && code == 32'(model_code) && fault == model_fault_addr &&
                status[2:1] == (model_code == 0 ? 2'b01 : 2'b10) && irq)
            else $fatal(1, "Finish mismatch case=%0d bytes=%0d/%0d code=%0d/%0d fault=%h/%h status=%h",
                        case_number, bytes, confirmed, code, model_code, fault, model_fault_addr, status);
        if (model_code == 0) assert (confirmed == length) else $fatal(1, "Short success");
        for (int i = 0; i < BYTES; i++) begin
            assert (memory.mem[i/DBUS_BYTES][(i%DBUS_BYTES)*8 +: 8] == golden[i]) else $fatal(1, "DDR byte mismatch at %0d case=%0d", i, case_number);
            assert (itcm.mem[i/DBUS_BYTES][(i%DBUS_BYTES)*8 +: 8] == golden[BYTES+i]) else $fatal(1, "ITCM byte mismatch");
            assert (dtcm.mem[i/DBUS_BYTES][(i%DBUS_BYTES)*8 +: 8] == golden[2*BYTES+i]) else $fatal(1, "DTCM byte mismatch");
        end
        write_reg(16, 6);
        assert (!irq) else $fatal(1, "W1C IRQ did not clear");
        $display("DMA_BLOCK case=%0d mode=%0d len=%0d confirmed=%0d code=%0d cycles=%0d R/W=%0d/%0d multi=%0d/%0d slots=%0d overlap=%0d AXIoverlap=%0d narrow=%0d/%0d order=%0d heldR/W=%0d/%0d simultaneous=%0d",
            case_number, test_mode, length, confirmed, model_code, test_cycles, block_reads, block_writes,
            multi_reads, multi_writes, max_blocks, outstanding_overlap, physical_overlap, narrow_reads, narrow_writes,
            first_error_order, held_read_error, held_write_error, simultaneous_errors);
        checks++; case_number++;
    endtask

    initial begin
        int count, offset;
        int boundary_lengths [11] = '{1,31,32,33,64,96,127,128,129,256,257};
        logic [31:0] ignored;
        if ($value$plusargs("SEED=%d", random_state)) begin end
        @(negedge clk); repeat (3) tick(); rst = 0;
        initialize_case(DDR_BASE+'h1000, DDR_BASE+'h9000, 1024, 0);
        write_reg(12, 3); wait_finished();
        assert (max_blocks == 2 && multi_reads > 0 && multi_writes > 0 && outstanding_overlap > 0 && physical_overlap > 0)
            else $fatal(1, "No real bounded burst/read-write overlap");
        initialize_case(DDR_BASE+'h0fc0, DDR_BASE+'h7fe0, 640, 0);
        write_reg(12, 3); wait_finished();
        initialize_case(DDR_BASE+'h1001, DDR_BASE+'h9001, 611, 0);
        write_reg(12, 3); wait_finished();
        assert (block_reads > 0 && narrow_reads > 0) else $fatal(1, "Missing head/body/tail switch");
        initialize_case(DDR_BASE+'h1001, DDR_BASE+'h9003, 137, 0);
        write_reg(12, 3); wait_finished();
        assert (block_reads == 0) else $fatal(1, "Different residue illegally widened");
        initialize_case(ITCM_BASE+'h100, DDR_BASE+'h9000, 353, 0);
        write_reg(12, 3); wait_finished();
        initialize_case(DDR_BASE+'h1000, DTCM_BASE+'h200, 353, 0);
        write_reg(12, 3); wait_finished();
        initialize_case(ITCM_BASE+'h100, DTCM_BASE+'h200, 353, 0);
        write_reg(12, 3); wait_finished();
        // 确定长度保证1/2/3/4拍和所有窄尾边界，不依赖随机seed偶然命中。
        foreach (boundary_lengths[i]) begin
            initialize_case(DDR_BASE+'h1000, DDR_BASE+'h9000, boundary_lengths[i], 0);
            write_reg(12, 3); wait_finished();
            assert (block_reads == boundary_lengths[i]/128 + ((boundary_lengths[i]%128 >= 32) ? 1 : 0))
                else $fatal(1, "Boundary block count");
        end
        for (int i = 0; i < 12; i++) begin
            count = 1+int'(random_word()%700); offset = int'(random_word()%32);
            initialize_case(DDR_BASE+'h2000+32'(offset), DDR_BASE+'ha000+32'(offset), count, 0);
            write_reg(12, 3); wait_finished();
        end
        // 确定性门控制造错误先后和已展示命令反压；仍经过真实fabric/AXI后端。
        for (int mode = 1; mode <= 5; mode++) begin
            initialize_case(DDR_BASE+'h1000, DDR_BASE+'h9000, 512, mode,
                            DDR_BASE+'h1080, mode == 1 ? 32'hffff_ffff : DDR_BASE+'h9000);
            write_reg(12, 3); wait_finished();
            if (mode == 1) assert (held_write_error > 0 && confirmed == 128 && model_code == 3) else $fatal(1, "Older held write did not finish after young read fault");
            if (mode == 2) assert (first_error_order == 1 && model_code == 5 && confirmed == 0) else $fatal(1, "Old write did not override earlier young read error");
            if (mode == 3 || mode == 4) assert (first_error_order == 2 && model_code == 5 && confirmed == 0) else $fatal(1, "Write-first drain/error ordering");
            if (mode == 4) assert (held_read_error > 0) else $fatal(1, "No read offer held over old B error");
            if (mode == 5) assert (simultaneous_errors > 0 && model_code == 5) else $fatal(1, "No simultaneous errors");
        end
        initialize_case(DDR_BASE+'h1000, DDR_BASE+'h9000, 512, 12, DDR_BASE+'h1080);
        write_reg(12, 3); wait_finished();
        assert (confirmed == 128 && block_writes == 1 && model_code == 3)
            else $fatal(1, "Accepted write lost its W/B obligation after read error");
        for (int mode = 6; mode <= 7; mode++) begin
            initialize_case(DDR_BASE+'h1000, DDR_BASE+'h9000, 1024, mode);
            competition = 1;
            write_reg(12, 3);
            write_reg(0, 0, BUS_SLVERR); write_reg(12, 3, BUS_SLVERR);
            wait_finished();
            assert (competitor_reads > 0) else $fatal(1, "No CPU/cache competition progress");
        end
        // 首/中/末错误均不能发布坏读块；后续块B错误只确认其前面完整的128B。
        for (int beat = 0; beat < 4; beat++) begin
            initialize_case(DDR_BASE+'h1000, DDR_BASE+'h9000, 512, 0, DDR_BASE+'h1000+32'(beat*32));
            write_reg(12, 3); wait_finished();
            assert (model_code == 3 && confirmed == 0 && block_writes == 0)
                else $fatal(1, "Faulted read block was written");
            initialize_case(DDR_BASE+'h1000, DDR_BASE+'h9000, 512, 0, '1, DDR_BASE+'h9080+32'(beat*32));
            write_reg(12, 3); wait_finished();
            assert (model_code == 5 && confirmed == 128 && model_fault_addr == DDR_BASE+'h9080)
                else $fatal(1, "B error counted failed block bytes");
        end
        // 只观察公开engine→regs完成事件来定位输入沿，预期仍来自独立握手账本。
        // finish优先同沿W1C；finish仍busy故同沿START拒绝，后续合法START可成功。
        for (int collision = 0; collision < 2; collision++) begin
            initialize_case(DDR_BASE+'h1000, DDR_BASE+'h9000, 128, 0);
            write_reg(12, 3);
            for (int timeout = 0; timeout < 500 && !dut.finish_valid; timeout++) tick();
            assert (dut.finish_valid && !read_owner && !write_owner)
                else $fatal(1, "Missing drained finish collision boundary");
            write_reg(collision == 0 ? 16 : 12, collision == 0 ? 6 : 3,
                      collision == 0 ? BUS_OK : BUS_SLVERR);
            assert (irq) else $fatal(1, "finish lost to W1C/rejected START");
            wait_finished();
            initialize_case(DDR_BASE+'h1000, DDR_BASE+'h9000, 32, 0);
            write_reg(12, 3); wait_finished();
        end
        // 锁定AR offer、W数据反压、B反压、已接受部分R分别协调复位，随后完整重启。
        for (int mode = 8; mode <= 11; mode++) begin
            initialize_case(DDR_BASE+'h1000, DDR_BASE+'h9000, 512, mode);
            write_reg(12, 3);
            for (int timeout = 0; timeout < 500; timeout++) begin
                if ((mode == 8 && blk_rd_cmd_valid) || (mode == 9 && blk_wr_valid) ||
                    (mode == 10 && f_wr_rsp_valid) || (mode == 11 && read_owner && read_index > 0)) break;
                tick();
            end
            assert ((mode == 8 && blk_rd_cmd_valid) || (mode == 9 && blk_wr_valid) ||
                    (mode == 10 && f_wr_rsp_valid) || (mode == 11 && read_owner && read_index > 0))
                else $fatal(1, "Reset setup missing");
            case_active = 0; rst = 1; repeat (3) tick(); rst = 0;
            initialize_case(DDR_BASE+'h1000, DDR_BASE+'h9000, 257, 0);
            write_reg(12, 3); wait_finished();
        end
        // 非法MMIO范围、重叠、零长度均在外发之前拒绝，再证明无需reset重启。
        for (int kind = 0; kind < 3; kind++) begin
            initialize_case(kind == 0 ? UART0_BASE : DDR_BASE+'h1000,
                            kind == 1 ? DDR_BASE+'h1010 : DDR_BASE+'h9000, kind == 2 ? 0 : 64, 0);
            expected_config_error = 1; model_code = 1;
            model_fault_addr = kind == 0 ? source_address : destination_address;
            write_reg(12, 3); wait_finished();
            assert (block_reads == 0 && narrow_reads == 0) else $fatal(1, "Invalid configuration escaped");
        end
        initialize_case(DDR_BASE+'h1000, DDR_BASE+'h9000, 129, 0);
        write_reg(12, 3); wait_finished();
        case_active = 0; competition = 0;
        while (competitor_active) tick();
        access(0, 16, 0, ignored);
        $display("PASS tb_dma_block XLEN=%0d cases=%0d seed_final=%h", XLEN, checks, random_state);
        $finish;
    end
    initial begin #10000000; $fatal(1, "DMA block global timeout"); end
endmodule
