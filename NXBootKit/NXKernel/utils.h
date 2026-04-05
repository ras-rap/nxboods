//
//  utils.h
//  lara
//
//  Created by ruter on 25.03.26.
//

#ifndef utils_h
#define utils_h

#include <stdint.h>
#include <unistd.h>
#include <sys/types.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void init_offsets(void);
uint64_t getprocsize(void);
uint64_t ourproc(void);
uint64_t taskbyproc(uint64_t procaddr);
uint64_t procbypid(pid_t targetpid);
uint64_t procbyname(const char *procname);

extern bool aslrstate;
void getaslrstate(void);
int toggleaslr(void);

int killproc(const char* name);
int patchcsflags(void);

#ifdef __cplusplus
}
#endif

#endif /* utils_h */
