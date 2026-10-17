/*
 This file is part of Darling.

 Copyright (C) 2020 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/

#include "iokitd.h"
#include "ServiceRegistry.h"
#include <IOKit/IOCFUnserialize.h>
#include <CoreFoundation/CFString.h>
#include <IOKit/IOReturn.h>
#include <os/log.h>
#include <stdexcept>
#include "IOIterator.h"
#include "IOMatchingNotification.h"
#include <algorithm>
#include <cstring>

extern "C" {
#include "iokitmigServer.h"
}

ServiceRegistry* ServiceRegistry::instance()
{
	static ServiceRegistry reg;
	return &reg;
}

std::vector<IOObject*> ServiceRegistry::matchingServices(NSDictionary* criteria) const
{
    std::vector<IOObject*> matching;
    for (auto* service : m_registeredServices)
        if (service->matches(criteria)) matching.push_back(service);
    return matching;
}
IOIterator* ServiceRegistry::iteratorForMatchingServices(NSDictionary* criteria) const
{
    return new IOIterator(matchingServices(criteria));
}
void ServiceRegistry::registerService(IOService* service)
{
    if (service->m_state & kIOServiceInactiveState) return;
    if (std::find(m_registeredServices.begin(), m_registeredServices.end(), service) == m_registeredServices.end()) {
        service->retain();
        m_registeredServices.push_back(service);
    }
    bool first = !service->m_everPublished;
    service->m_state |= kIOServiceRegisteredState | kIOServiceMatchedState;
    service->m_everPublished = true;
    if (first) service->m_state |= kIOServiceFirstPublishState | kIOServiceFirstMatchState;
    for (auto* notification : m_notifications) notification->serviceChanged(service, false, first);
}
void ServiceRegistry::unregisterService(IOService* service)
{
    auto found = std::find(m_registeredServices.begin(), m_registeredServices.end(), service);
    if (found == m_registeredServices.end()) return;
    service->m_state |= kIOServiceInactiveState;
    m_registeredServices.erase(found);
    for (auto* notification : m_notifications) notification->serviceChanged(service, true, false);
    service->release();
}
void ServiceRegistry::addNotification(IOMatchingNotification* notification)
{
    m_notifications.push_back(notification);
}
void ServiceRegistry::removeNotification(IOMatchingNotification* notification)
{
    m_notifications.remove(notification);
}

namespace {
NSDictionary* decodeMatching(const void* bytes, unsigned size) {
    if (!size || size > sizeof(io_struct_inband_t) * 1024) return nil;
    CFStringRef error = nullptr;
    CFTypeRef criteria = IOCFUnserializeWithSize((const char*)bytes,size,kCFAllocatorDefault,0,&error);
    if (error) CFRelease(error);
    if (!criteria) return nil;
    if (CFGetTypeID(criteria) != CFDictionaryGetTypeID()) { CFRelease(criteria); return nil; }
    return (NSDictionary*)criteria;
}
kern_return_t matchingServices(mach_port_t master, const void* bytes, unsigned size, mach_port_t* result, bool single) {
    *result = MACH_PORT_NULL;
    if (master != g_masterPort) return kIOReturnNotPrivileged;
    NSDictionary* criteria = decodeMatching(bytes,size);
    if (!criteria) return kIOReturnBadArgument;
    auto matches = ServiceRegistry::instance()->matchingServices(criteria);
    [criteria release];
    if (single) {
        if (!matches.empty()) *result = matches.front()->port();
        return KERN_SUCCESS;
    }
    auto* iterator = new IOIterator(matches);
    *result = iterator->port(); iterator->releaseLater();
    return KERN_SUCCESS;
}
kern_return_t matchProperty(mach_port_t service, const void* bytes, unsigned size, boolean_t* result) {
    *result = false;
    auto* object = dynamic_cast<IOService*>(IOObject::lookup(service));
    if (!object) return kIOReturnBadArgument;
    NSDictionary* criteria = decodeMatching(bytes,size);
    if (!criteria) return kIOReturnBadArgument;
    *result = object->matches(criteria);
    [criteria release];
    return KERN_SUCCESS;
}
unsigned xmlSize(const char* bytes) {
    auto size = strnlen(bytes,sizeof(io_string_t));
    return size == sizeof(io_string_t) ? 0 : size + 1;
}
}
kern_return_t is_io_service_get_matching_services_bin(mach_port_t master, io_struct_inband_t bytes,
    mach_msg_type_number_t size, mach_port_t* result) { return matchingServices(master,bytes,size,result,false); }
kern_return_t is_io_service_get_matching_service_bin(mach_port_t master, io_struct_inband_t bytes,
    mach_msg_type_number_t size, mach_port_t* result) { return matchingServices(master,bytes,size,result,true); }
kern_return_t is_io_service_get_matching_services(mach_port_t master, io_string_t bytes,
    mach_port_t* result) { return matchingServices(master,bytes,xmlSize(bytes),result,false); }
kern_return_t is_io_service_get_matching_service(mach_port_t master, io_string_t bytes,
    mach_port_t* result) { return matchingServices(master,bytes,xmlSize(bytes),result,true); }
kern_return_t is_io_service_get_matching_services_ool(mach_port_t master, io_buf_ptr_t bytes,
    mach_msg_type_number_t size, kern_return_t* status, mach_port_t* result) {
    *status=matchingServices(master,bytes,size,result,false);
    if (bytes && size) vm_deallocate(mach_task_self(),(vm_address_t)bytes,size);
    return KERN_SUCCESS;
}
kern_return_t is_io_service_get_matching_service_ool(mach_port_t master, io_buf_ptr_t bytes,
    mach_msg_type_number_t size, kern_return_t* status, mach_port_t* result) {
    *status=matchingServices(master,bytes,size,result,true);
    if (bytes && size) vm_deallocate(mach_task_self(),(vm_address_t)bytes,size);
    return KERN_SUCCESS;
}
kern_return_t is_io_service_match_property_table_bin(mach_port_t service, io_struct_inband_t bytes,
    mach_msg_type_number_t size, boolean_t* result) { return matchProperty(service,bytes,size,result); }
kern_return_t is_io_service_match_property_table(mach_port_t service, io_string_t bytes,
    boolean_t* result) { return matchProperty(service,bytes,xmlSize(bytes),result); }
kern_return_t is_io_service_match_property_table_ool(mach_port_t service, io_buf_ptr_t bytes,
    mach_msg_type_number_t size, kern_return_t* status, boolean_t* result) {
    *status=matchProperty(service,bytes,size,result);
    if (bytes && size) vm_deallocate(mach_task_self(),(vm_address_t)bytes,size);
    return KERN_SUCCESS;
}
