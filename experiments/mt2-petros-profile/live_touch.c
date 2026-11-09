/* Live ingress adapter. Bounded CDC parsing; state/queues live in Rust. */
#include "wkmt2.h"
#include "usb_driver.h"
#include <stdbool.h>
#include <string.h>

static uint32_t received,max_contacts;
uint32_t wkmt2_live_received(void){return received;}
uint32_t wkmt2_live_max_contacts(void){return max_contacts;}
static int hex(uint8_t c){return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:-1;}
bool wkmt2_live_line(const uint8_t *p,size_t n,uint32_t now){
    if(n<5||memcmp(p,"MT2",3))return false;
    if(p[3]!='B'&&p[3]!='D'&&p[3]!='E')return false;
    if(p[4]!=',')return true;
    size_t i=5;uint32_t epoch=0;unsigned digits=0;
    for(;i<n&&p[i]>='0'&&p[i]<='9';i++){
        if(++digits>10||epoch>(UINT32_MAX-(p[i]-'0'))/10)return true;
        epoch=epoch*10+p[i]-'0';
    }
    if(!digits||!epoch)return true;
    if(p[3]=='B'||p[3]=='E'){
        if(i+1!=n||p[i]!='\n')return true;
        if(p[3]=='B'){if(wkmt2_enabled())wkmt2_live_begin(epoch,now);}
        else wkmt2_live_end(epoch);return true;
    }
    if(i>=n||p[i++]!=',')return true;
    size_t size=n-i-1;if(p[n-1]!='\n'||size<24||size>114||size%2)return true;
    uint8_t report[64];for(size_t j=0;j<size/2;j++){
        int a=hex(p[i+j*2]),b=hex(p[i+j*2+1]);if(a<0||b<0)return true;report[j]=(uint8_t)(a*16+b);
    }
    if(wkmt2_enabled()&&wkmt2_live_offer(epoch,report,size/2,now)>0){
        received++;unsigned down=0;for(size_t j=15;j<size/2;j+=9)if((report[j]&0xc0)==0x80)down++;
        if(down>max_contacts)max_contacts=down;
    }
    return true;
}

