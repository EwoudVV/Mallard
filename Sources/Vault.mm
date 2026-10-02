#import "Vault.h"
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>

@implementation MallardVault
+ (NSString *)service:(NSString *)profile { return [@"com.ewoudvv.Mallard.vault." stringByAppendingString:profile]; }
+ (void)setError:(NSError **)error status:(OSStatus)status {
    if(error) *error=[NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey:(__bridge_transfer NSString *)SecCopyErrorMessageString(status,NULL) ?: @"Keychain operation failed."}];
}
+ (NSArray<NSDictionary *> *)entriesForProfile:(NSString *)profile {
    NSDictionary *query=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:[self service:profile],(__bridge id)kSecReturnAttributes:@YES,(__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitAll};
    CFTypeRef result=NULL;
    OSStatus status=SecItemCopyMatching((__bridge CFDictionaryRef)query,&result);
    if(status!=errSecSuccess) return @[];
    NSArray *attributes=(__bridge_transfer NSArray *)result;
    NSMutableArray *entries=[NSMutableArray array];
    for(NSDictionary *a in attributes) {
        NSData *data=[a[(__bridge id)kSecAttrComment] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *metadata=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        if(metadata) { NSMutableDictionary *entry=[metadata mutableCopy]; entry[@"id"]=a[(__bridge id)kSecAttrAccount]; [entries addObject:entry]; }
    }
    return entries;
}
+ (BOOL)save:(NSDictionary *)record profile:(NSString *)profile error:(NSError **)error {
    NSString *kind=record[@"kind"];
    NSDictionary *metadata=[kind isEqual:@"password"] ? @{@"kind":kind,@"origin":record[@"origin"]?:@"",@"username":record[@"username"]?:@""} : @{@"kind":@"card",@"nickname":record[@"nickname"]?:@"Card",@"last4":[record[@"number"] substringFromIndex:MAX((NSInteger)[record[@"number"] length]-4,0)]};
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:error];
    if(!data) return NO;
    NSData *meta=[NSJSONSerialization dataWithJSONObject:metadata options:0 error:error];
    SecAccessRef access=NULL;
    OSStatus accessStatus=SecAccessCreate(CFSTR("Mallard autofill"),NULL,&access);
    if(accessStatus!=errSecSuccess) { [self setError:error status:accessStatus];return NO; }
    NSDictionary *query=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:[self service:profile],(__bridge id)kSecAttrAccount:NSUUID.UUID.UUIDString,(__bridge id)kSecAttrLabel:@"Mallard autofill",(__bridge id)kSecAttrComment:[[NSString alloc] initWithData:meta encoding:NSUTF8StringEncoding],(__bridge id)kSecAttrAccess:(__bridge id)access,(__bridge id)kSecUseDataProtectionKeychain:@NO,(__bridge id)kSecValueData:data};
    OSStatus status=SecItemAdd((__bridge CFDictionaryRef)query,NULL);
    CFRelease(access);
    if(status!=errSecSuccess) [self setError:error status:status];
    return status==errSecSuccess;
}
+ (void)read:(NSString *)identifier profile:(NSString *)profile completion:(void (^)(NSDictionary *, NSError *))completion {
    LAContext *authentication=[LAContext new];
    [authentication evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:@"Unlock a saved password or card for Mallard autofill." reply:^(BOOL success,NSError *authenticationError) {
        if(!success) { dispatch_async(dispatch_get_main_queue(),^{completion(nil,authenticationError);});return; }
        NSDictionary *query=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:[self service:profile],(__bridge id)kSecAttrAccount:identifier,(__bridge id)kSecUseDataProtectionKeychain:@NO,(__bridge id)kSecReturnData:@YES,(__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitOne};
        CFTypeRef result=NULL; NSError *error=nil;
        OSStatus status=SecItemCopyMatching((__bridge CFDictionaryRef)query,&result);
        NSDictionary *record=nil;
        if(status!=errSecSuccess) [self setError:&error status:status];
        else { NSData *data=CFBridgingRelease(result);record=[NSJSONSerialization JSONObjectWithData:data options:0 error:&error]; }
        dispatch_async(dispatch_get_main_queue(),^{completion(record,error);});
    }];
}
@end

BOOL MallardVaultStorageTest(void) {
    NSString *profile=[@"test-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSDictionary *fake=@{@"kind":@"password",@"origin":@"https://example.invalid",@"username":@"synthetic-test",@"password":@"not-a-real-account-4931"};
    NSError *error=nil;
    if(![MallardVault save:fake profile:profile error:&error]) { fprintf(stderr,"Keychain protected write failed: %ld\n",(long)error.code);return NO; }
    BOOL visible=[MallardVault entriesForProfile:profile].count==1;
    BOOL isolated=[MallardVault entriesForProfile:[profile stringByAppendingString:@"-other"]].count==0;
    NSDictionary *query=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:[@"com.ewoudvv.Mallard.vault." stringByAppendingString:profile]};
    OSStatus cleanup=SecItemDelete((__bridge CFDictionaryRef)query);
    printf("Encrypted Keychain write: %s; profile metadata isolation: %s; test cleanup: %s\n",visible?"passed":"FAILED",isolated?"passed":"FAILED",cleanup==errSecSuccess?"passed":"FAILED");
    return visible && isolated && cleanup==errSecSuccess;
}

BOOL MallardVaultAuthenticationTest(void) {
    NSString *profile=[@"auth-test-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSDictionary *fake=@{@"kind":@"password",@"origin":@"https://example.invalid",@"username":@"synthetic-test",@"password":@"not-a-real-account-4931"};
    NSError *error=nil;
    if(![MallardVault save:fake profile:profile error:&error]) { fprintf(stderr,"Synthetic Keychain write failed: %ld\n",(long)error.code);return NO; }
    NSString *identifier=[MallardVault entriesForProfile:profile].firstObject[@"id"];
    __block BOOL finished=NO,passed=NO;
    [MallardVault read:identifier profile:profile completion:^(NSDictionary *record,NSError *readError){
        passed=[record[@"password"] isEqual:fake[@"password"]] && !readError;finished=YES;
    }];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:120];
    while(!finished && deadline.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    NSDictionary *query=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:[@"com.ewoudvv.Mallard.vault." stringByAppendingString:profile]};
    OSStatus cleanup=SecItemDelete((__bridge CFDictionaryRef)query);
    printf("macOS authentication and synthetic secret retrieval: %s; cleanup: %s\n",passed?"passed":"not completed",cleanup==errSecSuccess?"passed":"FAILED");
    return passed && cleanup==errSecSuccess;
}
