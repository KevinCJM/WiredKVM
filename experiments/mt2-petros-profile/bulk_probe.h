/* Explicit, opt-in memory-only CDC/Bulk benchmark. Included after send().
 * Never opens HID/control capacity. No filesystem, hash or heap on the body.
 * One polling owner; DMA has an immutable private bounded copy. Wire rates are
 * a baseline for this CDC backend, NOT a silicon or USB signalling ceiling. */
#pragma once
#define WK_PROBE_MAX (512u*1024u*1024u)
#ifndef WK_PROBE_SLOTS
#define WK_PROBE_SLOTS 8u
#endif
#ifndef WK_PROBE_DMA_BYTES
#define WK_PROBE_DMA_BYTES 4096u
#endif
_Static_assert(WK_PROBE_DMA_BYTES%512u==0&&WK_PROBE_DMA_BYTES<=16384u,"bounded probe DMA");
_Static_assert(WK_PROBE_SLOTS*512u>=WK_PROBE_DMA_BYTES,"probe queue must cover DMA");
typedef struct {
    uint64_t nonce, total, received, sent;
    uint32_t started, last, ended;
    unsigned mode, phase, report, submitted, head, count, partial, command_size, pattern_ready;
    uint8_t command[64];
    uint8_t queue[WK_PROBE_SLOTS][512] __attribute__((aligned(4)));
    uint8_t dma[WK_PROBE_DMA_BYTES] __attribute__((aligned(4)));
} wk_probe_state;
static wk_probe_state wk_probe_ports[2];
typedef struct {uint64_t nonce,total,received,sent;uint32_t started,ended;unsigned mode;} wk_probe_metric;
static wk_probe_metric wk_probe_links[2][2];
static unsigned wk_probe_query[2];
static uint32_t wk_probe_epoch[2],wk_probe_tx_epoch[2];
static uint64_t wk_probe_u64(const uint8_t *p){uint64_t n=0;for(unsigned i=0;i<8;i++)n|=(uint64_t)p[i]<<(8*i);return n;}
static uint32_t wk_probe_u32(const uint8_t *p){uint32_t n=0;for(unsigned i=0;i<4;i++)n|=(uint32_t)p[i]<<(8*i);return n;}
static void wk_probe_put(uint8_t *p,uint64_t n,unsigned bytes){for(unsigned i=0;i<bytes;i++)p[i]=(uint8_t)(n>>(8*i));}
static uint32_t wk_probe_crc(const uint8_t *p,size_t n){uint32_t c=~0u;while(n--){c^=*p++;for(unsigned i=0;i<8;i++)c=(c>>1)^((c&1)?0xedb88320u:0);}return ~c;}
static void wk_probe_reset(unsigned p){memset(&wk_probe_ports[p],0,offsetof(wk_probe_state,queue));wk_probe_query[p]=0;wk_probe_epoch[p]++;}
static bool wk_probe_active(unsigned p){return wk_probe_ports[p].phase!=0||wk_probe_query[p]!=0;}
static bool wk_probe_current(unsigned p){return wk_probe_tx_epoch[p]==wk_probe_epoch[p];}
static bool wk_probe_idle_arm(unsigned p){
    /* Both normal peers online: keep ALL original loader/queue backpressure.
     * The sole extra arm is for an isolated local-link measurement. */
    return !wk_probe_active(p)&&!bridge.online[1-p]&&
        (p!=0||(wk_cable_setup_size()&&!wk_cable_setup_pending()));
}
static void wk_probe_abort(unsigned p,uint32_t now){wk_probe_state *s=&wk_probe_ports[p];s->phase=3;s->report=3;s->ended=now;}
static bool wk_probe_pair(unsigned p){
    const wk_probe_state *s=&wk_probe_ports[p],*d=&wk_probe_ports[1-p];
    return d->nonce==s->nonce&&d->total==s->total&&(d->mode==5||d->mode==4);
}
static bool wk_probe_space(unsigned p){
    const wk_probe_state *s=&wk_probe_ports[p];
    if(!s->phase)return true; /* admit only explicit commands on an idle link */
    if(s->phase!=2)return false;
    if(s->mode==1)return s->received<s->total;
    if(s->mode==4){const wk_probe_state *d=&wk_probe_ports[1-p];return wk_probe_pair(p)&&d->mode==5&&d->phase==2&&d->count+(d->partial?2u:1u)<=WK_PROBE_SLOTS;}
    return s->mode==2||s->mode==5; /* separate OUT remains available for STOP */
}
static void wk_probe_normal(unsigned p,const uint8_t *b,size_t n){
    if(p==0)wk_cable_setup_input(b,n);else (void)wk407_bulk_accept(&bridge,p,b,n);
}
static bool wk_probe_command(unsigned p,uint32_t now){
    wk_probe_state *s=&wk_probe_ports[p];uint8_t *b=s->command;
    if(b[4]!=1||wk_probe_crc(b,60)!=wk_probe_u32(b+60))return false;
    for(unsigned i=24;i<60;i++)if(b[i])return false;
    uint64_t nonce=wk_probe_u64(b+8),total=wk_probe_u64(b+16);unsigned op=b[5];
    if(op==7){
        if(!s->phase&&!wk_probe_query[p]&&!busy[p][p?5:4]&&b[6]<2&&b[7]>=1&&b[7]<=2&&!nonce&&!total)wk_probe_query[p]=1+b[6]*2+b[7]-1;
        return wk_probe_query[p]!=0;
    }
    if(b[6]||b[7])return false;
    if(op==6){if(s->nonce==nonce&&s->phase){wk_probe_abort(p,now);return true;}return false;}
    if(s->phase||s->count||busy[p][p?5:4]||!nonce||!total||total>WK_PROBE_MAX||total%512)return false;
    if(op!=1&&op!=2&&op!=4&&op!=5)return false;
    s->nonce=nonce;s->total=total;s->received=s->sent=0;s->mode=op;s->phase=1;s->report=1;
    s->started=s->last=now;s->ended=0;s->submitted=s->head=s->count=s->partial=s->pattern_ready=0;
    return true;
}
static bool wk_probe_input(unsigned p,const uint8_t *b,size_t n,uint32_t now){
    wk_probe_state *s=&wk_probe_ports[p];
    /* A probe-looking byte string inside an ordinary WKS5/WKIM cell is BODY,
     * never a command. Query the existing parser's exact boundary. */
    if(!s->phase&&!s->command_size&&!(p==0?wk_cable_setup_at_boundary():bridge.cell_size[p]==0))return false;
    size_t prefix=n<4?n:4;
    bool command=s->command_size||(n&&!memcmp(b,"WKBP",prefix));
    if(!command&&s->phase==2&&(s->mode==1||s->mode==4)){
        if(!n)return true;
        if(n>512||n>s->total-s->received){wk_probe_abort(p,now);return true;}
        if(s->mode==4){
            wk_probe_state *d=&wk_probe_ports[1-p];
            if(!wk_probe_pair(p)||d->mode!=5||d->phase!=2||d->count+(d->partial?2u:1u)>WK_PROBE_SLOTS){wk_probe_abort(p,now);return true;}
            size_t at=0;
            while(at<n){
                unsigned part=512-d->partial;if(part>n-at)part=(unsigned)(n-at);
                memcpy(d->queue[(d->head+d->count)%WK_PROBE_SLOTS]+d->partial,b+at,part);
                d->partial+=part;at+=part;if(d->partial==512){d->partial=0;d->count++;}
            }
            d->last=now;
        }
        s->received+=n;s->last=now;
        if(s->mode==1&&s->received==s->total){s->phase=3;s->report=2;s->ended=now;}
        return true;
    }
    if(s->phase&&!command)return true;
    /* Commands are 64 bytes and survive arbitrary short CDC/FS fragments.
     * Non-probe prefixes are replayed intact into the original parser. */
    if(!s->command_size&&(!n||b[0]!='W'))return false;
    if(!s->command_size&&n>=4&&memcmp(b,"WKBP",4))return false;
    while(n){
        unsigned at=s->command_size;
        if(at<4&&*b!=(uint8_t)"WKBP"[at]){
            if(!s->phase){if(at)wk_probe_normal(p,s->command,at);wk_probe_normal(p,b,n);}
            s->command_size=0;return true;
        }
        s->command[at]=*b++;s->command_size++;n--;
        if(s->command_size==64){
            s->command_size=0;bool accepted=wk_probe_command(p,now);
            if(!accepted&&!s->phase)wk_probe_normal(p,s->command,64);
            if(n&&!wk_probe_input(p,b,n,now))wk_probe_normal(p,b,n);
            return true;
        }
    }
    s->last=now;return true;
}
static void wk_probe_done(unsigned p,unsigned kind,uint32_t now){
    wk_probe_state *s=&wk_probe_ports[p];s->last=now;
    if(kind==11&&s->phase==2){s->sent+=s->submitted;s->submitted=0;}
    if(kind==10){if(s->phase==1){s->phase=2;s->started=now;}else if(s->phase==3){s->phase=0;s->count=s->partial=0;}s->report=0;}
}
static void wk_probe_service(unsigned p,unsigned ep,uint32_t now){
    wk_probe_state *s=&wk_probe_ports[p];
    if(!s->phase&&!wk_probe_query[p])return;
    uint32_t lease=((s->mode==4||s->mode==5)&&!s->received&&!s->sent)?60000:5000;
    if(s->phase&&(uint32_t)(now-s->last)>lease&&s->phase!=3)wk_probe_abort(p,now);
    if(busy[p][ep])return;
    if(s->phase==1&&s->mode==4&&(!wk_probe_pair(p)||wk_probe_ports[1-p].phase!=2))return;
    if(s->phase==2){
        if(s->mode==2&&s->sent==s->total){s->phase=3;s->report=2;s->ended=now;}
        if(s->mode==5&&s->sent==s->total){s->phase=3;s->report=2;s->ended=now;}
        if(s->mode==4&&s->received==s->total&&wk_probe_pair(p)&&wk_probe_ports[1-p].sent==s->total){s->phase=3;s->report=2;s->ended=now;}
    }
    unsigned n=0,kind=0;
    if(!s->phase&&wk_probe_query[p]){
        unsigned which=wk_probe_query[p]-1;const wk_probe_metric *m=&wk_probe_links[which/2][which%2];
        memset(s->dma,0,64);memcpy(s->dma,"WKBR",4);s->dma[4]=1;s->dma[5]=4;s->dma[6]=(uint8_t)m->mode;s->dma[7]=(uint8_t)(which/2);
        wk_probe_put(s->dma+8,m->nonce,8);wk_probe_put(s->dma+16,m->total,8);wk_probe_put(s->dma+24,m->received,8);wk_probe_put(s->dma+32,m->sent,8);
        wk_probe_put(s->dma+40,m->started,4);wk_probe_put(s->dma+44,m->ended,4);wk_probe_put(s->dma+60,wk_probe_crc(s->dma,60),4);n=64;kind=10;
    }else if(s->report){
        if(s->report==2&&(s->mode==1||s->mode==2))wk_probe_links[p][s->mode-1]=(wk_probe_metric){s->nonce,s->total,s->received,s->sent,s->started,s->ended,s->mode};
        memset(s->dma,0,64);memcpy(s->dma,"WKBR",4);s->dma[4]=1;s->dma[5]=(uint8_t)s->report;s->dma[6]=(uint8_t)s->mode;s->dma[7]=(uint8_t)p;
        wk_probe_put(s->dma+8,s->nonce,8);wk_probe_put(s->dma+16,s->total,8);wk_probe_put(s->dma+24,s->received,8);wk_probe_put(s->dma+32,s->sent,8);
        wk_probe_put(s->dma+40,s->started,4);wk_probe_put(s->dma+44,s->ended,4);wk_probe_put(s->dma+60,wk_probe_crc(s->dma,60),4);n=64;kind=10;
    }else if(s->phase==2&&s->mode==2){
        n=(unsigned)((s->total-s->sent)>sizeof(s->dma)?sizeof(s->dma):s->total-s->sent);
        if(!s->pattern_ready){memset(s->dma,0xa5,sizeof(s->dma));s->pattern_ready=1;}kind=11;
    }else if(s->phase==2&&s->mode==5&&s->count){
        unsigned cells=s->count;if(cells>sizeof(s->dma)/512)cells=sizeof(s->dma)/512;
        for(unsigned i=0;i<cells;i++)memcpy(s->dma+512*i,s->queue[(s->head+i)%WK_PROBE_SLOTS],512);
        n=cells*512;kind=11;
    }
    if(usbd_get_speed(handles[p])!=USB_SPEED_HIGH&&kind==11&&n>512)n=512;
    if(n&&usbd_upload(handles[p],(uint8_t)(ep|128),s->dma,n)==USB_RST_OK){
        busy[p][ep]=true;tx_kind[p][ep]=(uint8_t)kind;tx_epoch[p][ep]=bridge.epoch;
        wk_probe_tx_epoch[p]=wk_probe_epoch[p];
        if(!s->phase)wk_probe_query[p]=0;
        s->submitted=kind==11?n:0;
        if(kind==11&&s->mode==5){unsigned cells=n/512;s->head=(s->head+cells)%WK_PROBE_SLOTS;s->count-=cells;}
    }
}
