#import "Favicons.h"
#import "Core.h"
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#include <sqlite3.h>

NSNotificationName const MallardFaviconChanged=@"MallardFaviconChanged";
static const NSUInteger MaxIconBytes=1024*1024;

NSString *MallardFaviconPage(NSString *url) {
    if(![url isKindOfClass:NSString.class] || !MallardOrigin(url))return nil;
    NSURLComponents *parts=[NSURLComponents componentsWithString:url];
    if(parts.user || parts.password)return nil;
    parts.scheme=parts.scheme.lowercaseString;parts.host=parts.host.lowercaseString;parts.fragment=nil;
    if(!parts.path.length)parts.path=@"/";
    return parts.URL.absoluteString;
}
BOOL MallardFaviconURLAllowed(NSString *url) {
    return url.length<=MaxIconBytes && ([url.lowercaseString hasPrefix:@"data:image/"] || MallardFaviconPage(url)!=nil);
}
static NSString *IconKey(NSString *page,NSString *profile) {
    NSData *data=[[NSString stringWithFormat:@"%@\n%@",profile,page] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *key=[NSMutableString string];for(unsigned char byte:digest)[key appendFormat:@"%02x",byte];return key;
}
NSImage *MallardSiteSymbol(BOOL folder) {
    static NSImage *site,*directory;static dispatch_once_t once;
    dispatch_once(&once,^{
        NSImageSymbolConfiguration *tint=[NSImageSymbolConfiguration configurationWithPaletteColors:@[[NSColor colorWithWhite:.57 alpha:1]]];
        site=[[NSImage imageWithSystemSymbolName:@"globe" accessibilityDescription:nil] imageWithSymbolConfiguration:tint];
        directory=[[NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:nil] imageWithSymbolConfiguration:tint];
    });return folder?directory:site;
}
static NSData *IconPNG(NSData *data) {
    if(!data.length || data.length>MaxIconBytes)return nil;
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL);if(!source)return nil;
    size_t chosen=SIZE_MAX;double distance=DBL_MAX;
    for(size_t i=0;i<MIN(CGImageSourceGetCount(source),16);i++) {
        NSDictionary *info=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,i,NULL));
        double width=[info[(id)kCGImagePropertyPixelWidth] doubleValue],height=[info[(id)kCGImagePropertyPixelHeight] doubleValue];
        if(width<=0 || height<=0 || width>4096 || height>4096)continue;
        double score=fabs(width-32);if(score<distance){distance=score;chosen=i;}
    }
    if(chosen==SIZE_MAX){CFRelease(source);return nil;}
    NSDictionary *options=@{(id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(id)kCGImageSourceThumbnailMaxPixelSize:@32,(id)kCGImageSourceCreateThumbnailWithTransform:@YES};
    CGImageRef image=CGImageSourceCreateThumbnailAtIndex(source,chosen,(__bridge CFDictionaryRef)options);CFRelease(source);if(!image)return nil;
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();CGContextRef context=CGBitmapContextCreate(NULL,32,32,8,0,space,kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(space);
    if(!context){CGImageRelease(image);return nil;}
    double scale=MIN(32.0/CGImageGetWidth(image),32.0/CGImageGetHeight(image));double w=CGImageGetWidth(image)*scale,h=CGImageGetHeight(image)*scale;
    CGContextDrawImage(context,CGRectMake((32-w)/2,(32-h)/2,w,h),image);CGImageRelease(image);
    CGImageRef square=CGBitmapContextCreateImage(context);CGContextRelease(context);if(!square)return nil;
    NSMutableData *png=[NSMutableData data];CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png,CFSTR("public.png"),1,NULL);
    if(destination){CGImageDestinationAddImage(destination,square,NULL);if(!CGImageDestinationFinalize(destination))png=nil;CFRelease(destination);}else png=nil;
    CGImageRelease(square);return png;
}

