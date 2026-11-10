#include "bridge.h"
#include <string.h>

static uint32_t crc32(const uint8_t *p, size_t n) {
    uint32_t c = UINT32_MAX;
    while (n--) { c ^= *p++; for (unsigned i=0;i<8;i++) c=(c>>1)^((c&1)?0xedb88320U:0); }
    return ~c;
}
static int hex(char c) { return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:-1; }
static bool put(wk407_control_queue *q, const void *p, size_t n) {
    if (q->count == WK407_CONTROL_SLOTS || n>144) return false;
    wk407_control_packet *v=&q->item[(q->head+q->count)%WK407_CONTROL_SLOTS];
    memcpy(v->bytes,p,n); v->size=(uint16_t)n; q->count++; return true;
}
static const wk407_control_packet *peek(const wk407_control_queue *q) { return q->count?&q->item[q->head]:NULL; }
static void pop(wk407_control_queue *q) { if(q->count) {q->head=(q->head+1)%WK407_CONTROL_SLOTS;q->count--;} }
static void report(wk407_bridge *b, uint8_t ep, const uint8_t *p, uint8_t n) {
    wk407_hid_packet *v=&b->hid.item[(b->hid.head+b->hid.count)%WK407_HID_SLOTS];
    v->endpoint=ep;v->size=n;memcpy(v->bytes,p,n);b->hid.count++;
    if(b->hid.count>b->hid_high_water)b->hid_high_water=b->hid.count;
}
static void fn_report(wk407_bridge *b,uint8_t phase) {
    if(!b->fn_press)return;
    uint8_t p[64]={0};memcpy(p,"WKFN",4);p[4]=1;p[5]=phase;p[6]=b->fn_eligible;
    uint64_t values[4]={b->epoch,b->fn_press,(uint64_t)b->last_input_ms*1000,phase==2?(uint32_t)(b->last_input_ms-b->fn_began):0};
    unsigned positions[4]={8,12,16,24},sizes[4]={4,4,8,4};
    for(unsigned j=0;j<4;j++)for(unsigned i=0;i<sizes[j];i++)p[positions[j]+i]=(uint8_t)(values[j]>>(8*i));
    uint32_t crc=crc32(p,60);for(unsigned i=0;i<4;i++)p[60+i]=(uint8_t)(crc>>(8*i));
    if(!put(&b->urgent[1],p,64))b->fn_eligible=false;
}
static void keyboard(wk407_bridge *b) {
    bool down=(b->modifiers&16)!=0;
    if(down&&!b->fn_down){b->fn_press++;if(!b->fn_press)b->fn_press++;b->fn_began=b->last_input_ms;b->fn_eligible=true;}
    if((b->modifiers&15)||memcmp(b->keys,"\0\0\0\0\0\0",6))b->fn_eligible=false;
    if(down!=b->fn_down)fn_report(b,down?1:2);
    b->fn_down=down;
    uint8_t p[9]={1,(uint8_t)(b->modifiers&15),0};memcpy(p+3,b->keys,6);report(b,1,p,9);
    const uint8_t globe[3]={4,(b->modifiers&16)?0x9d:0,(b->modifiers&16)?2:0};report(b,1,globe,3);
}
static void pointer(wk407_bridge *b, int dx, int dy, int wheel, int pan) {
    if(b->buttons||wheel||pan)b->fn_eligible=false;
    if(b->absolute) {
        const uint8_t p[8]={3,b->buttons,(uint8_t)b->x,(uint8_t)(b->x>>8),(uint8_t)b->y,(uint8_t)(b->y>>8),(uint8_t)wheel,(uint8_t)pan};
        report(b,2,p,sizeof(p));
    } else {
        const uint8_t p[6]={2,b->buttons,(uint8_t)dx,(uint8_t)dy,(uint8_t)wheel,(uint8_t)pan};report(b,1,p,sizeof(p));
    }
}
static void release(wk407_bridge *b) {
    /* Emergency release has its own capacity by discarding obsolete HID state.
     * The USB adapter keeps an in-flight DMA copy until its completion. */
    b->release_pending=b->release_pending||b->buttons||b->modifiers||b->hid.count||memcmp(b->keys,"\0\0\0\0\0\0",6);
    if(b->fn_down){b->fn_eligible=false;fn_report(b,3);b->fn_down=false;}
    b->hid_epoch++;b->hid.head=b->hid.count=0;b->buttons=b->modifiers=0;memset(b->keys,0,6);
    if(b->online[1]&&b->release_pending){keyboard(b);b->absolute=true;pointer(b,0,0,0,0);b->absolute=false;pointer(b,0,0,0,0);b->release_pending=false;}
    b->absolute=false;b->seen=false;
}
void wk407_init(wk407_bridge *b) { memset(b,0,sizeof(*b));b->epoch=1; }
void wk407_connected(wk407_bridge *b,unsigned port,bool connected,uint32_t now) {
    if(port>1)return;
    b->online[port]=connected;b->epoch++;b->last_input_ms=now;
    for(unsigned i=0;i<2;i++){b->bulk[i].head=b->bulk[i].count=0;b->clipboard[i].head=b->clipboard[i].count=0;}
    memset(b->stream_session,0,sizeof(b->stream_session));memset(b->stream_generation,0,sizeof(b->stream_generation));
    memset(b->transactions,0,sizeof(b->transactions));memset(b->cell_size,0,sizeof(b->cell_size));
    memset(b->urgent,0,sizeof(b->urgent));
    b->reply.head=b->reply.count=0;b->line_size=0;b->discarding=false;release(b);
}
void wk407_tick(wk407_bridge *b,uint32_t now) {
    if((uint32_t)(now-b->last_input_ms)>=2500 && (b->buttons||b->modifiers||memcmp(b->keys,"\0\0\0\0\0\0",6))) {
        release(b);b->watchdog_releases++;b->last_input_ms=now;
    }
}
static void event(wk407_bridge *b,const wk_event_t *e,uint32_t now) {
    if(b->reply.count==WK407_CONTROL_SLOTS){if(e->kind==WK_EVENT_RELEASE)release(b);b->rejected++;return;}
    bool idempotent=e->kind==WK_EVENT_PING||e->kind==WK_EVENT_CLIENT_STATUS||e->kind==WK_EVENT_ABSOLUTE_CAPABILITY||e->kind==WK_EVENT_RELEASE;
    bool same=b->seen&&e->seq==b->previous.seq&&e->kind==b->previous.kind&&e->a==b->previous.a&&e->b==b->previous.b;
    bool ok=b->online[1];
    b->last_input_ms=now;
    if(e->kind==WK_EVENT_PING||e->kind==WK_EVENT_ABSOLUTE_CAPABILITY)ok=true;
    if(ok && (!same||idempotent)) {
        /* Reserve enough room for mode switch, keyboard and Globe reports. */
        if(e->kind!=WK_EVENT_RELEASE && b->hid.count>WK407_HID_SLOTS-6)ok=false;
        else switch(e->kind) {
        case WK_EVENT_MOVE:
        case WK_EVENT_ABSOLUTE_MOVE: {
            bool absolute=e->kind==WK_EVENT_ABSOLUTE_MOVE;
            if(absolute!=b->absolute && b->buttons){uint8_t held=b->buttons;b->buttons=0;pointer(b,0,0,0,0);b->buttons=held;}
            b->absolute=absolute;if(absolute){b->x=(uint16_t)e->a;b->y=(uint16_t)e->b;}
            pointer(b,e->a,e->b,0,0);break;
        }
        case WK_EVENT_BUTTONS:b->buttons=(uint8_t)e->a;pointer(b,0,0,0,0);break;
        case WK_EVENT_WHEEL:pointer(b,0,0,e->a,e->b);break;
        case WK_EVENT_KEYBOARD:b->modifiers=(uint8_t)e->a;memset(b->keys,0,6);b->keys[0]=(uint8_t)e->b;keyboard(b);break;
        case WK_EVENT_MODIFIERS:b->modifiers=(uint8_t)e->a;keyboard(b);break;
        case WK_EVENT_KEY_TRANSITION: {
            int held=-1,empty=-1;for(int i=0;i<6;i++){if(b->keys[i]==e->a)held=i;if(!b->keys[i])empty=i;}
            if(e->b==0 && held>=0){b->keys[held]=0;keyboard(b);}
            else if(e->b==1 && held<0){if(empty<0)ok=false;else{b->keys[empty]=(uint8_t)e->a;keyboard(b);}}
            /* A held USB key repeats at the destination OS rate. */
            break;
        }
        case WK_EVENT_RELEASE:release(b);break;
        default:break;
        }
        b->seen=ok;if(ok)b->previous=*e;
    }
    char out[12], digits[5];size_t n=ok?4:5,count=0;unsigned seq=e->seq;
    memcpy(out,ok?"ACK,":"WAIT,",n);
    do { digits[count++]=(char)('0'+seq%10);seq/=10; } while(seq);
    while(count)out[n++]=digits[--count];out[n++]='\n';put(&b->reply,out,n);
}
static uint64_t le64(const uint8_t *p){uint64_t v=0;for(unsigned i=0;i<8;i++)v|=(uint64_t)p[i]<<(8*i);return v;}
static uint32_t le32(const uint8_t *p){uint32_t v=0;for(unsigned i=0;i<4;i++)v|=(uint32_t)p[i]<<(8*i);return v;}
static bool control_put(wk407_control_queue *q,unsigned source,const uint8_t *p) {
    if(source==0)return put(q,p,64);
    char line[144];static const char h[]="0123456789abcdef";memcpy(line,"C1,",3);
    for(unsigned i=0;i<64;i++){line[3+i*2]=h[p[i]>>4];line[4+i*2]=h[p[i]&15];}
    line[131]=',';uint32_t c=crc32(p,64);for(unsigned i=0;i<8;i++)line[132+i]=h[(c>>(28-i*4))&15];line[140]='\n';
    return put(q,line,141);
}
static void purge(wk407_bridge *b,unsigned origin,const uint8_t *id) {
    /* DMA owns a copy popped at submit; compaction cannot mutate active DMA. */
    for(unsigned d=0;d<2;d++) {
        wk407_bulk_queue *q=&b->bulk[d];unsigned count=q->count,kept=0;
        for(unsigned i=0;i<count;i++) {
            wk407_bulk_packet *v=&q->item[(q->head+i)%WK407_BULK_SLOTS];
            if(!memcmp(v->bytes+20,id,16)) { if(v->bytes[8]==1)b->cancelled_bytes[origin]+=le32(v->bytes+44);continue; }
            if(kept!=i)q->item[(q->head+kept)%WK407_BULK_SLOTS]=*v;kept++;
        }
        q->count=kept;
    }
}
static bool stream_control(wk407_bridge *b,unsigned source,const uint8_t *p) {
    unsigned kind=p[4],origin=p[5];uint64_t epoch=le64(p+8),generation=le64(p+32);
    if(origin>1||p[6]||p[7]||kind<1||kind>8||crc32(p,60)!=le32(p+60))return false;
    for(unsigned i=40;i<60;i++)if(p[i])return false;
    if(kind==1) {
        if(origin!=source)return false;
        if(epoch!=b->stream_session[source]) {
            b->stream_session[source]=epoch;
            for(unsigned i=0;i<2;i++){b->bulk[i].head=b->bulk[i].count=0;b->cell_size[i]=0;}
            memset(b->transactions,0,sizeof(b->transactions));memset(b->stream_generation,0,sizeof(b->stream_generation));
        }
        return true;
    }
    if(!epoch||epoch!=b->stream_session[0]||epoch!=b->stream_session[1]||!generation)return false;
    if(kind==7)return control_put(&b->urgent[1-source],source,p);
    wk407_transaction *found=NULL,*empty=NULL;
    for(unsigned i=0;i<4;i++){
        wk407_transaction *t=&b->transactions[origin][i];
        if(t->used&&!memcmp(t->id,p+16,16))found=t;
        if(!t->used)empty=t;
    }
    if(kind==2) { /* receiver grants admission; old grants cannot resurrect */
        if(source==origin)return false;
        if(found){if(found->generation!=generation)return false;}
        else {
            if(generation<=b->stream_generation[origin]||!empty)return false;
            found=empty;found->used=true;found->generation=generation;memcpy(found->id,p+16,16);
            b->stream_generation[origin]=generation;
        }
    } else if(kind==3||kind==6) {
        if(kind==6&&source!=origin)return false;
        if(found&&found->generation!=generation)return false;
        if(found)found->used=false;
        if(generation>b->stream_generation[origin])b->stream_generation[origin]=generation;
        purge(b,origin,p+16);

    }
    return control_put(&b->urgent[1-source],source,p);
}
bool wk407_clipboard(wk407_bridge *b,unsigned source,const uint8_t *p,size_t n) {
    if(source>1||n!=64||!b->online[source])return false;
    if(!memcmp(p,"WKI1",4))return b->local_report&&b->local_report(b->local_context,source,p,n);
    if(!b->online[0]||!b->online[1])return false;
    if(!memcmp(p,"WKB5",4))return stream_control(b,source,p);
    return control_put(&b->clipboard[1-source],source,p);
}
void wk407_control(wk407_bridge *b,const uint8_t *bytes,size_t size,uint32_t now) {
    for(size_t i=0;i<size;i++) {
        uint8_t c=bytes[i];if(c=='\r')continue;
        if(c!='\n'){if(b->line_size<sizeof(b->line)-1&&!b->discarding)b->line[b->line_size++]=(char)c;else b->discarding=true;continue;}
        if(!b->discarding) {
            if(b->line_size==140&&!memcmp(b->line,"C1,",3)&&b->line[131]==',') {
                uint8_t p[64];bool valid=true;uint32_t expected=0;
                for(unsigned j=0;j<64;j++){int a=hex(b->line[3+j*2]),d=hex(b->line[4+j*2]);if(a<0||d<0){valid=false;break;}p[j]=(uint8_t)(a*16+d);}
                for(unsigned j=132;j<140;j++){int v=hex(b->line[j]);if(v<0){valid=false;break;}expected=(expected<<4)|(unsigned)v;}
                if(!valid||expected!=crc32(p,64)||!wk407_clipboard(b,0,p,64))b->rejected++;
            } else {
                wk_parser_t parser;wk_parser_init(&parser);wk_event_t e;wk_error_t error;int result=0;
                for(unsigned j=0;j<b->line_size;j++)result=wk_parser_feed(&parser,(uint8_t)b->line[j],&e,&error);
                result=wk_parser_feed(&parser,'\n',&e,&error);
                if(result==1)event(b,&e,now);else b->rejected++;
            }
        } else b->rejected++;
        b->line_size=0;b->discarding=false;
    }
}
bool wk407_bulk_space(const wk407_bridge *b,unsigned source) { return source<2&&b->online[0]&&b->online[1]&&b->bulk[1-source].count<WK407_BULK_SLOTS; }
static bool admitted(const wk407_bridge *b,unsigned source,const uint8_t *cell) {
    if(memcmp(cell,"WKS5",4)||le32(cell+4)!=512||le32(cell+44)>432)return false;
    uint64_t e=le64(cell+12);if(!e||e!=b->stream_session[0]||e!=b->stream_session[1])return false;
    unsigned origin=cell[8]==1||cell[8]==2?source:1-source;
    if(cell[8]!=1&&cell[8]!=2&&cell[8]!=3&&cell[8]!=5)return false;
    for(unsigned i=0;i<4;i++)if(b->transactions[origin][i].used&&!memcmp(b->transactions[origin][i].id,cell+20,16))return true;
    return false;
}
bool wk407_bulk_accept(wk407_bridge *b,unsigned source,const void *data,size_t n) {
    if(!wk407_bulk_space(b,source)||n>512)return false;
    const uint8_t *p=data;size_t i=0;uint8_t *cell=b->cell[source];unsigned used=b->cell_size[source];
    while(i<n) {
        /* Synchronize only the prefix. Once matched, copy the bounded remainder
         * without rechecking the same four bytes for every payload byte. */
        if(used<4){size_t take=4-used;if(take>n-i)take=n-i;memcpy(cell+used,p+i,take);used+=(unsigned)take;i+=take;if(used<4)break;}
        if(memcmp(cell,"WKS5",4)){memmove(cell,cell+1,3);used=3;continue;}
        size_t take=512-used;if(take>n-i)take=n-i;
        memcpy(cell+used,p+i,take);used+=(unsigned)take;i+=take;
        if(used==512) {
            if(admitted(b,source,cell)) {
                wk407_bulk_queue *q=&b->bulk[1-source];wk407_bulk_packet *v=&q->item[(q->head+q->count)%WK407_BULK_SLOTS];
                memcpy(v->bytes,cell,512);v->size=512;q->count++;
                if(q->count>b->bulk_high_water)b->bulk_high_water=q->count;
            }
            used=0;
        }
    }
    b->cell_size[source]=(uint16_t)used;return true;
}
const wk407_bulk_packet *wk407_bulk_peek(const wk407_bridge *b,unsigned d) { return d<2&&b->bulk[d].count?&b->bulk[d].item[b->bulk[d].head]:NULL; }
void wk407_bulk_done(wk407_bridge *b,unsigned d) { if(d<2&&b->bulk[d].count){wk407_bulk_queue *q=&b->bulk[d];b->forwarded[d]+=q->item[q->head].size;q->head=(q->head+1)%WK407_BULK_SLOTS;q->count--;} }
const wk407_hid_packet *wk407_hid_peek(const wk407_bridge *b) { return b->hid.count?&b->hid.item[b->hid.head]:NULL; }
void wk407_hid_done(wk407_bridge *b) { if(b->hid.count){b->hid.head=(b->hid.head+1)%WK407_HID_SLOTS;b->hid.count--;} }
const wk407_control_packet *wk407_reply_peek(const wk407_bridge *b){return peek(&b->reply);}
void wk407_reply_done(wk407_bridge *b){pop(&b->reply);}
const wk407_control_packet *wk407_clipboard_peek(const wk407_bridge *b,unsigned d){return d<2?peek(&b->clipboard[d]):NULL;}
void wk407_clipboard_done(wk407_bridge *b,unsigned d){if(d<2)pop(&b->clipboard[d]);}

const wk407_control_packet *wk407_urgent_peek(const wk407_bridge *b,unsigned d){return d<2?peek(&b->urgent[d]):NULL;}
void wk407_urgent_done(wk407_bridge *b,unsigned d){if(d<2)pop(&b->urgent[d]);}
