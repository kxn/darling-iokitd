#ifndef IOKITD_IOMATCHINGNOTIFICATION_H
#define IOKITD_IOMATCHINGNOTIFICATION_H
#include "IOIterator.h"
#include "IOService.h"
#include <deque>

// Main-queue confined, like the registry and the IOObject Mach demultiplexer.
class IOMatchingNotification : public IOIterator {
public:
    enum class Kind { Publish, FirstPublish, Matched, FirstMatch, Terminated };
    IOMatchingNotification(Kind kind, NSDictionary* matching, mach_port_t wake,
        const uint64_t* references, unsigned count);
    ~IOMatchingNotification() override;
    IOObject* next() override;
    void reset() override {} // Native notification iterators cannot rewind.
    void serviceChanged(IOService* service, bool terminated, bool first);
    void enqueue(IOObject* service);
    Kind kind() const { return m_kind; }
    NSDictionary* matching() const { return m_matching; }
private:
    void ping();
    Kind m_kind;
    NSDictionary* m_matching;
    mach_port_t m_wake;
    uint64_t m_references[8] = {};
    unsigned m_referenceCount;
    std::deque<IOObject*> m_pending;
    bool m_armed = false;
    bool m_retryScheduled = false;
    uint64_t m_cookie;
    uint64_t m_retryEpoch = 0;
    static uint64_t s_nextCookie;
};
#endif
