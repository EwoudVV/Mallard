#import <Cocoa/Cocoa.h>

extern NSNotificationName const MallardFaviconChanged;
NSString *MallardFaviconPage(NSString *url);
BOOL MallardFaviconURLAllowed(NSString *url);
NSImage *MallardSiteSymbol(BOOL folder);
BOOL MallardFaviconTests(void);

@interface MallardFavicons : NSObject
- (instancetype)initWithDirectory:(NSString *)directory;
- (void)primeBookmarks:(NSArray *)items profile:(NSString *)profile;
- (NSImage *)imageForPage:(NSString *)page profile:(NSString *)profile;
- (void)storePNG:(NSData *)data page:(NSString *)page profile:(NSString *)profile;
@end