@interface MallardIconFetch : NSObject <NSURLSessionDataDelegate,NSURLSessionTaskDelegate>
- (NSData *)fetch:(NSURL *)url;
@end
@implementation MallardIconFetch {
    NSMutableData *bytes;
    dispatch_semaphore_t finished;
    BOOL valid;
}
- (NSData *)fetch:(NSURL *)url {
    bytes=[NSMutableData data];finished=dispatch_semaphore_create(0);valid=YES;
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPCookieStorage=nil;config.URLCredentialStorage=nil;config.HTTPShouldSetCookies=NO;config.URLCache=nil;
    config.timeoutIntervalForRequest=6;config.timeoutIntervalForResource=8;
    NSURLSession *session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    [[session dataTaskWithURL:url] resume];
    BOOL done=dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,9*NSEC_PER_SEC))==0;
    [session invalidateAndCancel];return done && valid?[bytes copy]:nil;
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)response).statusCode:0;
    valid=status>=200 && status<300 && response.expectedContentLength<=(int64_t)MaxIconBytes;
    completion(valid?NSURLSessionResponseAllow:NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if(bytes.length+data.length>MaxIconBytes){valid=NO;[task cancel];return;}[bytes appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error { if(error)valid=NO;dispatch_semaphore_signal(finished); }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    BOOL allowed=MallardFaviconPage(request.URL.absoluteString)!=nil && !([response.URL.scheme isEqual:@"https"] && ![request.URL.scheme isEqual:@"https"]);
    completion(allowed?request:nil);
}
@end

static void BookmarkIconPages(NSArray *nodes,NSString *source,NSMutableDictionary *pages) {
    for(NSDictionary *node in nodes) {
        NSString *next=node[@"chromeSource"]?:source;
        if(node[@"children"])BookmarkIconPages(node[@"children"],next,pages);
        else {NSString *page=MallardFaviconPage(node[@"url"]);if(page && next.length)pages[page]=next;}
    }
}
static NSDictionary *ChromeIcons(NSDictionary *pages) {
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    NSString *chrome=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Google/Chrome"];
    for(NSString *profile in [NSSet setWithArray:pages.allValues]) {
        if(![profile.lastPathComponent isEqual:profile] || [profile hasPrefix:@"."])continue;
        NSString *source=[[chrome stringByAppendingPathComponent:profile] stringByAppendingPathComponent:@"Favicons"];
        if([[NSFileManager.defaultManager attributesOfItemAtPath:source error:nil][NSFileSize] unsignedLongLongValue]>128*1024*1024)continue;
        NSString *temporary=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"Mallard-favicons-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtPath:temporary withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
        NSString *copy=[temporary stringByAppendingPathComponent:@"Favicons"];sqlite3 *db=NULL;
        @try {
            // Chrome holds an exclusive SQLite lock. Recover/read only our private copy.
            if(![NSFileManager.defaultManager copyItemAtPath:source toPath:copy error:nil])continue;
            for(NSString *suffix in @[@"-wal",@"-journal"])if([NSFileManager.defaultManager fileExistsAtPath:[source stringByAppendingString:suffix]])[NSFileManager.defaultManager copyItemAtPath:[source stringByAppendingString:suffix] toPath:[copy stringByAppendingString:suffix] error:nil];
            if(sqlite3_open_v2(copy.fileSystemRepresentation,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_NOMUTEX,NULL)!=SQLITE_OK)continue;
            sqlite3_stmt *query=NULL;
            const char *sql="SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id=m.icon_id WHERE (m.page_url=?1 OR substr(m.page_url,1,length(?2))=?2) AND length(b.image_data)>0 AND length(b.image_data)<=1048576 ORDER BY (m.page_url=?1) DESC, abs(b.width-32) LIMIT 1";
            if(sqlite3_prepare_v2(db,sql,-1,&query,NULL)!=SQLITE_OK)continue;
            for(NSString *page in pages)if([pages[page] isEqual:profile]) {
                NSString *origin=[MallardOrigin(page) stringByAppendingString:@"/"];
                sqlite3_bind_text(query,1,page.UTF8String,-1,SQLITE_TRANSIENT);sqlite3_bind_text(query,2,origin.UTF8String,-1,SQLITE_TRANSIENT);
                if(sqlite3_step(query)==SQLITE_ROW){NSData *png=IconPNG([NSData dataWithBytes:sqlite3_column_blob(query,0) length:sqlite3_column_bytes(query,0)]);if(png)result[page]=png;}
                sqlite3_reset(query);sqlite3_clear_bindings(query);
            }
            sqlite3_finalize(query);
        } @finally { if(db)sqlite3_close(db);[NSFileManager.defaultManager removeItemAtPath:temporary error:nil]; }
    }
    return result;
}

@implementation MallardFavicons {
    NSString *directory;
    NSCache<NSString *,NSImage *> *images;
    NSMutableDictionary<NSString *,NSArray *> *pending;
    NSMutableSet *priming,*activeLoads;
    NSMutableDictionary<NSString *,NSDate *> *misses;
    NSOperationQueue *loads,*writes;
}
- (instancetype)initWithDirectory:(NSString *)path {
    if((self=[super init])) {
        directory=[path stringByAppendingPathComponent:@"Favicons"];[NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
        images=[NSCache new];images.countLimit=512;pending=[NSMutableDictionary dictionary];priming=[NSMutableSet set];activeLoads=[NSMutableSet set];misses=[NSMutableDictionary dictionary];
        loads=[NSOperationQueue new];loads.maxConcurrentOperationCount=3;loads.qualityOfService=NSQualityOfServiceUtility;
        writes=[NSOperationQueue new];writes.maxConcurrentOperationCount=1;writes.qualityOfService=NSQualityOfServiceUtility;
    }return self;
}
- (NSString *)file:(NSString *)key extension:(NSString *)extension { return [directory stringByAppendingPathComponent:[key stringByAppendingPathExtension:extension]]; }
- (NSData *)freshData:(NSString *)key {
    NSString *file=[self file:key extension:@"png"];NSDate *date=[NSFileManager.defaultManager attributesOfItemAtPath:file error:nil][NSFileModificationDate];
    return date && -date.timeIntervalSinceNow<30*86400?[NSData dataWithContentsOfFile:file]:nil;
}
- (void)commit:(NSData *)png page:(NSString *)page profile:(NSString *)profile persist:(BOOL)persist {
    NSString *key=IconKey(page,profile);NSImage *image=[[NSImage alloc] initWithData:png];if(!image)return;image.size=NSMakeSize(16,16);[image setTemplate:NO];
    [images setObject:image forKey:key];[misses removeObjectForKey:key];[pending removeObjectForKey:key];
    if(persist){NSString *file=[self file:key extension:@"png"],*miss=[self file:key extension:@"miss"];[writes addOperationWithBlock:^{[png writeToFile:file options:NSDataWritingAtomic error:nil];[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:file error:nil];[NSFileManager.defaultManager removeItemAtPath:miss error:nil];}];}
    [NSNotificationCenter.defaultCenter postNotificationName:MallardFaviconChanged object:self userInfo:@{@"page":page,@"profile":profile}];
}
- (void)loadPage:(NSString *)page profile:(NSString *)profile {
    NSString *key=IconKey(page,profile);if([activeLoads containsObject:key])return;[activeLoads addObject:key];__weak MallardFavicons *weak=self;
    [loads addOperationWithBlock:^{@autoreleasepool {
        MallardFavicons *owner=weak;if(!owner)return;
        NSData *png=IconPNG([owner freshData:key]);BOOL fresh=png!=nil;
        NSDate *failed=[NSFileManager.defaultManager attributesOfItemAtPath:[owner file:key extension:@"miss"] error:nil][NSFileModificationDate];
        BOOL attempted=!png && (!failed || -failed.timeIntervalSinceNow>3600);
        if(attempted) {
            NSURL *url=[NSURL URLWithString:[MallardOrigin(page) stringByAppendingString:@"/favicon.ico"]];
            png=IconPNG([[MallardIconFetch new] fetch:url]);
        }
        dispatch_async(dispatch_get_main_queue(),^{
            [owner->activeLoads removeObject:key];
            if([owner->images objectForKey:key]){[owner->pending removeObjectForKey:key];return;}
            [owner->pending removeObjectForKey:key];
            if(png)[owner commit:png page:page profile:profile persist:!fresh];
            else {owner->misses[key]=[(attempted?NSDate.date:failed?:NSDate.date) dateByAddingTimeInterval:3600];if(attempted){NSString *file=[owner file:key extension:@"miss"];[owner->writes addOperationWithBlock:^{[NSData.data writeToFile:file options:NSDataWritingAtomic error:nil];}];}}
        });
    }}];
}
- (NSImage *)imageForPage:(NSString *)url profile:(NSString *)profile {
    NSString *page=MallardFaviconPage(url);if(!page)return nil;NSString *key=IconKey(page,profile);NSImage *image=[images objectForKey:key];
    if(misses[key] && misses[key].timeIntervalSinceNow<=0)[misses removeObjectForKey:key];
    if(!image && !pending[key] && !misses[key]){pending[key]=@[page,profile];if(![priming containsObject:profile])[self loadPage:page profile:profile];}
    return image;
}
- (void)storePNG:(NSData *)data page:(NSString *)url profile:(NSString *)profile {
    NSString *page=MallardFaviconPage(url);NSData *png=IconPNG(data);if(page && png)[self commit:png page:page profile:profile persist:YES];
}
- (void)primeBookmarks:(NSArray *)items profile:(NSString *)profile {
    NSMutableDictionary *pages=[NSMutableDictionary dictionary];BookmarkIconPages(items,nil,pages);if(!pages.count)return;
    [priming addObject:profile];__weak MallardFavicons *weak=self;
    [loads addOperationWithBlock:^{@autoreleasepool {
        MallardFavicons *owner=weak;if(!owner)return;NSMutableDictionary *ready=[NSMutableDictionary dictionary],*missing=[pages mutableCopy];
        for(NSString *page in pages){NSData *png=IconPNG([owner freshData:IconKey(page,profile)]);if(png){ready[page]=png;[missing removeObjectForKey:page];}}
        [ready addEntriesFromDictionary:ChromeIcons(missing)];
        dispatch_async(dispatch_get_main_queue(),^{
            for(NSString *page in ready)if(![owner->images objectForKey:IconKey(page,profile)])[owner commit:ready[page] page:page profile:profile persist:YES];
            [owner->priming removeObject:profile];
            for(NSArray *request in owner->pending.allValues)if([request[1] isEqual:profile])[owner loadPage:request[0] profile:profile];
        });
    }}];
}
@end

BOOL MallardFaviconTests(void) {
    BOOL ok=[MallardFaviconPage(@"https://example.com/a?b=1#part") isEqual:@"https://example.com/a?b=1"];
    ok=ok && !MallardFaviconPage(@"file:///etc/passwd") && !MallardFaviconPage(@"https://user:secret@example.com/");
    ok=ok && ![IconKey(@"https://example.com/",@"personal") isEqual:IconKey(@"https://example.com/",@"school")];
    ok=ok && MallardFaviconURLAllowed(@"data:image/png;base64,AA==") && !MallardFaviconURLAllowed(@"javascript:alert(1)");
    ok=ok && !IconPNG([@"<html>Not an icon</html>" dataUsingEncoding:NSUTF8StringEncoding]);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();CGContextRef canvas=CGBitmapContextCreate(NULL,8,4,8,0,space,kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(space);
    CGContextSetRGBFillColor(canvas,.2,.7,.3,1);CGContextFillRect(canvas,CGRectMake(0,0,8,4));CGImageRef source=CGBitmapContextCreateImage(canvas);CGContextRelease(canvas);
    NSMutableData *raw=[NSMutableData data];CGImageDestinationRef writer=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)raw,CFSTR("public.png"),1,NULL);CGImageDestinationAddImage(writer,source,NULL);CGImageDestinationFinalize(writer);CFRelease(writer);CGImageRelease(source);
    NSData *png=IconPNG(raw);CGImageSourceRef decoded=png?CGImageSourceCreateWithData((__bridge CFDataRef)png,NULL):NULL;
    NSDictionary *properties=decoded?CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(decoded,0,NULL)):nil;
    ok=ok && [properties[(id)kCGImagePropertyPixelWidth] intValue]==32 && [properties[(id)kCGImagePropertyPixelHeight] intValue]==32;if(decoded)CFRelease(decoded);
    fprintf(stderr,"Favicon checks: %s\n",ok?"passed":"failed");return ok;
}
