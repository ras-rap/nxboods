//
//  NXKernelSupport.m
//  NXBootKit
//
//  Device/iOS version support checker for kernel exploit compatibility
//

#import <Foundation/Foundation.h>
#include <sys/utsname.h>
#include <mach-o/dyld.h>

static NSString *nx_device_machine(void) {
    struct utsname sysinfo;
    uname(&sysinfo);
    return [NSString stringWithUTF8String:sysinfo.machine];
}

static bool nx_has_mie(void) {
    NSString *machine = nx_device_machine();
    return [machine containsString:@"iPhone18,"];
}

static bool nx_is_live_container_installed(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *imageName = [NSString stringWithUTF8String:name];
        if ([imageName containsString:@"tweakinjector.dylib"] ||
            [imageName containsString:@"tweakloader.dylib"]) {
            return true;
        }
    }
    return false;
}

bool nx_kernel_is_supported(void) {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];

    if (v.majorVersion < 17) {
        return false;
    }

    if (v.majorVersion > 26) {
        return false;
    }

    if (v.majorVersion == 26) {
        if (v.minorVersion > 0) return false;
        if (v.minorVersion == 0 && v.patchVersion > 1) return false;
    }

    if (nx_has_mie()) {
        return false;
    }

    if (nx_is_live_container_installed()) {
        return false;
    }

    return true;
}
