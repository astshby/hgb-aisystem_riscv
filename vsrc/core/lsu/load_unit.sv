// Module: load_unit
// Description: Selects a byte lane and applies RV load sign or zero extension.
// 根据dmem数据给出load数据，使用unsigned_load来判断是否是无符号load
// load，store都是取/寸数据低位，但是要根据字节偏移
module load_unit (
    input  core_types_pkg::xlen_t     bus_data,
    input  core_types_pkg::xlen_t     address,
    input  core_types_pkg::mem_size_e size,
    input  logic                      unsigned_load,
    output core_types_pkg::xlen_t     load_data
);
    import core_config_pkg::*;
    import core_types_pkg::*;

    // 也需要OFFSET_W来计算地址的低位偏移量，所以是XLEN/8的log2（内存以字节为单位）
    localparam int unsigned OFFSET_W = $clog2(DBUS_BYTES);
    xlen_t shifted_data;

    always_comb begin
        // 取出一个xlen的数据后，也需要根据地址的低位偏移量来右移数据
        shifted_data = bus_data >> (8 * address[OFFSET_W-1:0]);
        unique case (size)
            MEM_BYTE: begin
                if (unsigned_load)
                    // xlen_t'是0扩展
                    load_data = xlen_t'(shifted_data[7:0]);
                else
                    load_data = {{(XLEN-8){shifted_data[7]}}, shifted_data[7:0]};
            end
            MEM_HALF: begin
                if (unsigned_load)
                    load_data = xlen_t'(shifted_data[15:0]);
                else
                    load_data = {{(XLEN-16){shifted_data[15]}}, shifted_data[15:0]};
            end
            MEM_WORD: begin
                if (unsigned_load)
                    load_data = xlen_t'(shifted_data[31:0]);
                else
                    load_data = {{(XLEN-32){shifted_data[31]}}, shifted_data[31:0]};
            end
            default:
                load_data = shifted_data;
        endcase
    end
endmodule
