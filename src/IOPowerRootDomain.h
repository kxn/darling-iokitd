#ifndef IOKITD_IOPOWERROOTDOMAIN_H
#define IOKITD_IOPOWERROOTDOMAIN_H
#include "IOService.h"
#include "ServiceRegistry.h"

class IOPowerRootDomain : public IOService {
public:
    static void registerSelf(ServiceRegistry* registry);
    const char* className() const override { return "IOPMrootDomain"; }
    NSDictionary* matchingDictionary() override;
    NSDictionary* getProperties() override;
};
#endif
