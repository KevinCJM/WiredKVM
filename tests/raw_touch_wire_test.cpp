#include "raw_touch_wire.hpp"
#include <cassert>
#include <iostream>
int main(){
    wk::RawTouchWire wire;
    const std::string hex="020000000000000031000088";
    assert(wire.accept("H B 1",false).empty());
    assert(wire.accept("H D 1 "+hex,true).empty());
    assert(wire.accept("H B 1",true)=="MT2B,1\n");
    assert(wire.accept("H D 1 "+hex,true)=="MT2D,1,"+hex+"\n");
    for(auto bad:{"H B -1","H B 4294967296","H B 1 injected","H D 1 xxxxxxxxxxxxxxxxxxxxxxxx","H E 2"})assert(wire.accept(bad,true).empty());
    assert(wire.leave()=="MT2E,1\n");assert(wire.accept("H D 1 "+hex,true).empty());
    wk::RawTouchFrames q;
    const auto data=[&](unsigned state,unsigned id){std::string bytes=hex;bytes+="000000";bytes+="0123456789abcdef"[state];bytes+="048301f408";bytes+="0123456789abcdef"[id];return "MT2D,1,"+bytes+"\n";};
    assert(q.offer(data(8,0)));
    for(unsigned i=0;i<100000;i++)assert(q.offer(data(8,0)));
    assert(q.offer(data(12,0))); // topology differs, release retained
    unsigned count=0;while(!q.empty()){count++;q.pop();}assert(count>=3&&count<=4);
    // Unique topology fills bounded slots; failure flushes rather than replaying.
    bool failed=false;for(unsigned i=0;i<30;i++)if(!q.offer(data(i%2?8:12,i%10))){failed=true;break;}
    assert(failed&&q.empty());
    std::cout<<"RAW_TOUCH_WIRE_PASS flood=100000 terminal_order=true local_and_stale_filtered=true\n";
}
