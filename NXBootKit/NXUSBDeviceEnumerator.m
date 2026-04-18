#import "NXUSBDeviceEnumerator.h"
#import "NXBootKit.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOMessage.h>
#import <IOKit/usb/IOUSBLib.h>
#import <mach/mach.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#include <stdarg.h>

#ifndef NXBOOTMAC_BUILDING
// use kIOMasterPortDefault for NXBoot iOS and command line builds for compatibility
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wavailability"
extern const mach_port_t kIOMasterPortDefault __API_AVAILABLE(ios(1.0));
#pragma clang diagnostic pop
#define kIOMainPortDefault kIOMasterPortDefault
#endif

#define ERR(FMT, ...) [self handleError:[NSString stringWithFormat:FMT, ##__VA_ARGS__]]

@interface NXUSBDeviceEnumerator () {
    io_iterator_t _deviceIter;
    io_iterator_t _legacyDeviceIter;
}
@property (assign, nonatomic) UInt16 VID;
@property (assign, nonatomic) UInt16 PID;
@property (assign, nonatomic) IONotificationPortRef notifyPort;
- (void)handleDevicesAdded:(io_iterator_t)iterator;
- (void)handleDeviceNotification:(NXUSBDevice *)device
                      forService:(io_service_t)service
                     messageType:(natural_t)messageType
                      messageArg:(void *)messageArg;
@end

static void bridgeDevicesAdded(void *u, io_iterator_t iterator) {
    NXUSBDeviceEnumerator *deviceEnum = (__bridge NXUSBDeviceEnumerator *)u;
    [deviceEnum handleDevicesAdded:iterator];
}

static void bridgeDeviceNotification(void *u, io_service_t service, natural_t messageType, void *messageArg) {
    NXUSBDevice *device = (__bridge NXUSBDevice *)u;
    NXUSBDeviceEnumerator *deviceEnum = device.parentEnum;
    [deviceEnum handleDeviceNotification:device forService:service messageType:messageType messageArg:messageArg];
}

static void NXUSBLogf(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void NXUSBLogf(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    if (!msg) return;
    NXLog(@"%@", msg);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NXKernelLog"
                                                        object:nil
                                                      userInfo:@{ @"message": msg }];
}

static NSString *NXDescribeIOReturn(kern_return_t kr) {
    switch (kr) {
        case KERN_SUCCESS: return @"kIOReturnSuccess";
        case 0xe00002be: return @"kIOReturnNoResources";
        case 0xe00002c1: return @"kIOReturnNotPrivileged";
        case 0xe00002c7: return @"kIOReturnUnsupported";
        case 0xe00002e2: return @"kIOReturnNotPermitted";
        default: return [NSString stringWithFormat:@"0x%08x", kr];
    }
}

static void *NXIOKitFrameworkHandle(void) {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_GLOBAL);
    });
    return handle;
}

static void *NXIOUSBHostFrameworkHandle(void) {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/IOUSBHost.framework/IOUSBHost", RTLD_LAZY | RTLD_GLOBAL);
    });
    return handle;
}

static CFUUIDRef NXLookupHostUUIDSymbol(const char *symbolName) {
    const CFUUIDRef *uuidPtr = NULL;

    void *handle = NXIOKitFrameworkHandle();
    if (handle) {
        uuidPtr = (const CFUUIDRef *)dlsym(handle, symbolName);
    }
    if (!uuidPtr) {
        handle = NXIOUSBHostFrameworkHandle();
        if (handle) {
            uuidPtr = (const CFUUIDRef *)dlsym(handle, symbolName);
        }
    }
    if (!uuidPtr) {
        uuidPtr = (const CFUUIDRef *)dlsym(RTLD_DEFAULT, symbolName);
    }
    if (!uuidPtr) {
        return NULL;
    }
    return *uuidPtr;
}

