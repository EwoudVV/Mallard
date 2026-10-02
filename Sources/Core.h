#import <Foundation/Foundation.h>

NSString *MallardURL(NSString *input);
NSString *MallardOrigin(NSString *url);
NSArray<NSDictionary *> *MallardParsePasswordCSV(NSString *text, NSError **error);
BOOL MallardCoreTests(void);
