// Module: mm3_trace_tasks
// Description: Passive raw DDR snapshots after completed commands, never arithmetic reference data.
    string mm3_trace_prefix;
    bit mm3_trace_enable;
    initial mm3_trace_enable=$value$plusargs("TRACE_PREFIX=%s",mm3_trace_prefix);
    task automatic mm3_trace_region(input int fd,input logic[31:0] address,bytes);
        for(int unsigned i=0;i<bytes;i++)
            $fwrite(fd,"%c",8'(mm3_trace_word((address+i)&32'hfffffffc)>>(8*((address+i)%4))));
    endtask
    task automatic mm3_trace_command(input int unsigned index,input logic[31:0] cmd);
        int fd;
        logic[31:0] op,n,m,flags,pos;
        if(mm3_trace_enable)begin
            op=mm3_trace_word(cmd+4);n=mm3_trace_word(cmd+8);m=mm3_trace_word(cmd+12);
            flags=mm3_trace_word(cmd+20);pos=mm3_trace_word(cmd+56);
            fd=$fopen($sformatf("%s/op-%03d.bin",mm3_trace_prefix,index),"wb");
            if(fd==0)$fatal(1,"open command trace");
            if(op==8)begin
                mm3_trace_region(fd,mm3_trace_word(cmd+(flags[0]?24:72))+(flags[0]?0:pos*n*2),n*2);
                mm3_trace_region(fd,mm3_trace_word(cmd+(flags[0]?28:76))+(flags[0]?0:pos*n*2),n*2);
                mm3_trace_region(fd,mm3_trace_word(cmd+(flags[0]?36:80))+(flags[0]?0:pos*32),32);
                mm3_trace_region(fd,mm3_trace_word(cmd+(flags[0]?40:84))+(flags[0]?0:pos*32),32);
            end else begin
                mm3_trace_region(fd,mm3_trace_word(cmd+32),op==7?m*n*8:n*2);
                if(op!=5&&op!=7)mm3_trace_region(fd,mm3_trace_word(cmd+44),8);
            end
            $fclose(fd);
        end
    endtask
