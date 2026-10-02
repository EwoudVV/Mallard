#import <Cocoa/Cocoa.h>
@interface MallardVault : NSObject
+ (NSArray<NSDictionary *> *)entriesForProfile:(NSString *)profile;
+ (BOOL)save:(NSDictionary *)record profile:(NSString *)profile error:(NSError **)error;
+ (void)read:(NSString *)identifier profile:(NSString *)profile completion:(void (^)(NSDictionary *, NSError *))completion;
@end
BOOL MallardVaultStorageTest(void);
BOOL MallardVaultAuthenticationTest(void);
