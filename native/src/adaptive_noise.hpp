#pragma once
#include <algorithm>
#include <cmath>

namespace ses {
// One update per 10 ms audio frame. Speech and a 300 ms hangover are excluded
// from the ambient estimate. No gate, allocation or extra inference is used.
class AdaptiveNoise {
    float floor=-60;
    unsigned speechHold=0;
public:
    void reset(float calibratedFloor){floor=std::clamp(calibratedFloor,-100.f,-20.f);speechHold=0;}
    float observe(float inputDb,float speechProbability){
        if(!std::isfinite(inputDb)||!std::isfinite(speechProbability))return floor;
        if(speechProbability>=.35f)speechHold=30;
        else if(speechHold)--speechHold;
        else if(speechProbability<=.15f&&inputDb<-.5f){
            const float ambient=std::clamp(inputDb,-100.f,-20.f);
            floor+=(ambient-floor)*(ambient>floor?.01f:.002f);
        }
        return floor;
    }
    float strength()const{return std::clamp(.4f+(floor+65.f)*(.55f/35.f),.35f,.95f);}
};
}
