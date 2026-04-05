//
//  sbx.h
//  lara
//
//  Created by ruter on 05.04.26.
//

#ifndef sbx_h
#define sbx_h

#include <stdint.h>

int sbx_escape(uint64_t self_proc);
void sbx_setlogcallback(void (*callback)(const char *message));
void gettoken(void);

#endif /* sbx_h */
