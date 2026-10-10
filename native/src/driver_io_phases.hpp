#pragma once
#include <cstdint>

namespace ses {
enum class DriverIssuePath : std::uint8_t { NotAttempted=0, ImmediateSuccess=1, ImmediateFailure=2, Pending=3 };
enum class DriverResultPath : std::uint8_t { NotAttempted=0, Success=1, Failure=2, Incomplete=3 };
// Optional worker-only observations, never kernel execution/CPU time. A pending
// request can probe GetOverlappedResult twice; result elapsed is their sum and
// resultPath describes the last probe. Cancellation/grace are outside that sum.
struct DriverIoPhases {
    std::uint64_t issue100ns=0,wait100ns=0,result100ns=0;
    std::uint32_t waitReturn=0xffffffffu;
    DriverIssuePath issuePath=DriverIssuePath::NotAttempted;
    DriverResultPath resultPath=DriverResultPath::NotAttempted;
    std::uint8_t resultCalls=0,observations=0;
    static constexpr std::uint8_t issueAvailable=1,waitAvailable=2,resultAvailable=4,waitAttempted=8;
};
static_assert(sizeof(DriverIoPhases)==32);
using DriverIoClock=bool(*)(std::uint64_t&);
}
