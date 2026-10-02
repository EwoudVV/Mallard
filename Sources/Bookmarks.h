#import <Foundation/Foundation.h>

NSMutableArray *MallardBookmarkTree(NSArray *items);
NSUInteger MallardBookmarkCount(NSArray *items);
NSDictionary *MallardImportChrome(NSString *path,NSString *sourceName,NSMutableArray *destination,NSError **error);
BOOL MallardBookmarkTests(void);
int MallardImportChromeSession(NSString *profile,NSString *path,NSString *sourceName);
