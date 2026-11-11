#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>
extern "C" {
#include "bridge.h"
}
#include "desktop_pointer.hpp"
#include "clipboard_channel.hpp"
#ifdef WK407_COPY_BUDGET
static uint64_t copied_bytes, copy_calls;
extern "C" void *wk407_test_memcpy(void *d,const void *s,size_t n) {
    copied_bytes+=n;copy_calls++;return std::memcpy(d,s,n);
}
#endif
static void command(wk407_bridge &b,unsigned seq,char kind,int a,int c,uint32_t now,bool ack=true) {
    char p[96];int n=snprintf(p,sizeof(p),"WK1,%u,%c,%d,%d",seq,kind,a,c);
    uint8_t crc=wk_crc8(reinterpret_cast<uint8_t*>(p),size_t(n));n+=snprintf(p+n,sizeof(p)-size_t(n),",%02x\n",crc);
    // Deliberately split every command in the middle of its ASCII sequence.
    wk407_control(&b,reinterpret_cast<uint8_t*>(p),3,now);wk407_control(&b,reinterpret_cast<uint8_t*>(p+3),size_t(n-3),now);
    auto r=wk407_reply_peek(&b);assert(r);assert(!memcmp(r->bytes,ack?"ACK,":"WAIT,",ack?4:5));wk407_reply_done(&b);
}
static void drain(wk407_bridge &b){while(wk407_hid_peek(&b))wk407_hid_done(&b);}
static void little(uint8_t *p,uint64_t n,unsigned bytes){for(unsigned i=0;i<bytes;i++)p[i]=uint8_t(n>>(8*i));}
static bool control(wk407_bridge &b,unsigned source,unsigned kind,unsigned origin,uint64_t gen=1,uint8_t id=7) {
    uint8_t p[64]={};memcpy(p,"WKB5",4);p[4]=uint8_t(kind);p[5]=uint8_t(origin);little(p+8,12345,8);memset(p+16,id,16);little(p+32,gen,8);
    uint32_t crc=~0u;for(unsigned i=0;i<60;i++){crc^=p[i];for(unsigned j=0;j<8;j++)crc=(crc>>1)^((crc&1)?0xedb88320u:0);}
    little(p+60,~crc,4);bool ok=wk407_clipboard(&b,source,p,64);while(wk407_urgent_peek(&b,1-source))wk407_urgent_done(&b,1-source);return ok;
}
static void bulk_boundaries() {
    wk407_bridge b;uint8_t packet[512]={};memcpy(packet,"WKS5",4);little(packet+4,512,4);packet[8]=1;
    little(packet+12,12345,8);memset(packet+20,7,16);little(packet+44,432,4);
    for(unsigned i=80;i<512;i++)packet[i]=uint8_t(i*37);
    for(unsigned source=0;source<2;source++)for(unsigned cut=0;cut<=512;cut++) {
        wk407_init(&b);wk407_connected(&b,0,true,0);wk407_connected(&b,1,true,0);
        assert(control(b,0,1,0)&&control(b,1,1,1)&&control(b,1-source,2,source));
        assert(wk407_bulk_accept(&b,source,packet,cut));
        assert(wk407_bulk_accept(&b,source,packet+cut,512-cut));
        auto received=wk407_bulk_peek(&b,1-source);
        assert(received&&received->size==512&&!memcmp(received->bytes,packet,512));
        wk407_bulk_done(&b,1-source);assert(!wk407_bulk_peek(&b,1-source)&&!b.cell_size[source]);
        const uint8_t noise[]={'x','W','K','S','z','W','K','W','W'};
        for(uint8_t c:noise)assert(wk407_bulk_accept(&b,source,&c,1));
        for(unsigned i=0;i<512;i++)assert(wk407_bulk_accept(&b,source,packet+i,1));
        received=wk407_bulk_peek(&b,1-source);assert(received&&!memcmp(received->bytes,packet,512));
        wk407_bulk_done(&b,1-source);assert(!wk407_bulk_peek(&b,1-source));
        command(b,17,'A',1,2,0);drain(b);
    }
    std::cout<<"BULK_BOUNDARIES_PASS splits=1026 noise_resync=true byte_fragments=true input_retained=true\n";
}
int main(int argc,char **argv) {
#ifdef WK407_COPY_BUDGET
    if(argc==2&&!std::strcmp(argv[1],"--copy-budget")) {
        for(unsigned source=0;source<2;source++) {
            wk407_bridge b;wk407_init(&b);wk407_connected(&b,0,true,0);wk407_connected(&b,1,true,0);
            assert(control(b,0,1,0)&&control(b,1,1,1)&&control(b,1-source,2,source));
            alignas(4) uint8_t packet[512]={};memcpy(packet,"WKS5",4);little(packet+4,512,4);packet[8]=1;
            little(packet+12,12345,8);memset(packet+20,7,16);little(packet+44,432,4);
            for(unsigned i=80;i<512;i++)packet[i]=uint8_t(i*37);
            for(unsigned i=0;i<32;i++) {
                copied_bytes=copy_calls=0;assert(wk407_bulk_accept(&b,source,packet,512));
                assert(copied_bytes==512&&copy_calls==1);
                auto p=&b.bulk[1-source].item[i];assert(!(reinterpret_cast<uintptr_t>(p->bytes)&3));
                assert(p->size==512&&!memcmp(p->bytes,packet,512));
            }
            assert(!wk407_bulk_accept(&b,source,packet,512));
            command(b,99,'A',13,17,1);drain(b);
        }
        std::cout<<"BULK_COPY_BUDGET_PASS directions=2 slots=32 copiesPerFullCell=1 copiedBytes=512 payloadAlignment=4 input_retained=true physicalUSB=false\n";
        return 0;
    }
#else
    (void)argc;(void)argv;
#endif
    bulk_boundaries();
    wk407_bridge b;wk407_init(&b);wk407_connected(&b,0,true,0);wk407_connected(&b,1,true,0);
    assert(!wk407_hid_peek(&b)); // attaching a fresh keyboard must not warp the pointer
    uint8_t bytes[512]={};memcpy(bytes,"WKS5",4);little(bytes+4,512,4);bytes[8]=1;
    little(bytes+12,12345,8);memset(bytes+20,7,16);little(bytes+44,432,4);
    assert(control(b,0,1,0)&&control(b,1,1,1));
    assert(control(b,1,2,0)&&control(b,0,2,1));
    wk::ClipboardChannel::Report clip{};for(unsigned i=0;i<64;i++)clip[i]=uint8_t(i*17);
    auto wire=wk::ClipboardChannel::encode(clip);
    for(unsigned i=0;i<32;i++) {
        wk407_control(&b,reinterpret_cast<const uint8_t*>(wire.data()),wire.size(),0);
        assert(wk407_clipboard(&b,1,clip.data(),clip.size()));
    }
    assert(!wk407_clipboard(&b,1,clip.data(),clip.size()));
    command(b,5,'P',0,0,0); // clipboard pressure cannot consume HID ACK capacity
    for(unsigned i=0;i<32;i++) {
        auto target=wk407_clipboard_peek(&b,1);assert(target&&target->size==64&&!memcmp(target->bytes,clip.data(),64));
        auto host=wk407_clipboard_peek(&b,0);assert(host);
        wk::ClipboardChannel::Report decoded{};
        assert(wk::ClipboardChannel::decode(std::string(reinterpret_cast<const char*>(host->bytes),host->size-1),decoded)&&decoded==clip);
        wk407_clipboard_done(&b,0);wk407_clipboard_done(&b,1);
    }
    auto damaged=wire;damaged[10]=damaged[10]=='0'?'1':'0';
    wk407_control(&b,reinterpret_cast<const uint8_t*>(damaged.data()),damaged.size(),0);assert(!wk407_clipboard_peek(&b,1));
    for(unsigned i=0;i<32;i++)for(unsigned p=0;p<2;p++)assert(wk407_bulk_accept(&b,p,bytes,512));
    assert(!wk407_bulk_space(&b,0)&&!wk407_bulk_space(&b,1));
    for(bool left:{false,true}) {
        wk::DesktopPointer pointer({},left);pointer.enter(5000);
        const int outward=left?1:-1;
        assert(!pointer.move(100*outward,0,true)); // held drag cannot return
        assert(!pointer.move(47*outward,0,false));
        assert(pointer.move(outward,0,false)); // exact existing 48px return gate
        auto position=pointer.report();command(b,9,'A',position.a,position.b,0);drain(b);
        command(b,10,'R',0,0,0);drain(b);pointer.leave();assert(!pointer.active());
    }
    // Full file queues remain stalled during 120,000 keyboard/pointer updates.
    for(unsigned i=1;i<=120000;i++) {
        command(b,i%65536,'A',int(i%32768),17,i);
        auto r=wk407_hid_peek(&b);assert(r&&r->endpoint==2&&r->bytes[0]==3);drain(b);
        if(i%7==0){command(b,(i+1)%65536,'B',1,0,i);drain(b);command(b,(i+2)%65536,'B',0,0,i);drain(b);}
        if(i%13==0){command(b,(i+3)%65536,'T',4,1,i);drain(b);command(b,(i+4)%65536,'T',4,0,i);drain(b);}
    }
    for(unsigned p=0;p<2;p++)for(unsigned i=0;i<32;i++){auto r=wk407_bulk_peek(&b,p);assert(r&&r->size==512&&!memcmp(r->bytes,bytes,512));wk407_bulk_done(&b,p);}
    // Drag state survives absolute movement; release bypasses a full HID queue.
    command(b,31,'B',1,0,120001);drain(b);command(b,32,'A',100,200,120002);
    assert(wk407_hid_peek(&b)->bytes[1]==1);drain(b);
    for(unsigned i=0;i<59;i++)command(b,100+i,'A',int(i),2,120003);
    command(b,200,'A',4,5,120004,false);command(b,201,'R',0,0,120005);assert(!b.buttons&&!b.modifiers&&b.hid.count==4);drain(b);
    // Partial USB completion: queue head remains pinned until done().
    assert(wk407_bulk_accept(&b,0,bytes,512));auto pinned=wk407_bulk_peek(&b,1);
    for(unsigned i=0;i<31;i++)assert(wk407_bulk_accept(&b,0,bytes,512));
    assert(pinned==wk407_bulk_peek(&b,1)&&!memcmp(pinned->bytes,bytes,512));
    command(b,202,'T',8,1,120006);drain(b);wk407_tick(&b,122506);assert(b.watchdog_releases==1);drain(b);
    // Cancel while body stalled: no queue drain, then immediately grant new ID.
    assert(control(b,1,3,0));assert(b.bulk[1].count==0);
    assert(!control(b,1,2,0)); // replay of cancelled grant rejected
    assert(wk407_bulk_accept(&b,0,bytes,512));assert(!wk407_bulk_peek(&b,1));
    assert(control(b,1,2,0,2,8));memset(bytes+20,8,16);
    assert(wk407_bulk_accept(&b,0,bytes,173));assert(wk407_bulk_accept(&b,0,bytes+173,339));
    assert(wk407_bulk_peek(&b,1));command(b,210,'A',2,3,122506);drain(b);
    wk407_connected(&b,1,false,122507);assert(b.bulk[0].count==0&&b.bulk[1].count==0);
    command(b,203,'S',0,0,122508,false);wk407_connected(&b,1,true,122509);drain(b);command(b,204,'S',0,0,122510);
    command(b,205,'T',4,1,122510);drain(b);wk407_connected(&b,1,false,122510);
    assert(b.release_pending);wk407_connected(&b,1,true,122510);assert(!b.release_pending&&b.hid.count==4);drain(b);
    // Same Fn-only metadata as the installed ESP32 path, with bounded priority
    // reports; ordinary keyboard HID never waits for the companion.
    while(wk407_urgent_peek(&b,1))wk407_urgent_done(&b,1);
    command(b,206,'C',16,0,122600);drain(b);
    auto down=wk407_urgent_peek(&b,1);assert(down&&!memcmp(down->bytes,"WKFN",4)&&down->bytes[5]==1&&down->bytes[6]==1);wk407_urgent_done(&b,1);
    command(b,207,'C',0,0,122680);drain(b);
    auto up=wk407_urgent_peek(&b,1);assert(up&&up->bytes[5]==2&&up->bytes[6]==1&&up->bytes[24]==80);wk407_urgent_done(&b,1);
    // Parser abuse cannot allocate, forward a partial report, or grow queues.
    uint32_t random=1;for(unsigned i=0;i<500000;i++){random=random*1664525+1013904223;uint8_t c=uint8_t(random>>24);wk407_control(&b,&c,1,122510);}
    drain(b);
    std::cout<<"CORE_PASS {\"hid_events\":120000,\"bulk_stall_both_directions\":true,\"bridge_bytes\":"<<sizeof(b)<<",\"bulk_high_water\":"<<b.bulk_high_water<<",\"parser_fuzz_bytes\":500000}\n";
}
