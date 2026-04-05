#import "Settings.h"
#import "PayloadStorage.h"

static NSString *const NXBootRememberPayload = @"NXBootRememberPayload";
static NSString *const NXBootLastPayload = @"NXBootLastPayload";

@implementation Settings

+ (BOOL)rememberPayload {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:NXBootRememberPayload]) {
        return [defaults boolForKey:NXBootRememberPayload];
    } else {
        return YES;
    }
}

+ (void)setRememberPayload:(BOOL)rememberPayload {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:rememberPayload forKey:NXBootRememberPayload];
}

+ (nullable NSString *)lastPayloadFileName {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:NXBootLastPayload];
}

+ (void)setLastPayloadFileName:(nullable NSString *)lastPayloadFileName {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (lastPayloadFileName) {
        [defaults setObject:lastPayloadFileName forKey:NXBootLastPayload];
    } else {
        [defaults removeObjectForKey:NXBootLastPayload];
    }
}

@end
