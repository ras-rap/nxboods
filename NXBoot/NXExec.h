#import <Foundation/Foundation.h>

@class NXUSBDevice;

#ifdef __cplusplus
extern "C" {
#endif

BOOL NXExec(NXUSBDevice *device,
            NSData *relocator,
            NSData *payload,
            NSString * _Nullable * _Nullable error);

#ifdef __cplusplus
}
#endif
