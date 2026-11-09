/* Standalone readonly BOT/SCSI, one 512-byte staging cell per USB port.
 * No other computer, UART, clipboard, heap or entire-image RAM dependency. */
#include "setup_msc.h"
#include <string.h>
enum { CBW, REPLY, READ, DRAIN, CSW, HALTED };
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[3]|(uint32_t)p[2]<<8|(uint32_t)p[1]<<16|(uint32_t)p[0]<<24; }
static void putle(uint8_t *p,uint32_t v) { for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(v>>(i*8)); }
static void putbe(uint8_t *p,uint32_t v) { for(unsigned i=0;i<4;i++)p[3-i]=(uint8_t)(v>>(i*8)); }
static uint32_t crc_update(uint32_t v,const uint8_t *p,size_t n) {
    while(n--) { v^=*p++;for(unsigned i=0;i<8;i++)v=(v>>1)^((v&1)?0xedb88320u:0); } return v;
}
void wk_setup_init(wk_setup *s,wk_setup_read_fn read,void *context) {
    memset(s,0,sizeof(*s));s->read=read;s->context=context;
    wk_setup_refresh(s);
}
void wk_setup_refresh(wk_setup *s) {
    if(s->valid||s->validating)return;
    uint8_t h[24];
    if(!s->read||!s->read(s->context,0,h,sizeof(h))||memcmp(h,"WKDUAL01",8)||le32(h+8)!=1||
       le32(h+20)!=~crc_update(UINT32_MAX,h,20))return;
    s->image_bytes=le32(h+12);s->expected_crc=le32(h+16);
    if(!s->image_bytes||s->image_bytes%512||s->image_bytes>WK_SETUP_FLASH_BYTES-WK_SETUP_IMAGE_OFFSET)return;
    s->crc=UINT32_MAX;s->checked=0;s->validating=true;
}
void wk_setup_tick(wk_setup *s,uint32_t now) {
    if(s->validating) {
        uint8_t cell[512];uint32_t n=s->image_bytes-s->checked;if(n>512)n=512;
        if(!s->read(s->context,WK_SETUP_IMAGE_OFFSET+s->checked,cell,n)){s->validating=false;return;}
        s->crc=crc_update(s->crc,cell,n);s->checked+=n;
        if(s->checked==s->image_bytes){s->validating=false;s->valid=(~s->crc==s->expected_crc);}
    }
    for(unsigned i=0;i<2;i++) {
        wk_setup_port *p=&s->ports[i];
        if(p->lease&&(uint32_t)(now-p->last_lease)>4000) {
            p->lease=false;
            /* Do not interrupt an already accepted SCSI read. */
            if(p->phase==CBW){p->suppressed=false;p->hide_requested=false;}
        }
        if(!p->lease&&p->phase==CBW&&!p->ejected){p->suppressed=false;p->hide_requested=false;}
        if(p->hide_requested&&p->phase==CBW&&!p->prevent)p->suppressed=true;
    }
}
void wk_setup_connected(wk_setup *s,unsigned port,bool online,uint32_t now) {
    if(port>1)return;memset(&s->ports[port],0,sizeof(wk_setup_port));
    s->ports[port].online=online;s->ports[port].attached=now;
}
bool wk_setup_control(wk_setup *s,unsigned port,const uint8_t *b,size_t n,uint32_t now) {
    if(port>1||n!=64||memcmp(b,"WKI1",4)||b[4]!=1||b[5]!=port||b[7]||
       (b[6]!=1&&b[6]!=2)||!s->ports[port].online||le32(b+60)!=~crc_update(UINT32_MAX,b,60))return false;
    for(unsigned i=12;i<60;i++)if(b[i])return false;
    wk_setup_port *p=&s->ports[port];uint32_t seq=le32(b+8);
    if(p->lease&&(int32_t)(seq-p->sequence)<=0)return false;
    p->sequence=seq;p->last_lease=now;p->lease=true;
    if(!p->announced||b[6]==2)p->hide_requested=true;
    return true;
}
bool wk_setup_ready(wk_setup *s,unsigned port,uint32_t now) {
    if(port>1)return false;wk_setup_port *p=&s->ports[port];
    if(!s->valid||!p->online||p->ejected||p->suppressed||(uint32_t)(now-p->attached)<1500)return false;
    p->announced=true;return true;
}
void wk_setup_msc_reset(wk_setup *s,unsigned port) {
    if(port>1)return;wk_setup_port *p=&s->ports[port];p->phase=CBW;p->length=0;p->remaining=0;p->status=0;p->stall_in=false;
}
static void fail(wk_setup_port *p,uint8_t sense,uint8_t asc,bool out) {
    p->sense=sense;p->asc=asc;p->status=1;p->phase=out&&p->residue?DRAIN:CSW;p->remaining=p->residue;
    if(!out&&p->residue)p->stall_in=true;
}
static void reply(wk_setup_port *p,unsigned bytes,unsigned allocation) {
    if(bytes>allocation)bytes=allocation;if(bytes>p->residue)bytes=p->residue;
    p->length=(uint16_t)bytes;p->phase=bytes?REPLY:CSW;
}
static bool medium(wk_setup *s,unsigned i,uint32_t now,bool out) {
    if(wk_setup_ready(s,i,now))return true;fail(&s->ports[i],2,0x3a,out);return false;
}
static bool direction(wk_setup_port *p,bool in,bool actual) {
    if(p->residue&&in!=actual){p->phase=HALTED;p->status=2;return false;}return true;
}
bool wk_setup_msc_out(wk_setup *s,unsigned i,const uint8_t *b,size_t n,uint32_t now) {
    if(i>1||!s->ports[i].online)return false;wk_setup_port *p=&s->ports[i];
    if(p->phase==DRAIN) {
        if(!n||n>p->remaining){p->phase=HALTED;return false;}
        p->remaining-=(uint32_t)n;if(!p->remaining)p->phase=CSW;return true;
    }
    if(p->phase!=CBW||n!=31||le32(b)!=0x43425355u||b[12]&0x7f||b[13]||b[14]<1||b[14]>16){p->phase=HALTED;return false;}
    p->tag=le32(b+4);p->residue=le32(b+8);p->status=0;p->length=0;
    bool in=(b[12]&128)!=0;const uint8_t *c=b+15;uint8_t op=c[0];
    if(p->residue>64u*1024u*1024u){p->phase=HALTED;return false;}
    memset(p->buffer,0,sizeof(p->buffer));
    switch(op) {
    case 0x00: if(!medium(s,i,now,!in))return true;p->phase=CSW;break;
    case 0x12:
        if(!direction(p,true,in))return false;
        if(b[14]<6||c[1]&0xfe){fail(p,5,0x24,!in);break;}
        if(c[1]&1) {
            p->buffer[1]=c[2];
            if(c[2]==0){p->buffer[3]=2;p->buffer[4]=0;p->buffer[5]=0x80;reply(p,6,c[4]);}
            else if(c[2]==0x80){static const char serial[]="CH32V407-DoNotShip";p->buffer[3]=sizeof(serial)-1;memcpy(p->buffer+4,serial,sizeof(serial)-1);reply(p,4+sizeof(serial)-1,c[4]);}
            else fail(p,5,0x24,!in);
            break;
        }
        p->buffer[1]=0x80;p->buffer[2]=4;p->buffer[3]=2;p->buffer[4]=31;
        memcpy(p->buffer+8,"WiredKVM",8);memcpy(p->buffer+16,"Read-only Setup ",16);memcpy(p->buffer+32,"0001",4);
        reply(p,36,c[4]);break;
    case 0x03:
        if(!direction(p,true,in))return false;
        p->buffer[0]=0x70;p->buffer[2]=p->sense;p->buffer[7]=10;p->buffer[12]=p->asc;
        reply(p,18,c[4]);p->sense=p->asc=0;break;
    case 0x1a:
        if(!direction(p,true,in))return false;p->buffer[0]=3;p->buffer[2]=0x80;reply(p,4,c[4]);break;
    case 0x5a:
        if(!direction(p,true,in))return false;p->buffer[1]=6;p->buffer[3]=0x80;reply(p,8,((unsigned)c[7]<<8)|c[8]);break;
    case 0x25:
        if(!direction(p,true,in))return false;if(!medium(s,i,now,!in))break;
        putbe(p->buffer,s->image_bytes/512-1);putbe(p->buffer+4,512);reply(p,8,8);break;
    case 0x23:
        if(!direction(p,true,in))return false;if(!medium(s,i,now,!in))break;
        p->buffer[3]=8;putbe(p->buffer+4,s->image_bytes/512);p->buffer[8]=2;p->buffer[10]=2;
        reply(p,12,((unsigned)c[7]<<8)|c[8]);break;
    case 0x9e:
        if(b[14]<16||c[1]!=0x10||!direction(p,true,in)){fail(p,5,0x24,!in);break;}
        if(!medium(s,i,now,!in))break;putbe(p->buffer+4,s->image_bytes/512-1);putbe(p->buffer+8,512);reply(p,32,be32(c+10));break;
    case 0xa0:
        if(!direction(p,true,in))return false;
        if(b[14]<12){fail(p,5,0x24,!in);break;}
        p->buffer[3]=8;reply(p,16,be32(c+6));break;
    case 0x28:case 0xa8:case 0x88: {
        if(!direction(p,true,in))return false;if(!medium(s,i,now,!in))break;
        if((op==0x28&&b[14]<10)||(op==0xa8&&b[14]<12)||(op==0x88&&(b[14]<16||be32(c+2)))){fail(p,5,0x24,!in);break;}
        uint32_t lba=be32(c+(op==0x88?6:2));
        uint32_t blocks=op==0x28?((uint32_t)c[7]<<8)|c[8]:be32(c+(op==0x88?10:6));
        if(lba>s->image_bytes/512||blocks>s->image_bytes/512-lba||blocks*512u!=p->residue){fail(p,5,0x21,!in);break;}
        p->offset=lba*512;p->remaining=blocks*512;p->phase=p->remaining?READ:CSW;break;
    }
    case 0x1b:
        if((c[4]&3)==2&&!p->prevent)p->ejected=true;p->phase=CSW;break;
    case 0x1e:p->prevent=(c[4]&1)!=0;p->phase=CSW;break;
    case 0x35:p->phase=CSW;break;
    case 0x2a:case 0xaa:case 0x8a:fail(p,7,0x27,!in);break;
    default:fail(p,5,0x20,!in);break;
    }
    return true;
}
const uint8_t *wk_setup_msc_in(wk_setup *s,unsigned i,size_t *size) {
    *size=0;if(i>1)return NULL;wk_setup_port *p=&s->ports[i];
    if(p->length){*size=p->length;return p->buffer;}
    if(p->phase==READ) {
        uint32_t n=p->remaining;if(n>512)n=512;
        if(!s->read(s->context,WK_SETUP_IMAGE_OFFSET+p->offset,p->buffer,n)){fail(p,3,0x11,false);}
        else {p->length=(uint16_t)n;*size=n;return p->buffer;}
    }
    if(p->phase==CSW) {
        putle(p->buffer,0x53425355u);putle(p->buffer+4,p->tag);putle(p->buffer+8,p->residue);p->buffer[12]=p->status;
        p->length=13;*size=13;return p->buffer;
    }
    return NULL;
}
void wk_setup_msc_done(wk_setup *s,unsigned i) {
    if(i>1)return;wk_setup_port *p=&s->ports[i];uint32_t n=p->length;p->length=0;
    if(p->phase==CSW){p->phase=CBW;return;}
    if(p->phase==READ){p->offset+=n;p->remaining-=n;if(!p->remaining)p->phase=CSW;}
    else if(p->phase==REPLY)p->phase=CSW;
    if(n<=p->residue)p->residue-=n;
}
bool wk_setup_msc_wants_out(const wk_setup *s,unsigned i) { return i<2&&(s->ports[i].phase==CBW||s->ports[i].phase==DRAIN); }
bool wk_setup_msc_take_stall(wk_setup *s,unsigned i) {
    if(i>1)return false;bool value=s->ports[i].stall_in;s->ports[i].stall_in=false;return value;
}