static CFUUIDRef NXLookupHostUUIDSymbolAny(const char * const *symbolNames, size_t symbolCount, NSString *logPrefix) {
    for (size_t i = 0; i < symbolCount; i++) {
        CFUUIDRef uuid = NXLookupHostUUIDSymbol(symbolNames[i]);
        if (uuid) {
            NXUSBLogf(@"%@: resolved %s", logPrefix, symbolNames[i]);
            return uuid;
        }
    }

    NXUSBLogf(@"%@: no matching host UUID symbol found", logPrefix);
    return NULL;
}

static CFUUIDRef NXLookupLegacyUUIDSymbolAny(const char * const *symbolNames, size_t symbolCount, NSString *logPrefix) {
    for (size_t i = 0; i < symbolCount; i++) {
        CFUUIDRef uuid = NXLookupHostUUIDSymbol(symbolNames[i]);
        if (uuid) {
            NXUSBLogf(@"%@: resolved %s", logPrefix, symbolNames[i]);
            return uuid;
        }
    }

    NXUSBLogf(@"%@: no matching legacy UUID symbol found", logPrefix);
    return NULL;
}

static CFUUIDRef NXCopyRegistryPluginTypeUUID(io_registry_entry_t service, NSString *logPrefix) {
    if (!service) {
        return NULL;
    }

    CFTypeRef pluginTypes = IORegistryEntryCreateCFProperty(service,
                                                            CFSTR("IOCFPlugInTypes"),
                                                            kCFAllocatorDefault,
                                                            0);
    if (!pluginTypes) {
        NXUSBLogf(@"%@: IOCFPlugInTypes missing", logPrefix);
        return NULL;
    }

    if (CFGetTypeID(pluginTypes) != CFDictionaryGetTypeID()) {
        NXUSBLogf(@"%@: IOCFPlugInTypes has unexpected type", logPrefix);
        CFRelease(pluginTypes);
        return NULL;
    }

    CFDictionaryRef dict = (CFDictionaryRef)pluginTypes;
    CFIndex count = CFDictionaryGetCount(dict);
    if (count <= 0) {
        NXUSBLogf(@"%@: IOCFPlugInTypes empty", logPrefix);
        CFRelease(pluginTypes);
        return NULL;
    }

    const void **keys = calloc((size_t)count, sizeof(void *));
    if (!keys) {
        NXUSBLogf(@"%@: IOCFPlugInTypes allocation failed", logPrefix);
        CFRelease(pluginTypes);
        return NULL;
    }

    CFDictionaryGetKeysAndValues(dict, keys, NULL);
    CFUUIDRef selectedUUID = NULL;
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef key = keys[i];
        if (!key) {
            continue;
        }

        if (CFGetTypeID(key) == CFUUIDGetTypeID()) {
            selectedUUID = (CFUUIDRef)key;
            CFRetain(selectedUUID);
            break;
        }

        if (CFGetTypeID(key) == CFStringGetTypeID()) {
            selectedUUID = CFUUIDCreateFromString(kCFAllocatorDefault, (CFStringRef)key);
            if (selectedUUID) {
                break;
            }
        }
    }

    free(keys);
    CFRelease(pluginTypes);

    if (!selectedUUID) {
        NXUSBLogf(@"%@: IOCFPlugInTypes had no UUID keys", logPrefix);
        return NULL;
    }

    CFStringRef uuidStr = CFUUIDCreateString(kCFAllocatorDefault, selectedUUID);
    if (uuidStr) {
        NXUSBLogf(@"%@: using IOCFPlugInTypes UUID %@", logPrefix, (__bridge NSString *)uuidStr);
        CFRelease(uuidStr);
    }

    return selectedUUID;
}

