#import <Foundation/Foundation.h>
@interface MallardFilterUpdater : NSObject
+ (void)check:(NSString *)filterDirectory dataDirectory:(NSString *)dataDirectory completion:(void (^)(BOOL updated))completion;
@end
