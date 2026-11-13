#import <Foundation/Foundation.h>
#import <Security/Security.h>

#ifndef PROBE_REVISION
#define PROBE_REVISION 1
#endif

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if(argc!=3)return 2;
        NSString *operation=[NSString stringWithUTF8String:argv[1]],*service=[NSString stringWithUTF8String:argv[2]];
        if(![service hasPrefix:@"com.ewoudvv.Mallard.signing-test."])return 2;
        NSMutableDictionary *query=[@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:service,(__bridge id)kSecAttrAccount:@"test",(__bridge id)kSecUseDataProtectionKeychain:@NO,(__bridge id)kSecUseAuthenticationUI:(__bridge id)kSecUseAuthenticationUIFail} mutableCopy];
        NSData *fake=[@"temporary-signing-check" dataUsingEncoding:NSUTF8StringEncoding];
        OSStatus status=errSecParam;
        if([operation isEqual:@"create"]){query[(__bridge id)kSecValueData]=fake;status=SecItemAdd((__bridge CFDictionaryRef)query,NULL);}
        else if([operation isEqual:@"read"]){
            query[(__bridge id)kSecReturnData]=@YES;CFTypeRef value=NULL;
            status=SecItemCopyMatching((__bridge CFDictionaryRef)query,&value);
            NSData *data=CFBridgingRelease(value);if(status==errSecSuccess && ![data isEqual:fake])status=errSecDecode;
        } else if([operation isEqual:@"delete"])status=SecItemDelete((__bridge CFDictionaryRef)query);
        printf("build %d %s: %d\n",PROBE_REVISION,operation.UTF8String,(int)status);
        return status==errSecSuccess?0:1;
    }
}
