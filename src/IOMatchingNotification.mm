#include "IOMatchingNotification.h"
#include "ServiceRegistry.h"
#include "iokitd.h"
#include <IOKit/IOCFUnserialize.h>
#include <IOKit/OSMessageNotification.h>
#include <Foundation/NSString.h>
#include <os/log.h>
#include <cstring>
#include <algorithm>
extern "C" {
#include "iokitmigServer.h"
}

uint64_t IOMatchingNotification::s_nextCookie = 0;

IOMatchingNotification::IOMatchingNotification(Kind kind, NSDictionary* matching,
    mach_port_t wake, const uint64_t* references, unsigned count)
    : IOIterator({}), m_kind(kind), m_matching([matching copy]), m_wake(wake), m_referenceCount(count), m_cookie(++s_nextCookie)
{
    std::copy(references, references + count, m_references);
    ServiceRegistry::instance()->addNotification(this);
    if (kind != Kind::Terminated)
        for (auto* service : ServiceRegistry::instance()->matchingServices(matching)) enqueue(service);
}
IOMatchingNotification::~IOMatchingNotification()
{
    ServiceRegistry::instance()->removeNotification(this);
    for (auto* object : m_pending) object->release();
    [m_matching release];
    if (MACH_PORT_VALID(m_wake)) mach_port_deallocate(mach_task_self(), m_wake);
}
IOObject* IOMatchingNotification::next()
{
    if (m_pending.empty()) { m_armed = true; return nullptr; }
    auto* object = m_pending.back();
    m_pending.pop_back();
    // The MIG reply copies the service capability before this queued release.
    object->releaseLater();
    return object;
}
void IOMatchingNotification::serviceChanged(IOService* service, bool terminated, bool first)
{
    if (terminated != (m_kind == Kind::Terminated)) return;
    if (!first && (m_kind == Kind::FirstPublish || m_kind == Kind::FirstMatch)) return;
    if (service->matches(m_matching)) enqueue(service);
}
void IOMatchingNotification::enqueue(IOObject* service)
{
    if (std::find(m_pending.begin(), m_pending.end(), service) != m_pending.end()) return;
    bool notify = m_armed && m_pending.empty();
    service->retain();
    m_pending.push_back(service);
    if (notify) { m_armed = false; ping(); }
}
void IOMatchingNotification::ping()
{
    if (!MACH_PORT_VALID(m_wake)) return;
    // Apple's ping includes only the supplied async references, not the full
    // eight-slot maximum, and transfers a fresh notifier send right.
    struct { mach_msg_header_t head; OSNotificationHeader64 notification; } packet = {};
    packet.head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND);
    packet.head.msgh_remote_port = m_wake;
    packet.head.msgh_local_port = port();
    packet.head.msgh_id = kOSNotificationMessageID;
    packet.head.msgh_size = sizeof(mach_msg_header_t) + 8 + m_referenceCount * sizeof(uint64_t);
    packet.notification.type = m_kind == Kind::Terminated ? kIOServiceTerminatedNotificationType :
        (m_kind == Kind::Matched || m_kind == Kind::FirstMatch) ? kIOServiceMatchedNotificationType : kIOServicePublishNotificationType;
    std::copy(m_references, m_references + m_referenceCount, packet.notification.reference);
    auto result = mach_msg(&packet.head, MACH_SEND_MSG | MACH_SEND_TIMEOUT, packet.head.msgh_size,
        0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
    if (result == MACH_SEND_TIMED_OUT || result == MACH_SEND_INVALID_DEST) {
        // A failed send can return freshly copied rights in pseudo-receive form.
        // Destroy those returned rights, without consuming the original wake right.
        auto localType = MACH_MSGH_BITS_LOCAL(packet.head.msgh_bits);
        if (MACH_PORT_VALID(packet.head.msgh_local_port) &&
            (localType == MACH_MSG_TYPE_MOVE_SEND || localType == MACH_MSG_TYPE_MOVE_SEND_ONCE))
            mach_port_deallocate(mach_task_self(), packet.head.msgh_local_port);
        mach_msg_destroy(&packet.head);
    }
    if (result == MACH_SEND_TIMED_OUT && !m_retryScheduled) {
        // A retry must not own a send right to its notifier: that would prevent
        // NO_SENDERS cleanup when the subscriber deregisters while its queue is full.
        m_retryScheduled = true;
        const auto expectedCookie = m_cookie, expectedEpoch = ++m_retryEpoch;
        const auto objectPort = port();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 10), dispatch_get_main_queue(), ^{
            auto* token = dynamic_cast<IOMatchingNotification*>(IOObject::lookup(objectPort));
            if (!token || token->m_cookie != expectedCookie || token->m_retryEpoch != expectedEpoch || !token->m_retryScheduled) return;
            token->m_retryScheduled = false;
            if (!token->m_pending.empty() && !token->m_armed) token->ping();
        });
    } else if (result == KERN_SUCCESS) {
        m_retryScheduled = false;
        ++m_retryEpoch;
    } else if (result != MACH_SEND_TIMED_OUT) {
        os_log_error(OS_LOG_DEFAULT, "IOKit matching notification delivery failed: %d", result);
    }
}

