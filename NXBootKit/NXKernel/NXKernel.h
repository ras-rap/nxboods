//
//  NXKernel.h
//  NXBootKit
//
//  Public API for iOS kernel read/write (Darksword exploit)
//

#ifndef NXKernel_h
#define NXKernel_h

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>

typedef enum {
    NXKernelStatusNotStarted = 0,
    NXKernelStatusRunning    = 1,
    NXKernelStatusReady      = 2,
    NXKernelStatusFailed     = 3,
} NXKernelStatus;

typedef void (*NXKernelLogCallback)(const char *message);
typedef void (*NXKernelProgressCallback)(double progress);

// Callbacks
void NXKernelSetLogCallback(NXKernelLogCallback callback);
void NXKernelSetProgressCallback(NXKernelProgressCallback callback);

// Lifecycle
NXKernelStatus NXKernelRun(void);
bool NXKernelIsReady(void);

// Kernel info
uint64_t NXKernelGetBase(void);
uint64_t NXKernelGetSlide(void);
uint64_t NXKernelGetProc(void);
uint64_t NXKernelGetTask(void);

// Kernel read
uint64_t NXKernelRead64(uint64_t address);
uint32_t NXKernelRead32(uint64_t address);
void     NXKernelRead(uint64_t address, void *buffer, uint64_t size);

// Kernel write
void NXKernelWrite64(uint64_t address, uint64_t value);
void NXKernelWrite32(uint64_t address, uint32_t value);
void NXKernelWrite(uint64_t address, void *buffer, uint64_t size);

// Offsets / kernelcache
bool NXKernelDownloadOffsets(void);
bool NXKernelHasOffsets(void);
void NXKernelClearOffsets(void);

// Utilities
void NXKernelInitOffsets(void);
uint64_t NXKernelProcByPID(pid_t pid);
uint64_t NXKernelProcByName(const char *name);

// Support check (implemented in Swift/ObjC)
bool NXKernelIsSupported(void);

#endif /* NXKernel_h */
