#pragma once
#include <algorithm>
namespace ses {
// Proportional drift correction has enough negative authority before the FIFO empties.
inline double clock_ratio(double fill, unsigned target) {
    return 1+std::clamp((fill-target)/std::max(1u,target)*.002,-.001,.001);
}
}