static kern_return_t subscribe(mach_port_t master, const char* type, const void* bytes, unsigned size,
    mach_port_t wake, const uint64_t* references, unsigned count, mach_port_t* notification)
{
    *notification = MACH_PORT_NULL;
    if (master != g_masterPort) return kIOReturnNotPrivileged;
    if (!size || size > sizeof(io_struct_inband_t) * 1024 || count > kOSAsyncRef64Count) return kIOReturnBadArgument;
    IOMatchingNotification::Kind kind;
    if (!std::strcmp(type,kIOPublishNotification)) kind=IOMatchingNotification::Kind::Publish;
    else if (!std::strcmp(type,kIOFirstPublishNotification)) kind=IOMatchingNotification::Kind::FirstPublish;
    else if (!std::strcmp(type,kIOMatchedNotification)) kind=IOMatchingNotification::Kind::Matched;
    else if (!std::strcmp(type,kIOFirstMatchNotification)) kind=IOMatchingNotification::Kind::FirstMatch;
    else if (!std::strcmp(type,kIOTerminatedNotification)) kind=IOMatchingNotification::Kind::Terminated;
    else return kIOReturnUnsupported;
    CFStringRef error = nullptr;
    CFTypeRef criteria = IOCFUnserializeWithSize((const char*)bytes,size,kCFAllocatorDefault,0,&error);
    if (error) CFRelease(error);
    if (!criteria) return kIOReturnBadArgument;
    if (CFGetTypeID(criteria) != CFDictionaryGetTypeID()) { CFRelease(criteria); return kIOReturnBadArgument; }
    auto* token = new IOMatchingNotification(kind,(NSDictionary*)criteria,wake,references,count);
    CFRelease(criteria);
    *notification = token->port(); token->releaseLater();
    return KERN_SUCCESS;
}
kern_return_t is_io_service_add_notification_bin_64(mach_port_t master, io_name_t type,
    io_struct_inband_t matching, mach_msg_type_number_t size, mach_port_t wake,
    io_async_ref64_t refs, mach_msg_type_number_t count, mach_port_t* notification)
{
    return subscribe(master,type,matching,size,wake,refs,count,notification);
}
kern_return_t is_io_service_add_notification_64(mach_port_t master, io_name_t type,
    io_string_t matching, mach_port_t wake, io_async_ref64_t refs,
    mach_msg_type_number_t count, mach_port_t* notification)
{
    auto size = strnlen(matching,sizeof(io_string_t));
    if (size == sizeof(io_string_t)) return kIOReturnBadArgument;
    return subscribe(master,type,matching,size+1,wake,refs,count,notification);
}
kern_return_t is_io_service_add_notification_ool_64(mach_port_t master, io_name_t type,
    io_buf_ptr_t matching, mach_msg_type_number_t size, mach_port_t wake,
    io_async_ref64_t refs, mach_msg_type_number_t count, kern_return_t* result, mach_port_t* notification)
{
    *result=subscribe(master,type,matching,size,wake,refs,count,notification);
    if (matching && size) vm_deallocate(mach_task_self(),(vm_address_t)matching,size);
    // The RPC transport succeeds even when the reported operation fails.
    if (*result != KERN_SUCCESS && MACH_PORT_VALID(wake)) mach_port_deallocate(mach_task_self(),wake);
    return KERN_SUCCESS;
}
