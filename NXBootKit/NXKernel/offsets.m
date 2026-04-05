//
//  kernelcache_offsets.m
//  lara
//
//  Created by ruter on 04.04.26.
//  shoutout: appinstallerios
//

#import <Foundation/Foundation.h>
#import <xpc/xpc.h>

#import "xpf.h"
#import "libgrabkernel2.h"

static NSString *const kkernprockey   = @"lara.kernprocoff";
static NSString *const krootvnodekey  = @"lara.rootvnodeoff";
static NSString *const kkerncachekey  = @"lara.kernelcache_path";
static NSString *const kkernprocsize  = @"lara.kernproc_size";
static NSString *const kcsflagsoffkey = @"lara.csflags_offset";
static NSString *const kucredoffkey   = @"lara.ucred_offset";

static NSString *kerncachepath(void) {
    NSString *docs =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                            NSUserDomainMask,
                                            YES).firstObject;

    return [docs stringByAppendingPathComponent:@"kernelcache"];
}

static bool resolvekernoffsets(NSString *kcpath) {
    if (xpf_start_with_kernel_path(kcpath.UTF8String) != 0) {
        printf("xpf start error: %s\n", xpf_get_error());
        return false;
    }
    
    const char *sets[] = { "base", "translation", "struct", NULL };
    xpc_object_t dict = xpf_construct_offset_dictionary(sets);

    if (!dict) {
        printf("xpf dict failed, continuing without offsets: %s\n", xpf_get_error());
    }

    printf("kernel: %s\n", gXPF.kernelVersionString);
    printf("kernbase: 0x%llx\n", gXPF.kernelBase);
    printf("kernentry: 0x%llx\n", gXPF.kernelEntry);

    uint64_t kernproc = xpf_item_resolve("kernelSymbol.kernproc");
    if (!kernproc) kernproc = xpf_item_resolve("kernproc");

    uint64_t rootvnode = xpf_item_resolve("kernelSymbol.rootvnode");
    uint64_t procsize  = xpf_item_resolve("kernelStruct.proc.struct_size");

    // Resolve p_ucred and p_csflags offsets by scanning the proc struct definition
    uint64_t ucred_off  = xpf_item_resolve("kernelStruct.proc.p_ucred");
    uint64_t csflags_off = xpf_item_resolve("kernelStruct.proc.p_csflags");

    if (!kernproc || !rootvnode) {
        printf("failed to resolve important kernel symbols\n");
        xpf_stop();
        return false;
    }

    if (kernproc < gXPF.kernelBase || rootvnode < gXPF.kernelBase) {
        printf("invalid kernel symbol addresses\n");
        xpf_stop();
        return false;
    }

    uint64_t kernprocoff = kernproc - gXPF.kernelBase;
    uint64_t rootvnodeoff = rootvnode - gXPF.kernelBase;

    printf("kernproc: 0x%llx\n", kernprocoff);
    printf("rootvnode: 0x%llx\n", rootvnodeoff);
    printf("procsize: 0x%llx\n", procsize);
    printf("ucred_off: 0x%llx\n", ucred_off);
    printf("csflags_off: 0x%llx\n", csflags_off);

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    [defaults setObject:@(kernprocoff) forKey:kkernprockey];
    [defaults setObject:@(rootvnodeoff) forKey:krootvnodekey];
    [defaults setObject:@(procsize) forKey:kkernprocsize];
    [defaults setObject:kcpath forKey:kkerncachekey];
    if (ucred_off)  [defaults setObject:@(ucred_off) forKey:kucredoffkey];
    if (csflags_off) [defaults setObject:@(csflags_off) forKey:kcsflagsoffkey];

    [defaults synchronize];

    xpf_stop();

    return true;
}

bool dlkerncache(void) {
    NSString *outPath = kerncachepath();

    if (!outPath) {
        printf("documents path failure\n");
        return false;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:outPath]) {
        printf("downloading kernelcache → %s\n", outPath.UTF8String);

        if (!grab_kernelcache(outPath)) {
            printf("kernelcache download failed\n");
            return false;
        }
    } else {
        printf("using cached kernelcache\n");
    }

    return resolvekernoffsets(outPath);
}

uint64_t getkernproc(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kkernprockey];
    return n ? n.unsignedLongLongValue : 0;
}

uint64_t getrootvnode(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:krootvnodekey];
    return n ? n.unsignedLongLongValue : 0;
}

uint64_t getprocsize(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kkernprocsize];
    return n ? n.unsignedLongLongValue : 0;
}

bool haskernproc(void) {
    return getkernproc() != 0;
}

NSString *getkerncache(void) {
    return [[NSUserDefaults standardUserDefaults] objectForKey:kkerncachekey];
}

void clearkerncachedata(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *path = [defaults objectForKey:kkerncachekey];

    if (path.length) {
        NSError *err = nil;
        [[NSFileManager defaultManager] removeItemAtPath:path error:&err];
        if (err) {
            printf("delete failed: %s\n", err.localizedDescription.UTF8String);
        } else {
            printf("kernelcache removed\n");
        }
    }

    [defaults removeObjectForKey:kkerncachekey];
    [defaults removeObjectForKey:kkernprockey];
    [defaults removeObjectForKey:krootvnodekey];
    [defaults removeObjectForKey:kkernprocsize];
    [defaults removeObjectForKey:kcsflagsoffkey];
    [defaults removeObjectForKey:kucredoffkey];
    [defaults synchronize];
}

uint64_t getcsflagsoffset(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kcsflagsoffkey];
    return n ? n.unsignedLongLongValue : 0;
}

uint64_t getucredooffset(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kucredoffkey];
    return n ? n.unsignedLongLongValue : 0;
}
