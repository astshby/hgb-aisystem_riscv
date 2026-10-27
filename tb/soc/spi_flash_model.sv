// Module: spi_flash_model
// Description: Mode-0 serial Flash model; only SPI pins expose storage to the design.
module spi_flash_model #(parameter int BYTES=65536) (
    input logic cs_n, sck, mosi,
    output logic miso
);
    timeunit 1ns;
    timeprecision 1ps;
    byte unsigned mem [BYTES];
    logic [63:0] header_q = 0;
    int header_total_q=32, address_bits_q=24;
    int header_bits_q = 0, data_bits_q = 0;
    logic [31:0] address_q = 0;
    integer transactions = 0;
    initial begin
        miso = 0;
        for (int i=0;i<BYTES;i++) mem[i]=8'((i*17) ^ (i>>8) ^ 8'ha5);
        // addi a0,zero,42; jalr zero,ra,0。程序只能通过 SPI/DMA 到达 DDR。
        mem[16384]=8'h13; mem[16385]=8'h05; mem[16386]=8'ha0; mem[16387]=8'h02;
        mem[16388]=8'h67; mem[16389]=8'h80; mem[16390]=8'h00; mem[16391]=8'h00;
    end
    always @(posedge sck or posedge cs_n) begin
        if (cs_n) begin
            header_bits_q <= 0; data_bits_q <= 0; header_q <= 0; header_total_q <= 32; address_bits_q <= 24;
        end else if (header_bits_q < header_total_q) begin
            header_q <= {header_q[62:0],mosi};
            header_bits_q <= header_bits_q+1;
            if (header_bits_q == 7) begin
                unique case ({header_q[6:0],mosi})
                    8'h03: begin header_total_q<=32; address_bits_q<=24; end
                    8'h0b: begin header_total_q<=40; address_bits_q<=24; end
                    8'h13: begin header_total_q<=40; address_bits_q<=32; end
                    8'h0c: begin header_total_q<=48; address_bits_q<=32; end
                    default: $fatal(1,"unsupported Flash read command");
                endcase
            end
            if (header_bits_q == address_bits_q+7) begin
                address_q <= address_bits_q==24 ? {8'b0,header_q[22:0],mosi} : {header_q[30:0],mosi};
                transactions <= transactions+1;
            end
        end else data_bits_q <= data_bits_q+1;
    end
    always @(negedge sck) begin
        if (!cs_n && header_bits_q == header_total_q) begin
            assert (int'(address_q)+(data_bits_q/8) < BYTES) else $fatal(1,"Flash model range");
            miso = mem[int'(address_q)+(data_bits_q/8)][7-(data_bits_q%8)];
        end else miso = 0;
    end
endmodule
