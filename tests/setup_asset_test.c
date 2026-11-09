/* Replay the actual packed release image through both production SCSI cores.
 * Host-side flash fixture can be large; MCU state remains sizeof(wk_setup). */
#include "setup_msc.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static uint8_t *flash;static size_t flash_size;static unsigned max_read;
static bool read_flash(void *ctx,uint32_t at,void *bytes,size_t n) {
    (void)ctx;if(n>max_read)max_read=(unsigned)n;
    if(at>flash_size||n>flash_size-at)return false;memcpy(bytes,flash+at,n);return true;
}
static void le(uint8_t *p,uint32_t n){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(n>>(i*8));}
static void be(uint8_t *p,uint32_t n){for(unsigned i=0;i<4;i++)p[3-i]=(uint8_t)(n>>(i*8));}
int main(int argc,char **argv) {
    assert(argc==2);FILE *f=fopen(argv[1],"rb");assert(f);assert(!fseek(f,0,SEEK_END));long n=ftell(f);
    assert(n>4096&&n<=WK_SETUP_FLASH_BYTES);flash_size=(size_t)n;rewind(f);flash=malloc(flash_size);assert(flash);
    assert(fread(flash,1,flash_size,f)==flash_size);fclose(f);
    wk_setup setup;wk_setup_init(&setup,read_flash,NULL);
    unsigned checks=0;
    for(unsigned k=0;setup.validating&&k<WK_SETUP_FLASH_BYTES/512+1;k++)wk_setup_tick(&setup,k);
    assert(setup.valid&&max_read<=512);
    for(unsigned port=0;port<2;port++) {
        wk_setup_connected(&setup,port,true,0); /* Only this side need be online. */
        for(uint32_t at=0;at<setup.image_bytes;at+=512) {
            uint8_t cbw[31]={0};le(cbw,0x43425355);le(cbw+4,at+1);le(cbw+8,512);cbw[12]=128;cbw[14]=10;cbw[15]=0x28;be(cbw+17,at/512);cbw[23]=1;
            assert(wk_setup_msc_out(&setup,port,cbw,31,2000));size_t size=0;
            const uint8_t *bytes=wk_setup_msc_in(&setup,port,&size);assert(bytes&&size==512&&!memcmp(bytes,flash+4096+at,size));
            wk_setup_msc_done(&setup,port);bytes=wk_setup_msc_in(&setup,port,&size);assert(bytes&&size==13&&!bytes[12]);
            wk_setup_msc_done(&setup,port);checks++;
        }
        wk_setup_connected(&setup,port,false,3000);
    }
    printf("SETUP_ACTUAL_ASSET_PASS sectors=%u each_role_bytes=%u exact_bytes=true independent_ports=true fixed_state=%zu physicalUSB=false\n",checks,setup.image_bytes,sizeof(setup));free(flash);
}
