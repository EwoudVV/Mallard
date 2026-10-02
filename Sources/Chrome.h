#import <Cocoa/Cocoa.h>

NSFont *MallardMono(CGFloat size);

@interface MallardButton : NSButton
@property(nonatomic) BOOL chosen;
@property(nonatomic) BOOL leftAligned;
@property(nonatomic) CGFloat trailingInset;
@property(nonatomic,strong) NSImage *leadingImage;
@end

@interface MallardInput : NSView
@property(readonly) NSTextField *field;
@property(nonatomic) BOOL minimal;
@property(nonatomic) CGFloat trailingInset;
@property(nonatomic,copy) NSString *prompt;
- (instancetype)initWithFontSize:(CGFloat)size secure:(BOOL)secure;
@end

@interface MallardTabRow : NSView
@property(readonly) MallardButton *selectButton;
@property(readonly) MallardButton *closeButton;
@end

NSInteger MallardRunDialog(NSWindow *parent, NSString *title, NSString *detail,
                          NSArray<NSString *> *names, NSIndexSet *secure,
                          NSArray<NSString *> *initial, NSArray<NSString *> *buttons,
                          NSArray<NSString *> **values);
