#include "mm3.h"
#include <math.h>
static void gemv(float *out,const float *w,const float *x,int rows,int cols) {
    for(int r=0;r<rows;r++) {
        float a=0,b=0,c=0,d=0;
        const float *p=w+(size_t)r*cols; int i=0;
        for(;i+3<cols;i+=4) { a+=p[i]*x[i]; b+=p[i+1]*x[i+1]; c+=p[i+2]*x[i+2]; d+=p[i+3]*x[i+3]; }
        float sum=(a+b)+(c+d); for(;i<cols;i++) sum+=p[i]*x[i]; out[r]=sum;
    }
}
static void norm(float *out,const float *x,const float *w,int n,float eps) {
    float sum=0; for(int i=0;i<n;i++) sum+=x[i]*x[i];
    float scale=1.f/sqrtf(sum/(float)n+eps);
    for(int i=0;i<n;i++) out[i]=(x[i]*scale)*w[i];
}
static void softmax(float *x,int n) {
    float max=x[0],sum=0;
    for(int i=1;i<n;i++) if(x[i]>max) max=x[i];
    for(int i=0;i<n;i++) { x[i]=expf(x[i]-max); sum+=x[i]; }
    for(int i=0;i<n;i++) x[i]/=sum;
}
static void rope(float *x,int heads,int pos,float theta) {
    for(int i=0;i<48;i++) {
        float inverse=1.f/powf(theta,(2.f*i)/96.f);
        float angle=(float)pos*inverse,co=cosf(angle),si=sinf(angle);
        for(int h=0;h<heads;h++) { float *p=x+h*96; float a=p[i],b=p[i+48]; p[i]=a*co-b*si; p[i+48]=b*co+a*si; }
    }
}
static void swiglu(float *gate,const float *up,int n) {
    for(int i=0;i<n;i++) { float x=gate[i]; float sigmoid=x>=0?1.f/(1.f+expf(-x)):expf(x)/(1.f+expf(x)); gate[i]=(x*sigmoid)*up[i]; }
}
const Backend mm3_cpu_backend={gemv,norm,softmax,rope,swiglu};
int argmax(const float *x,int n) { int best=0; for(int i=1;i<n;i++) if(x[i]>x[best]) best=i; return best; }
