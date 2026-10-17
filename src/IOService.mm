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

#include "IOService.h"
#import <Foundation/NSArray.h>
#import <Foundation/NSString.h>
#import <Foundation/NSNumber.h>

extern "C" {
#include "iokitmigServer.h"
}

IOService::IOService()
{

}

static bool propertySubset(NSDictionary* actual, id expected)
{
    if ([expected isKindOfClass:[NSArray class]]) {
        for (id choice in expected) if (propertySubset(actual, choice)) return true;
        return false;
    }
    if (![expected isKindOfClass:[NSDictionary class]]) return false;
    for (id key in expected)
        if (![expected[key] isEqual:actual[key]]) return false;
    return true;
}
bool IOService::matches(NSDictionary* dict)
{
    NSDictionary* matching = matchingDictionary();
    NSDictionary* properties = getProperties();
    for (NSString* key in dict) {
        ::id value = dict[key];
        if ([key isEqualToString:@"IOProviderClass"] || [key isEqualToString:@"IOClass"]) {
            bool found = false;
            NSArray* classes = [value isKindOfClass:[NSArray class]] ? value : @[value];
            for (::id name in classes)
                if ([name isKindOfClass:[NSString class]] && conformsTo([name UTF8String])) found = true;
            if (!found) return false;
        } else if ([key isEqualToString:@"IONameMatch"]) {
            NSString* name = [NSString stringWithUTF8String:getName(kIOServicePlane).c_str()];
            if ([value isKindOfClass:[NSArray class]]) { if (![value containsObject:name]) return false; }
            else if (![value isEqual:name]) return false;
        } else if ([key isEqualToString:@"IORegistryEntryID"]) {
            if (![value isKindOfClass:[NSNumber class]] || [value unsignedLongLongValue] != id()) return false;
        } else if ([key isEqualToString:@"IOPropertyMatch"]) {
            if (!propertySubset(properties,value)) return false;
        } else {
            ::id actual = matching[key] ?: properties[key];
            if (!actual || ![value isEqual:actual]) return false;
        }
    }
    return true;
}

bool IOService::conformsTo(const char* className)
{
	if (strcmp(className, "IOService") == 0)
		return true;
	return strcmp(className, "IORegistryEntry") == 0 || IOObject::conformsTo(className);
}

kern_return_t is_io_service_get_state
(
	mach_port_t service,
	uint64_t *state,
	uint32_t *busy_state,
	uint64_t *accumulated_busy_time
)
{
    IOService* e = dynamic_cast<IOService*>(IOObject::lookup(service));
	if (!e)
		return kIOReturnBadArgument;

	*state = e->state();
	*busy_state = e->busyState();
	*accumulated_busy_time = e->accumulatedBusyTime();

    return kIOReturnSuccess;
}
