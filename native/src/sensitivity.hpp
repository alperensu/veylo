#pragma once
#include <algorithm>
#include <cmath>

namespace ses {
// Independent transmission control. The detector runs once per 10 ms block;
// attack/release run at 48 kHz. Level control uses existing audio lookahead;
// speech control follows the delayed RNNoise VAD, with no extra frame delay.
// No allocation, locks, or gain above unity, including in expander mode.
class Sensitivity {
    float threshold=-50, gain=1, wantedGain=1;
    float attack=.0103626f, release=.000173596f, hysteresis=6, ratio=2, maxReduction=24;
    unsigned hold=0, holdBlocks=30;
    bool open=false, initial=true, expander=false;
    static float safe(float value,float fallback,float low,float high){return std::isfinite(value)?std::clamp(value,low,high):fallback;}
public:
    void reset(){threshold=-50;gain=wantedGain=1;hold=0;open=false;initial=true;}
    void configure(unsigned mode,float attackMs,float holdMs,float releaseMs,float hysteresisDb,float expansionRatio,float maxReductionDb){
        expander=mode==1;
        attack=-std::expm1(-1.f/(48000.f*.001f*safe(attackMs,2,.1f,100)));
        release=-std::expm1(-1.f/(48000.f*.001f*safe(releaseMs,120,5,2000)));
        holdBlocks=unsigned(std::ceil(safe(holdMs,300,0,2000)/10));hold=std::min(hold,holdBlocks);
        hysteresis=safe(hysteresisDb,6,0,24);ratio=safe(expansionRatio,2,1,8);maxReduction=safe(maxReductionDb,24,0,60);
    }
    void observe(bool enabled,bool automatic,float manual,float ambient,float level,float vad,bool speechAware=false){
        ambient=safe(ambient,-60,-120,-15);level=safe(level,-120,-120,24);vad=safe(vad,0,0,1);
        float wanted=automatic?std::clamp(ambient+10,-75.f,-20.f):safe(manual,-50,-90,-10);
        if(initial)threshold=wanted;
        else if(!automatic)threshold=wanted;
        else threshold+=std::clamp(wanted-threshold,-.02f,.02f); // <=2 dB/s
        if(!enabled){open=true;hold=0;wantedGain=1;}
        else {
            // In automatic soft expansion with RNNoise, loud non-speech must
            // neither open the detector nor keep renewing its speech hold.
            // Manual level control and the legacy gate retain their behavior.
            const bool voiceControl=automatic&&expander&&speechAware;
            bool detected=voiceControl?(vad>=.2f&&level>ambient+3):
                (level>=threshold || (automatic&&vad>=.2f&&level>ambient+3));
            if(detected || (!voiceControl&&open&&level>=threshold-hysteresis)){open=true;hold=holdBlocks;}
            else if(hold)--hold;
            else open=false;
            wantedGain=open?1.f:0.f;
            if(expander&&!open){
                // A 6 dB soft knee below the threshold joins unity smoothly.
                float deficit=std::max(0.f,threshold-level);
                float knee=deficit<6?deficit*deficit/12:deficit-3;
                // A bounded probability floor also attenuates loud non-speech;
                // level-only expansion would return unity for those sounds.
                // Preserve unity ratio and the user's maximum reduction.
                float uncertainty=voiceControl?30.f*std::clamp(1.f-vad/.2f,0.f,1.f):0.f;
                float reduction=std::min(maxReduction,(ratio-1)*std::max(knee,uncertainty));
                wantedGain=std::pow(10.f,-reduction/20);
            }
        }
        if(initial)gain=enabled?(expander?wantedGain:0.f):1.f;
        initial=false;
    }
    float tick(){gain+=(wantedGain-gain)*(wantedGain>gain?attack:release);if(gain<.00001f)gain=0;return gain;}
    float appliedThreshold()const{return threshold;}
    float appliedGain()const{return gain;}
};
}