static kern_return_t NXCreatePluginForServiceWithFallback(io_service_t service,
                                                          const CFUUIDRef preferredUserClient,
                                                          const CFUUIDRef fallbackUserClient,
                                                          IOCFPlugInInterface ***plugInInterface,
                                                          SInt32 *plugInScore,
                                                          NSString *logPrefix)
{
    *plugInInterface = NULL;
    *plugInScore = -1;

    NXUSBLogf(@"%@: creating plugin with preferred user client", logPrefix);
    kern_return_t kr = IOCreatePlugInInterfaceForService(service,
                                                         preferredUserClient,
                                                         kIOCFPlugInInterfaceID,
                                                         plugInInterface,
                                                         plugInScore);

    if ((kr || !*plugInInterface) && preferredUserClient != fallbackUserClient) {
        NXUSBLogf(@"%@: preferred user client plugin failed (%08x, %@), retrying fallback", logPrefix, kr, NXDescribeIOReturn(kr));
        *plugInInterface = NULL;
        *plugInScore = -1;
        kr = IOCreatePlugInInterfaceForService(service,
                                               fallbackUserClient,
                                               kIOCFPlugInInterfaceID,
                                               plugInInterface,
                                               plugInScore);
    }

    if (kr || !*plugInInterface) {
        NXUSBLogf(@"%@: plugin creation failed (%08x, %@) score=%d", logPrefix, kr, NXDescribeIOReturn(kr), (int)*plugInScore);
    } else {
        NXUSBLogf(@"%@: plugin creation succeeded score=%d", logPrefix, (int)*plugInScore);
    }

    return kr;
}

// Returns KERN_SUCCESS and sets *outConn/*outOpenType to the first successful open type.
// The caller is responsible for closing *outConn via IOServiceClose when done.
// If no open type succeeds, *outConn is IO_OBJECT_NULL and the last error is returned.
static kern_return_t NXTryServiceOpenAccess(io_service_t service,
                                             NSString *logPrefix,
                                             uint32_t *outOpenType,
                                             io_connect_t *outConn)
{
    *outOpenType = 0;
    *outConn = IO_OBJECT_NULL;

    if (!service) {
        return kIOReturnBadArgument;
    }

    const uint32_t openTypes[] = { 0, 1, 2, 3, 4, 5, 0x100, 0x200 };
    kern_return_t lastKr = kIOReturnError;
    bool anySuccess = false;

    for (size_t i = 0; i < sizeof(openTypes) / sizeof(openTypes[0]); i++) {
        io_connect_t conn = IO_OBJECT_NULL;
        kern_return_t openKr = IOServiceOpen(service, mach_task_self(), openTypes[i], &conn);
        NXUSBLogf(@"%@: IOServiceOpen(type=0x%x) -> 0x%08x (%@)",
              logPrefix,
              openTypes[i],
              openKr,
              NXDescribeIOReturn(openKr));
        if (openKr == KERN_SUCCESS && conn) {
            if (!anySuccess) {
                *outOpenType = openTypes[i];
                *outConn = conn;
                anySuccess = true;
            } else {
                IOServiceClose(conn);
            }
        } else {
            // Prefer kIOReturnNotPermitted over other errors: it means the service exists and
            // responded (access denied) rather than the type being unsupported entirely. This
            // surfaces the most actionable error code in the final diagnostic message.
            if (lastKr != (kern_return_t)kIOReturnNotPermitted) {
                lastKr = openKr;
            }
        }
    }

    if (!anySuccess) {
        NXUSBLogf(@"%@: all IOServiceOpen probes failed", logPrefix);
        return lastKr;
    }

    return KERN_SUCCESS;
}

@implementation NXUSBDeviceEnumerator

- (void)dealloc {
    [self stop];
}

- (void)setFilterForVendorID:(UInt16)vendorID productID:(UInt16)productID {
    self.VID = vendorID;
    self.PID = productID;
}

