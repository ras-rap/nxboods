#import "NXUSBDeviceEnumerator.h"
#import "NXBootKit.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOMessage.h>
#import <IOKit/usb/IOUSBLib.h>
#import <mach/mach.h>
#import <TargetConditionals.h>
#import <dlfcn.h>

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

static void *NXIOKitFrameworkHandle(void) {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_GLOBAL);
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
        uuidPtr = (const CFUUIDRef *)dlsym(RTLD_DEFAULT, symbolName);
    }
    if (!uuidPtr) {
        return NULL;
    }
    return *uuidPtr;
}

static kern_return_t NXCreatePluginForServiceWithFallback(io_service_t service,
                                                          const CFUUIDRef preferredUserClient,
                                                          const CFUUIDRef fallbackUserClient,
                                                          IOCFPlugInInterface ***plugInInterface,
                                                          SInt32 *plugInScore,
                                                          NSString *logPrefix)
{
    kern_return_t kr = IOCreatePlugInInterfaceForService(service,
                                                         preferredUserClient,
                                                         kIOCFPlugInInterfaceID,
                                                         plugInInterface,
                                                         plugInScore);

    if ((kr || !*plugInInterface) && preferredUserClient != fallbackUserClient) {
        NXLog(@"%@: preferred user client plugin failed (%08x), retrying fallback", logPrefix, kr);
        kr = IOCreatePlugInInterfaceForService(service,
                                               fallbackUserClient,
                                               kIOCFPlugInInterfaceID,
                                               plugInInterface,
                                               plugInScore);
    }

    return kr;
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

    NXLog(@"USB: OK, listening for devices matching VID:%04x PID:%04x", self.VID, self.PID);

    dispatch_async(dispatch_get_main_queue(), ^{
        [self handleDevicesAdded:self->_deviceIter];
        if (self->_legacyDeviceIter) {
            [self handleDevicesAdded:self->_legacyDeviceIter];
        }
        NXLog(@"USB: Done processing initial device list");
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

    NXLog(@"USB: Processing new devices");

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
        NXLog(@"USB: Device added: 0x%08x `%@'", service, device.name);

        // load the device interface implementation bundle
        IOCFPlugInInterface **plugInInterface = NULL;
        SInt32 plugInScore = -1;
        io_name_t ioClassName;
        ioClassName[0] = '\0';
        (void)IOObjectGetClass(service, ioClassName);

        BOOL classIsHostDevice = (strcmp(ioClassName, "IOUSBHostDevice") == 0);
        CFUUIDRef hostUserClientTypeID = NXLookupHostUUIDSymbol("kIOUSBHostDeviceUserClientTypeID");
        CFUUIDRef hostInterfaceID = NXLookupHostUUIDSymbol("kIOUSBHostDeviceInterfaceID");
        NXLog(@"USB: class=%s hostUserClient=%s hostInterface=%s",
              ioClassName,
              hostUserClientTypeID ? "yes" : "no",
              hostInterfaceID ? "yes" : "no");
        const CFUUIDRef preferredUserClient = (classIsHostDevice && hostUserClientTypeID)
            ? hostUserClientTypeID
            : kIOUSBDeviceUserClientTypeID;

        if (classIsHostDevice && !hostUserClientTypeID) {
            NXLog(@"USB: host device client UUID unavailable, legacy fallback may be unsupported");
        }

        kr = NXCreatePluginForServiceWithFallback(service,
                                                  preferredUserClient,
                                                  kIOUSBDeviceUserClientTypeID,
                                                  &plugInInterface,
                                                  &plugInScore,
                                                  @"USB: current service");

        // On newer iOS stacks, the usable user client may be exposed on a related registry node.
        if (kr || !plugInInterface) {
            io_registry_entry_t parent = IO_OBJECT_NULL;
            if (IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS) {
                kr = NXCreatePluginForServiceWithFallback(parent,
                                                          preferredUserClient,
                                                          kIOUSBDeviceUserClientTypeID,
                                                          &plugInInterface,
                                                          &plugInScore,
                                                          @"USB: parent service");
                IOObjectRelease(parent);
            }
        }

        if (kr || !plugInInterface) {
            ERR(@"Could not create USB device plugin instance (%08x) class=%s score=%d", kr, ioClassName, (int)plugInScore);
            goto cleanup;
        }

        kr = (*plugInInterface)->QueryInterface(plugInInterface,
                                                CFUUIDGetUUIDBytes(kNXUSBDeviceInterfaceUUID),
                                                (void *)&device->_intf);

        if ((kr || !device->_intf) && classIsHostDevice && hostInterfaceID) {
            NXLog(@"USB: legacy device interface query failed (%08x), retrying host interface UUID", kr);
            kr = (*plugInInterface)->QueryInterface(plugInInterface,
                                                    CFUUIDGetUUIDBytes(hostInterfaceID),
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
        NXLog(@"USB: Device location ID: 0x%lx\n", (unsigned long)device->_locationID);

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
            NXLog(@"USB: Device 0x%08x removed", service);
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
