//
//  NXKernel.m
//  NXBootKit
//
//  Wrapper that bridges NXKernel public API to Darksword internals
//

#import "NXKernel.h"
#import "darksword.h"
#import "utils.h"
#import "offsets.h"
#import "sbx.h"

static NXKernelLogCallback g_nx_log_callback = NULL;
static NXKernelProgressCallback g_nx_progress_callback = NULL;

static void nx_internal_log(const char *message) {
    if (g_nx_log_callback) {
        g_nx_log_callback(message);
    }
}

static void nx_internal_progress(double progress) {
    if (g_nx_progress_callback) {
        g_nx_progress_callback(progress);
    }
}

void NXKernelSetLogCallback(NXKernelLogCallback callback) {
    g_nx_log_callback = callback;
    ds_set_log_callback(callback ? (ds_log_callback_t)callback : NULL);
    sbx_setlogcallback(callback ? (void (*)(const char *))callback : NULL);
}

void NXKernelSetProgressCallback(NXKernelProgressCallback callback) {
    g_nx_progress_callback = callback;
    ds_set_progress_callback(callback ? (ds_progress_callback_t)callback : NULL);
}

NXKernelStatus NXKernelRun(void) {
    int result = ds_run();
    return (result == 0 && ds_is_ready()) ? NXKernelStatusReady : NXKernelStatusFailed;
}

bool NXKernelIsReady(void) {
    return ds_is_ready();
}

uint64_t NXKernelGetBase(void) {
    return ds_get_kernel_base();
}

uint64_t NXKernelGetSlide(void) {
    return ds_get_kernel_slide();
}

uint64_t NXKernelGetProc(void) {
    return ds_get_our_proc();
}

uint64_t NXKernelGetTask(void) {
    return ds_get_our_task();
}

uint64_t NXKernelRead64(uint64_t address) {
    return ds_kread64(address);
}

uint32_t NXKernelRead32(uint64_t address) {
    return ds_kread32(address);
}

void NXKernelRead(uint64_t address, void *buffer, uint64_t size) {
    ds_kread(address, buffer, size);
}

void NXKernelWrite64(uint64_t address, uint64_t value) {
    ds_kwrite64(address, value);
}

void NXKernelWrite32(uint64_t address, uint32_t value) {
    ds_kwrite32(address, value);
}

void NXKernelWrite(uint64_t address, void *buffer, uint64_t size) {
    ds_kwrite(address, buffer, size);
}

bool NXKernelDownloadOffsets(void) {
    return dlkerncache();
}

bool NXKernelHasOffsets(void) {
    return haskernproc();
}

void NXKernelClearOffsets(void) {
    clearkerncachedata();
}

void NXKernelInitOffsets(void) {
    init_offsets();
}

uint64_t NXKernelProcByPID(pid_t pid) {
    return procbypid(pid);
}

uint64_t NXKernelProcByName(const char *name) {
    return procbyname(name);
}

int NXKernelSandboxEscape(void) {
    int patchResult = patchcsflags();

    uint64_t selfProc = ds_get_our_proc();
    if (!selfProc) {
        selfProc = ourproc();
    }

    int sbxResult = sbx_escape(selfProc);
    if (patchResult == 0 || sbxResult == 0) {
        return 0;
    }

    return patchResult;
}

bool NXKernelIsSupported(void) {
    // Implemented in NXKernelSupport.m
    extern bool nx_kernel_is_supported(void);
    return nx_kernel_is_supported();
}