- (void)start {
    kern_return_t kr;
    NSMutableDictionary *matchingDict = nil;
    NSMutableDictionary *legacyMatchingDict = nil;

    // clean up previous run before starting a new one
    [self stop];

    // Note we're searching for IOUSBHostDevice kernel objects, which only works on macOS 10.11+ and iOS 9+.
    // macOS has backwards-compatibility for IOUSBDevice, but iOS does not.
    matchingDict = (__bridge_transfer NSMutableDictionary *)IOServiceMatching("IOUSBHostDevice");
    if (!matchingDict) {
        ERR(@"Could not create service matching dict");
        return;
    }
    [matchingDict setValue:@(self.VID) forKey:@(kUSBVendorID)];
    [matchingDict setValue:@(self.PID) forKey:@(kUSBProductID)];

    self.notifyPort = IONotificationPortCreate(kIOMainPortDefault);
    if (!self.notifyPort) {
        ERR(@"Could not create notification port");
        return;
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       IONotificationPortGetRunLoopSource(self.notifyPort),
                       kCFRunLoopDefaultMode);

    kr = IOServiceAddMatchingNotification(self.notifyPort,
                                          kIOFirstMatchNotification,
                                          (__bridge_retained CFDictionaryRef)matchingDict,
                                          bridgeDevicesAdded,
                                          (__bridge void *)self,
                                          &_deviceIter);
    if (kr) {
        ERR(@"Could not add matching service notification (%08x)", kr);
        return;
    }

    // Some firmware stacks still expose IOUSBDevice, so monitor both classes.
    legacyMatchingDict = (__bridge_transfer NSMutableDictionary *)IOServiceMatching("IOUSBDevice");
    if (legacyMatchingDict) {
        [legacyMatchingDict setValue:@(self.VID) forKey:@(kUSBVendorID)];
        [legacyMatchingDict setValue:@(self.PID) forKey:@(kUSBProductID)];

        kr = IOServiceAddMatchingNotification(self.notifyPort,
                                              kIOFirstMatchNotification,
                                              (__bridge_retained CFDictionaryRef)legacyMatchingDict,
                                              bridgeDevicesAdded,
                                              (__bridge void *)self,
                                              &_legacyDeviceIter);
        if (kr) {
            NXLog(@"USB: Legacy IOUSBDevice match registration failed (%08x)", kr);
        }
    }

    NXUSBLogf(@"USB: OK, listening for devices matching VID:%04x PID:%04x", self.VID, self.PID);

    dispatch_async(dispatch_get_main_queue(), ^{
        [self handleDevicesAdded:self->_deviceIter];
        if (self->_legacyDeviceIter) {
            [self handleDevicesAdded:self->_legacyDeviceIter];
        }
        NXUSBLogf(@"USB: Done processing initial device list");
    });
}

- (void)stop {
    if (self.notifyPort) {
        IONotificationPortDestroy(self.notifyPort);
    }
    if (_deviceIter) {
        IOObjectRelease(_deviceIter);
        _deviceIter = 0;
    }
    if (_legacyDeviceIter) {
        IOObjectRelease(_legacyDeviceIter);
        _legacyDeviceIter = 0;
    }
}

#pragma mark - IOKit Notifications

