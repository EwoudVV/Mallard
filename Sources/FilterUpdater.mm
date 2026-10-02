#import "FilterUpdater.h"
#import <CommonCrypto/CommonDigest.h>
#include "Blocker.h"

static NSString *Digest(NSData *data) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,hash);
    NSMutableString *text=[NSMutableString string];for(unsigned char byte:hash)[text appendFormat:@"%02x",byte];return text;
}
@implementation MallardFilterUpdater
+ (void)check:(NSString *)filterDirectory dataDirectory:(NSString *)dataDirectory completion:(void (^)(BOOL))completion {
    NSString *checkedPath=[dataDirectory stringByAppendingPathComponent:@"filter-check.json"];
    NSDictionary *previous=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:checkedPath]?:[NSData data] options:0 error:nil];
    if([NSDate date].timeIntervalSince1970-[previous[@"timestamp"] doubleValue]<86400)return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSData *manifestData=[NSData dataWithContentsOfFile:[filterDirectory stringByAppendingPathComponent:@"manifest.json"]];
        NSDictionary *manifest=manifestData?[NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil]:nil;
        NSArray *sources=manifest[@"sources"];
        if(![sources isKindOfClass:NSArray.class] || sources.count<3 || sources.count>150)return;
        NSString *identifier=NSUUID.UUID.UUIDString;
        NSString *staging=[[dataDirectory stringByAppendingPathComponent:@"FilterRevisions"] stringByAppendingPathComponent:identifier];
        NSFileManager *fm=NSFileManager.defaultManager;
        if(![fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil])return;
        NSOperationQueue *queue=[NSOperationQueue new];queue.maxConcurrentOperationCount=4;
        NSObject *lock=[NSObject new];__block BOOL valid=YES,changed=NO;NSMutableArray *updatedSources=[NSMutableArray array];NSMutableArray *failures=[NSMutableArray array];
        for(NSDictionary *source in sources) [queue addOperationWithBlock:^{
            @synchronized(lock){if(!valid)return;}
            NSString *name=source[@"file"];NSURL *url=[NSURL URLWithString:source[@"url"]];
            NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."];
            if(![name isKindOfClass:NSString.class] || [name hasPrefix:@"."] || [name rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound || ![url.scheme isEqual:@"https"] || ![url.host isEqual:@"raw.githubusercontent.com"]) { @synchronized(lock){valid=NO;[failures addObject:@{@"file":[name isKindOfClass:NSString.class]?name:@"(invalid)",@"error":@"Invalid source entry"}];}return; }
            if([name.pathExtension isEqual:@"json"]) {
                BOOL copied=[fm copyItemAtPath:[filterDirectory stringByAppendingPathComponent:name] toPath:[staging stringByAppendingPathComponent:name] error:nil];
                @synchronized(lock){if(!copied)valid=NO;else [updatedSources addObject:source];}return;
            }
            dispatch_semaphore_t wait=dispatch_semaphore_create(0);
            __block NSData *bytes=nil;__block NSInteger status=0,networkError=0;
            NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];request.timeoutInterval=20;
            NSURLSessionDataTask *task=[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){bytes=data;networkError=error.code;status=[response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)response).statusCode:0;dispatch_semaphore_signal(wait);}];
            [task resume];
            if(dispatch_semaphore_wait(wait,dispatch_time(DISPATCH_TIME_NOW,25*NSEC_PER_SEC))!=0){[task cancel];@synchronized(lock){valid=NO;[failures addObject:@{@"file":name,@"error":@"timeout"}];}return;}
            NSString *text=bytes?[[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding]:nil;
            BOOL payload=status==200 && text && bytes.length<12000000 && ![[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] hasPrefix:@"<"];
            if([source[@"bytes"] integerValue]>100000 && bytes.length<10000)payload=NO;
            if([name.pathExtension isEqual:@"json"] && ![[NSJSONSerialization JSONObjectWithData:bytes?:[NSData data] options:0 error:nil] isKindOfClass:NSArray.class])payload=NO;
            if(!payload || ![bytes writeToFile:[staging stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil]){@synchronized(lock){valid=NO;[failures addObject:@{@"file":name,@"httpStatus":@(status),@"networkError":@(networkError)}];}return;}
            NSString *hash=Digest(bytes);
            @synchronized(lock){if(![hash isEqual:source[@"sha256"]])changed=YES;[updatedSources addObject:@{@"file":name,@"url":url.absoluteString,@"sha256":hash,@"bytes":@(bytes.length)}];}
        }];
        [queue waitUntilAllOperationsAreFinished];
        if(valid && changed)valid=mb_validate(staging.UTF8String);
        if(valid && changed) {
            NSDictionary *next=@{@"updated":[[NSISO8601DateFormatter new] stringFromDate:[NSDate date]],@"sources":updatedSources};
            NSData *data=[NSJSONSerialization dataWithJSONObject:next options:NSJSONWritingPrettyPrinted error:nil];
            valid=[data writeToFile:[staging stringByAppendingPathComponent:@"manifest.json"] options:NSDataWritingAtomic error:nil];
            if(valid) { NSData *pointer=[NSJSONSerialization dataWithJSONObject:@{@"revision":identifier} options:0 error:nil];valid=[pointer writeToFile:[dataDirectory stringByAppendingPathComponent:@"current-filters.json"] options:NSDataWritingAtomic error:nil]; }
        }
        if(valid){NSData *checked=[NSJSONSerialization dataWithJSONObject:@{@"timestamp":@([NSDate date].timeIntervalSince1970)} options:0 error:nil];[checked writeToFile:checkedPath options:NSDataWritingAtomic error:nil];}
        if(!valid || !changed)[fm removeItemAtPath:staging error:nil];
        NSDictionary *report=@{@"timestamp":@([NSDate date].timeIntervalSince1970),@"valid":@(valid),@"updateReady":@(valid&&changed),@"completedFiles":@(updatedSources.count),@"failures":failures};
        NSData *reportData=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        [reportData writeToFile:[dataDirectory stringByAppendingPathComponent:@"filter-update-status.json"] options:NSDataWritingAtomic error:nil];
        dispatch_async(dispatch_get_main_queue(),^{completion(valid && changed);});
    });
}
@end
