#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Settings : NSObject

@property (nonatomic, class, assign) BOOL rememberPayload;
@property (nonatomic, class, strong, nullable) NSString *lastPayloadFileName;

@end

NS_ASSUME_NONNULL_END
