#pragma once
#include <algorithm>
namespace ses {
// Playback-thread owned. Integral correction learns the clock difference instead
// of draining a block-sized FIFO to obtain a persistent negative correction.
class ClockController {
    double integral_=0;
public:
    void reset(){integral_=0;}
    double ratio(double fill,unsigned target,unsigned frames,unsigned normalization=0){
        const double error=(fill-target)/std::max(1u,normalization?normalization:target);
        integral_=std::clamp(integral_+error*.000001*(frames/480.),-.001,.001);
        return 1+std::clamp(error*.002+integral_,-.001,.001);
    }
};
}