- (void)handleDevicesAdded:(io_iterator_t)iterator {
    kern_return_t kr;
    io_service_t service;

    NXUSBLogf(@"USB: Processing new devices");

    while ((service = IOIteratorNext(iterator))) {
        NXUSBDevice *device = [[NXUSBDevice alloc] init];
        device.parentEnum = self;

        // retrieve service name as device name
        io_name_t ioDeviceName;
        kr = IORegistryEntryGetName(service, ioDeviceName);
        if (kr) {
            ioDeviceName[0] = '\0';
        }
        device.name = [NSString stringWithCString:ioDeviceName encoding:NSASCIIStringEncoding];
        NXUSBLogf(@"USB: Device added: 0x%08x `%@'", service, device.name);

        // load the device interface implementation bundle
        IOCFPlugInInterface **plugInInterface = NULL;
        SInt32 plugInScore = -1;
        io_name_t ioClassName;
        ioClassName[0] = '\0';
        (void)IOObjectGetClass(service, ioClassName);

        BOOL classIsHostDevice = (strcmp(ioClassName, "IOUSBHostDevice") == 0);
        static const char * const hostUserClientNames[] = {
            "kIOUSBHostDeviceUserClientTypeID",
            "kIOUSBHostDeviceUserClientTypeID245",
            "kIOUSBHostDeviceUserClientTypeID300",
            "kIOUSBHostDeviceUserClientTypeID500",
            "kIOUSBHostDeviceUserClientTypeID550",
        };
        static const char * const hostInterfaceNames[] = {
            "kIOUSBHostDeviceInterfaceID",
            "kIOUSBHostDeviceInterfaceID245",
            "kIOUSBHostDeviceInterfaceID300",
            "kIOUSBHostDeviceInterfaceID500",
            "kIOUSBHostDeviceInterfaceID550",
        };
        static const char * const legacyUserClientNames[] = {
            "kIOUSBDeviceUserClientTypeID",
            "kIOUSBDeviceUserClientTypeID245",
            "kIOUSBDeviceUserClientTypeID300",
            "kIOUSBDeviceUserClientTypeID500",
            "kIOUSBDeviceUserClientTypeID550",
        };
        static const char * const legacyInterfaceNames[] = {
            "kIOUSBDeviceInterfaceID",
            "kIOUSBDeviceInterfaceID245",
            "kIOUSBDeviceInterfaceID300",
            "kIOUSBDeviceInterfaceID500",
            "kIOUSBDeviceInterfaceID550",
        };
        CFUUIDRef hostUserClientTypeID = NXLookupHostUUIDSymbolAny(hostUserClientNames,
                                                                   sizeof(hostUserClientNames) / sizeof(hostUserClientNames[0]),
                                                                   @"USB: host user-client UUID");
        CFUUIDRef hostInterfaceID = NXLookupHostUUIDSymbolAny(hostInterfaceNames,
                                                              sizeof(hostInterfaceNames) / sizeof(hostInterfaceNames[0]),
                                                              @"USB: host interface UUID");
        CFUUIDRef legacyUserClientTypeID = NXLookupLegacyUUIDSymbolAny(legacyUserClientNames,
                                                                        sizeof(legacyUserClientNames) / sizeof(legacyUserClientNames[0]),
                                                                        @"USB: legacy user-client UUID");
        CFUUIDRef legacyInterfaceID = NXLookupLegacyUUIDSymbolAny(legacyInterfaceNames,
                                                                   sizeof(legacyInterfaceNames) / sizeof(legacyInterfaceNames[0]),
                                                                   @"USB: legacy interface UUID");
        NXUSBLogf(@"USB: class=%s hostUserClient=%s hostInterface=%s legacyUserClient=%s legacyInterface=%s",
                  ioClassName,
                  hostUserClientTypeID ? "yes" : "no",
                  hostInterfaceID ? "yes" : "no",
                  legacyUserClientTypeID ? "yes" : "no",
                  legacyInterfaceID ? "yes" : "no");
        const CFUUIDRef preferredUserClient = (classIsHostDevice && hostUserClientTypeID)
            ? hostUserClientTypeID
            : (legacyUserClientTypeID ?: kIOUSBDeviceUserClientTypeID);
        CFUUIDRef registryUserClientTypeID = NXCopyRegistryPluginTypeUUID(service,
                                                                          @"USB: current service plugin type");

        if (classIsHostDevice && !hostUserClientTypeID) {
            NXUSBLogf(@"USB: host device client UUID unavailable, legacy fallback may be unsupported");
        }

        kr = NXCreatePluginForServiceWithFallback(service,
                                                  preferredUserClient,
                                                  kIOUSBDeviceUserClientTypeID,
                                                  &plugInInterface,
                                                  &plugInScore,
                                                  @"USB: current service");

        if ((kr || !plugInInterface) && registryUserClientTypeID &&
            !CFEqual(registryUserClientTypeID, preferredUserClient)) {
            kr = NXCreatePluginForServiceWithFallback(service,
                                                      registryUserClientTypeID,
                                                      preferredUserClient,
                                                      &plugInInterface,
                                                      &plugInScore,
                                                      @"USB: current service (registry UUID)");
        }

        // IOServiceOpen fallback: populated during ancestor walk when plugin creation fails.
        io_connect_t fallbackConn = IO_OBJECT_NULL;
        uint32_t fallbackOpenType = 0;
        kern_return_t fallbackConnKr = kIOReturnError;

        // On newer iOS stacks, the usable user client may be exposed on ancestor registry nodes.
        if (kr || !plugInInterface) {
            // Try direct IOServiceOpen on the current service first.
            {
                io_connect_t probeConn = IO_OBJECT_NULL;
                uint32_t probeType = 0;
                kern_return_t probeKr = NXTryServiceOpenAccess(service, @"USB: current service access probe", &probeType, &probeConn);
                if (probeKr == KERN_SUCCESS && probeConn) {
                    fallbackConn = probeConn;
                    fallbackOpenType = probeType;
                    fallbackConnKr = KERN_SUCCESS;
                } else {
                    fallbackConnKr = probeKr;
                }
            }

            io_registry_entry_t ancestor = service;
            IOObjectRetain(ancestor);
            for (int depth = 1; depth <= 4 && (kr || !plugInInterface); depth++) {
                io_registry_entry_t next = IO_OBJECT_NULL;
                if (IORegistryEntryGetParentEntry(ancestor, kIOServicePlane, &next) != KERN_SUCCESS || !next) {
                    break;
                }

                IOObjectRelease(ancestor);
                ancestor = next;

                NSString *prefix = [NSString stringWithFormat:@"USB: ancestor[%d] service", depth];
                NSString *registryPrefix = [NSString stringWithFormat:@"USB: ancestor[%d] service plugin type", depth];
                NSString *openPrefix = [NSString stringWithFormat:@"USB: ancestor[%d] access probe", depth];

                {
                    io_connect_t probeConn = IO_OBJECT_NULL;
                    uint32_t probeType = 0;
                    kern_return_t probeKr = NXTryServiceOpenAccess(ancestor, openPrefix, &probeType, &probeConn);
                    // Keep the first successful connection found (current service takes priority over ancestors).
                    if (probeKr == KERN_SUCCESS && probeConn && !fallbackConn) {
                        fallbackConn = probeConn;
                        fallbackOpenType = probeType;
                        fallbackConnKr = KERN_SUCCESS;
                    } else if (probeConn) {
                        IOServiceClose(probeConn);
                    } else if (fallbackConnKr != KERN_SUCCESS &&
                               fallbackConnKr != (kern_return_t)kIOReturnNotPermitted) {
                        fallbackConnKr = probeKr;
                    }
                }

                CFUUIDRef ancestorRegistryUserClientTypeID = NXCopyRegistryPluginTypeUUID(ancestor, registryPrefix);
                kr = NXCreatePluginForServiceWithFallback(ancestor,
                                                          preferredUserClient,
                                                          kIOUSBDeviceUserClientTypeID,
                                                          &plugInInterface,
                                                          &plugInScore,
                                                          prefix);

                if ((kr || !plugInInterface) && ancestorRegistryUserClientTypeID &&
                    !CFEqual(ancestorRegistryUserClientTypeID, preferredUserClient)) {
                    NSString *registryAttemptPrefix = [NSString stringWithFormat:@"USB: ancestor[%d] service (registry UUID)", depth];
                    kr = NXCreatePluginForServiceWithFallback(ancestor,
                                                              ancestorRegistryUserClientTypeID,
                                                              preferredUserClient,
                                                              &plugInInterface,
                                                              &plugInScore,
                                                              registryAttemptPrefix);
                }

                if (ancestorRegistryUserClientTypeID) {
                    CFRelease(ancestorRegistryUserClientTypeID);
                }
            }
            IOObjectRelease(ancestor);
        }

        if (registryUserClientTypeID) {
            CFRelease(registryUserClientTypeID);
        }

        BOOL usingFallbackPath = NO;
        if (kr || !plugInInterface) {
            if (fallbackConn) {
                // Plugin creation failed on all paths, but IOServiceOpen succeeded.
                // Proceed with the direct connection; USB pipe operations will not be available.
                NXUSBLogf(@"USB: Plugin creation failed (%08x, %@) class=%s score=%d; "
                          @"using IOServiceOpen fallback connection (type=0x%x)",
                          kr, NXDescribeIOReturn(kr), ioClassName, (int)plugInScore, fallbackOpenType);
                device->_conn = fallbackConn;
                device->_connOpenType = fallbackOpenType;
                fallbackConn = IO_OBJECT_NULL;
                usingFallbackPath = YES;
            } else {
                ERR(@"Could not create USB device plugin instance (%08x, %@) class=%s score=%d; "
                    @"IOServiceOpen fallback also failed (%08x, %@). "
                    @"Check device entitlements and IOKit USB stack.",
                    kr, NXDescribeIOReturn(kr), ioClassName, (int)plugInScore,
                    fallbackConnKr, NXDescribeIOReturn(fallbackConnKr));
                goto cleanup;
            }
        } else if (fallbackConn) {
            // Plugin succeeded; discard the fallback connection that was accumulated during probing.
            IOServiceClose(fallbackConn);
            fallbackConn = IO_OBJECT_NULL;
        }

        if (!usingFallbackPath) {
            kr = (*plugInInterface)->QueryInterface(plugInInterface,
                                                    CFUUIDGetUUIDBytes(kNXUSBDeviceInterfaceUUID),
                                                    (void *)&device->_intf);

            if ((kr || !device->_intf) && classIsHostDevice && hostInterfaceID) {
                NXUSBLogf(@"USB: legacy device interface query failed (%08x), retrying host interface UUID", kr);
                kr = (*plugInInterface)->QueryInterface(plugInInterface,
                                                        CFUUIDGetUUIDBytes(hostInterfaceID),
                                                        (void *)&device->_intf);
            }

            if ((kr || !device->_intf) && legacyInterfaceID) {
                NXUSBLogf(@"USB: host/compile-time interface query failed (%08x), retrying legacy interface UUID", kr);
                kr = (*plugInInterface)->QueryInterface(plugInInterface,
                                                        CFUUIDGetUUIDBytes(legacyInterfaceID),
                                                        (void *)&device->_intf);
            }

            NXCOMCall(plugInInterface, Release);
            plugInInterface = NULL;
            if (kr || !device->_intf) {
                ERR(@"Could not get USB device interface (%08x)", kr);
                goto cleanup;
            }

            // fetch location ID
            kr = NXCOMCall(device->_intf, GetLocationID, &device->_locationID);
            if (kr != KERN_SUCCESS) {
                ERR(@"GetLocationID failed with code %08x, skipping device\n", kr);
                goto cleanup;
            }
            NXUSBLogf(@"USB: Device location ID: 0x%lx", (unsigned long)device->_locationID);
        }

        // register for device events
        kr = IOServiceAddInterestNotification(self.notifyPort,
                                              service,
                                              kIOGeneralInterest,
                                              bridgeDeviceNotification,
                                              (__bridge_retained void *)device,
                                              &device->_notification);
        if (kr != KERN_SUCCESS) {
            ERR(@"IOServiceAddInterestNotification failed with code 0x%08x", kr);
            goto cleanup;
        }

        // notify delegate
        [self.delegate usbDeviceEnumerator:self deviceConnected:device];

    cleanup:
        kr = IOObjectRelease(service);
        if (kr != KERN_SUCCESS) {
            ERR(@"IOObjectRelease for device failed with code 0x%08x", kr);
            goto cleanup;
        }
    }
}

- (void)handleDeviceNotification:(NXUSBDevice *)device
                      forService:(io_service_t)service
                     messageType:(natural_t)messageType
                      messageArg:(void *)messageArgument
{
    NXLog(@"USB: Device 0x%08x received message 0x%x", service, messageType);

    switch (messageType) {
        case kIOMessageServiceIsTerminated: {
            NXUSBLogf(@"USB: Device 0x%08x removed", service);
            [device invalidate];
            [self.delegate usbDeviceEnumerator:self deviceDisconnected:device];
            device = (__bridge_transfer NXUSBDevice *)(__bridge void *)device;
            break;
        }
    }
}

- (void)handleError:(NSString *)err {
    NXLog(@"ERR: %@", err);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NXKernelLog"
                                                        object:nil
                                                      userInfo:@{ @"message": [NSString stringWithFormat:@"USB: %@", err] }];
    [self.delegate usbDeviceEnumerator:self deviceError:err];
}

@end

#undef ERR
