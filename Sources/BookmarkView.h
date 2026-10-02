#import <Cocoa/Cocoa.h>
@class MallardFavicons;

@interface MallardBookmarkView : NSView
@property(nonatomic,strong) NSMutableArray *items;
@property(nonatomic,strong) MallardFavicons *favicons;
@property(nonatomic,copy) NSString *profile;
@property(copy) void (^openURL)(NSString *url);
@property(copy) void (^changed)(void);
@property(copy) void (^importRequested)(void);
- (void)addURL:(NSString *)url title:(NSString *)title;
- (void)newFolder:(id)sender;
- (void)focusBookmarks;
@end
