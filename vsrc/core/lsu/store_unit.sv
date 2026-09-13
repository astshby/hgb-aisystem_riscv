// Module: store_unit
// Description: Aligns store data and generates byte write strobes.
// 输入store_data，输出给dmem的bus_wdata和bus_wstrb
// load，store都是取/寸数据低位，但是要根据字节偏移
module store_unit (
    input  core_types_pkg::xlen_t     store_data,
    input  core_types_pkg::xlen_t     address,
    input  core_types_pkg::mem_size_e size,
    output core_types_pkg::xlen_t     bus_wdata,
    output logic [core_config_pkg::DBUS_BYTES-1:0] bus_wstrb
);
    import core_config_pkg::*;
    import core_types_pkg::*;

    // OFFSET_W用于计算地址的低位偏移量，所以是XLEN/8的log2（内存以字节为单位）
    localparam int unsigned OFFSET_W = $clog2(DBUS_BYTES);
    logic [DBUS_BYTES-1:0] base_strobe;

    // 注意：写入得bus_wstrb必须与地址对齐，所以需要左移，由于数据都是低位写入，所以也要对齐
    always_comb begin
        unique case (size)
            MEM_BYTE:  base_strobe = DBUS_BYTES'(1); //0001 / 00000001
            MEM_HALF:  base_strobe = DBUS_BYTES'(3); //0011 / 00000011
            MEM_WORD:  base_strobe = DBUS_BYTES'(15); //1111 / 00001111
            default:   base_strobe = '1; // 1111 / 11111111
        endcase
        bus_wstrb = base_strobe << address[OFFSET_W-1:0];
        bus_wdata = store_data << (8 * address[OFFSET_W-1:0]);
    end
endmodule
