#pragma once
#include <string>
#include <sstream>
#include <cstdint>
#include <deque>

namespace wk {
// Local helper protocol is never passed through as arbitrary firmware text.
class RawTouchWire {
    uint32_t epoch_=0;
public:
    std::string leave(){if(!epoch_)return {};auto e=epoch_;epoch_=0;return "MT2E,"+std::to_string(e)+"\n";}
    std::string accept(const std::string &row,bool remote){
        std::istringstream in(row);std::string h,kind,number,hex,extra;
        if(!(in>>h>>kind>>number)||h!="H"||number.empty()||number.size()>10)return {};
        uint64_t n=0;for(char c:number){if(c<'0'||c>'9')return {};n=n*10+c-'0';}
        if(n==0||n>UINT32_MAX)return {};
        if(kind=="E"||kind=="B"){
            if(in>>extra)return {};
            if(kind=="E")return n==epoch_?leave():"";
            if(!remote)return {};epoch_=static_cast<uint32_t>(n);return "MT2B,"+number+"\n";
        }
        if(kind!="D"||!remote||n!=epoch_||!(in>>hex)||in>>extra||hex.size()<24||hex.size()>114||hex.size()%2)return {};
        for(char c:hex)if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return {};
        return "MT2D,"+number+","+hex+"\n";
    }
};
class RawTouchFrames {
    std::deque<std::string> queue_;
    static std::string topology(const std::string &packet){
        const auto comma=packet.find_last_of(',');if(comma==std::string::npos)return {};
        const auto raw=packet.substr(comma+1);std::string key;
        // Hex contact state and ID, including release records. Coordinate-only
        // changes may replace a tail; finger begin/end must retain their order.
        for(size_t n=24;n+18<=raw.size();n+=18){key+=raw.substr(n+6,1);key+=raw.substr(n+17,1);}
        return key;
    }
public:
    bool offer(std::string packet){
        if(queue_.size()>1 && topology(queue_.back())==topology(packet)){queue_.back()=std::move(packet);return true;}
        if(queue_.size()>=16){clear();return false;}queue_.push_back(std::move(packet));return true;
    }
    bool empty()const{return queue_.empty();}
    const std::string &front()const{return queue_.front();}
    void pop(){queue_.pop_front();}
    void clear(){queue_.clear();}
};
}
