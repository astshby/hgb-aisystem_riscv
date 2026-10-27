#include <stdio.h>
#include <stdint.h>
int main(int argc,char **argv) {
    if(argc!=3) {fprintf(stderr,"usage: tohex INPUT OUTPUT\n");return 2;}
    FILE *in=fopen(argv[1],"rb"),*out=fopen(argv[2],"w");
    if(!in||!out) {if(in)fclose(in);if(out)fclose(out);return 1;}
    unsigned char b[4];size_t n;int bad=0;
    while((n=fread(b,1,4,in))!=0) {
        if(n!=4){fprintf(stderr,"Input must contain complete 32-bit words\n");bad=1;break;}
        uint32_t v=(uint32_t)b[0]|(uint32_t)b[1]<<8|(uint32_t)b[2]<<16|(uint32_t)b[3]<<24;
        if(fprintf(out,"%08x\n",v)<0){bad=1;break;}
    }
    if(ferror(in))bad=1;
    if(fclose(in))bad=1;
    if(fclose(out))bad=1;
    return bad;
}
