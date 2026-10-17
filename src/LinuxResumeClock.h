#ifndef IOKITD_LINUX_RESUME_CLOCK_H
#define IOKITD_LINUX_RESUME_CLOCK_H
#include <cstdint>

// CLOCK_BOOTTIME includes suspend; CLOCK_MONOTONIC excludes it. Bracket the
// boottime read with monotonic reads so scheduling delays are not sleep events.
// This observes resume only. It cannot authorize, delay, or announce suspend.
class LinuxResumeClock {
public:
    bool observe(int64_t before, int64_t boot, int64_t after) {
        if (before < 0 || boot < after || after < before || after - before > 20000000)
            return false;
        const int64_t lower = boot - after, upper = boot - before;
        const bool resumed = valid && before >= lastAfter && lower > lastUpper &&
            lower - lastUpper > 100000000;
        lastAfter = after;
        lastUpper = upper;
        valid = true;
        return resumed;
    }
private:
    bool valid = false;
    int64_t lastAfter = 0, lastUpper = 0;
};
#endif
