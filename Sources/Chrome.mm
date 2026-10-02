#import "Chrome.h"
#import <CoreText/CoreText.h>

static NSColor *Shade(CGFloat value) { return [NSColor colorWithWhite:value alpha:1]; }
NSFont *MallardMono(CGFloat size) {
    return [NSFont fontWithName:@"JetBrainsMono-Regular" size:size]
        ?: [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
}

@implementation MallardButton {
    NSTrackingArea *tracking;
    BOOL hovered;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.bordered=NO; self.font=MallardMono(12); self.focusRingType=NSFocusRingTypeNone;
        self.contentTintColor=Shade(.85);
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return self.enabled; }
- (id)accessibilityValue { return [self.accessibilityRole isEqual:NSAccessibilityRadioButtonRole]?@(self.chosen):[super accessibilityValue]; }
- (BOOL)becomeFirstResponder { BOOL result=[super becomeFirstResponder]; self.needsDisplay=YES; return result; }
- (BOOL)resignFirstResponder { BOOL result=[super resignFirstResponder]; self.needsDisplay=YES; return result; }
- (void)setChosen:(BOOL)value { _chosen=value; self.state=value?NSControlStateValueOn:NSControlStateValueOff; self.needsDisplay=YES; }
- (void)setLeadingImage:(NSImage *)value { if(_leadingImage==value)return;_leadingImage=value;self.needsDisplay=YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if(tracking) [self removeTrackingArea:tracking];
    tracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:tracking];
}
- (void)mouseEntered:(NSEvent *)event { hovered=YES; self.needsDisplay=YES; }
- (void)mouseExited:(NSEvent *)event { hovered=NO; self.needsDisplay=YES; }
- (void)drawRect:(NSRect)dirty {
    NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:5 yRadius:5];
    if(self.chosen || (self.enabled && (hovered || self.highlighted))) {
        [Shade(self.highlighted?.20:self.chosen?.14:.09) setFill]; [shape fill];
    }
    if(self.image) {
        [super drawRect:dirty];
    } else {
        CGFloat left=self.leadingImage?34:10;
        if(self.leadingImage)[self.leadingImage drawInRect:NSMakeRect(10,round((self.bounds.size.height-16)/2),16,16) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:self.enabled?1:.45 respectFlipped:YES hints:nil];
        NSFont *font=self.font?:MallardMono(12);
        NSColor *color=self.enabled?(self.chosen?Shade(.95):self.contentTintColor):Shade(.32);
        NSDictionary *attributes=@{NSFontAttributeName:font,NSForegroundColorAttributeName:color};
        NSAttributedString *string=[[NSAttributedString alloc] initWithString:self.title?:@"" attributes:attributes];
        CTLineRef line=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
        CGFloat available=MAX(0,self.bounds.size.width-left-10-self.trailingInset);
        if(CTLineGetTypographicBounds(line,NULL,NULL,NULL)>available) {
            NSAttributedString *ellipsis=[[NSAttributedString alloc] initWithString:@"…" attributes:attributes];
            CTLineRef token=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)ellipsis);
            CTLineRef truncated=CTLineCreateTruncatedLine(line,available,kCTLineTruncationEnd,token);
            CFRelease(token); if(truncated){CFRelease(line);line=truncated;}
        }
        CGFloat width=CTLineGetTypographicBounds(line,NULL,NULL,NULL);
        CGFloat x=self.leftAligned?left:round((self.bounds.size.width-width)/2);
        CGContextRef context=NSGraphicsContext.currentContext.CGContext;
        CGContextSaveGState(context);
        CGContextTranslateCTM(context,0,self.bounds.size.height); CGContextScaleCTM(context,1,-1);
        CGContextSetTextMatrix(context,CGAffineTransformIdentity);
        // A stable cap-height baseline keeps titles aligned even when one has descenders.
        CGContextSetTextPosition(context,x,round((self.bounds.size.height-font.capHeight)/2));
        CTLineDraw(line,context); CGContextRestoreGState(context); CFRelease(line);
    }
    if(self.window.firstResponder==self) { [Shade(.48) setStroke]; shape.lineWidth=1; [shape stroke]; }
}
@end

@interface MallardPrompt : NSView
@property(copy) NSString *text;
@property NSFont *font;
@end
@implementation MallardPrompt
- (void)drawRect:(NSRect)dirty {
    NSAttributedString *string=[[NSAttributedString alloc] initWithString:self.text?:@"" attributes:@{NSFontAttributeName:self.font,NSForegroundColorAttributeName:[NSColor colorWithRed:.22 green:.79 blue:.17 alpha:1]}];
    CTLineRef line=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    CGRect ink=CTLineGetBoundsWithOptions(line,kCTLineBoundsUseGlyphPathBounds);
    CGContextRef context=NSGraphicsContext.currentContext.CGContext;CGContextSaveGState(context);
    CGContextSetTextMatrix(context,CGAffineTransformIdentity);
    CGContextSetTextPosition(context,2,round((self.bounds.size.height-ink.size.height)/2-ink.origin.y));
    CTLineDraw(line,context);CGContextRestoreGState(context);CFRelease(line);
}
@end

@implementation MallardInput {
    MallardPrompt *promptLabel;
    BOOL lastFocused;
}
- (instancetype)initWithFontSize:(CGFloat)size secure:(BOOL)secure {
    if((self=[super initWithFrame:NSZeroRect])) {
        _field=secure?[NSSecureTextField new]:[NSTextField new];
        _field.font=MallardMono(size); _field.bordered=NO; _field.drawsBackground=NO;
        _field.textColor=Shade(.94); _field.focusRingType=NSFocusRingTypeNone;
        _field.cell.usesSingleLineMode=YES; _field.cell.scrollable=YES;
        _field.cell.sendsActionOnEndEditing=NO;
        [self addSubview:_field];
        for(NSNotificationName name in @[NSControlTextDidBeginEditingNotification,NSControlTextDidEndEditingNotification])
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(focusChanged:) name:name object:_field];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowUpdated:) name:NSWindowDidUpdateNotification object:nil];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)focusChanged:(NSNotification *)notification { self.needsDisplay=YES; }
- (BOOL)hasFocus { return self.window.firstResponder==_field || (_field.currentEditor && self.window.firstResponder==_field.currentEditor); }
- (void)windowUpdated:(NSNotification *)notification {
    if(notification.object!=self.window)return;
    BOOL focused=[self hasFocus];if(focused!=lastFocused){lastFocused=focused;self.needsDisplay=YES;}
}
- (void)setMinimal:(BOOL)value { _minimal=value; [self setNeedsLayout:YES]; self.needsDisplay=YES; }
- (void)setTrailingInset:(CGFloat)value { _trailingInset=value; [self setNeedsLayout:YES]; }
- (void)setPrompt:(NSString *)value {
    _prompt=[value copy];
    if(!promptLabel) { promptLabel=[MallardPrompt new]; promptLabel.font=_field.font; [self addSubview:promptLabel]; }
    promptLabel.text=value?:@""; [self setNeedsLayout:YES];
}
- (void)layout {
    [super layout];
    CGFloat height=ceil(_field.cell.cellSize.height);
    CGFloat lineArea=self.minimal?self.bounds.size.height-14:self.bounds.size.height;
    CGFloat inset=self.minimal?(self.prompt.length?30:0):9;
    NSRect text=NSMakeRect(inset,round((lineArea-height)/2),MAX(0,self.bounds.size.width-inset-(self.minimal?0:9)-self.trailingInset),height);
    _field.frame=text;
    if(promptLabel) {
        CGFloat letterCenter=NSMinY(text)+_field.firstBaselineOffsetFromTop-_field.font.capHeight/2;
        promptLabel.frame=NSMakeRect(0,letterCenter-lineArea/2,24,lineArea);
    }
}
- (void)drawRect:(NSRect)dirty {
    BOOL focused=[self hasFocus];
    if(self.minimal) {
        [(focused?[NSColor colorWithRed:.20 green:.48 blue:.18 alpha:1]:Shade(.22)) setFill];
        NSRectFill(NSMakeRect(0,self.bounds.size.height-1,self.bounds.size.width,1));
    } else {
        NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:5 yRadius:5];
        [Shade(.09) setFill]; [shape fill]; [(focused?Shade(.45):Shade(.15)) setStroke]; shape.lineWidth=1; [shape stroke];
    }
}
- (void)mouseDown:(NSEvent *)event { [self.window makeFirstResponder:_field]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

@implementation MallardTabRow
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])) {
        _selectButton=[MallardButton new]; _selectButton.leftAligned=YES; _selectButton.trailingInset=26; [self addSubview:_selectButton];
        _closeButton=[MallardButton new];
        _closeButton.image=[[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Close tab"] imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightRegular]];
        [_closeButton setAccessibilityLabel:@"Close tab"]; [self addSubview:_closeButton];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout]; _selectButton.frame=self.bounds;
    _closeButton.frame=NSMakeRect(self.bounds.size.width-31,3,28,self.bounds.size.height-6);
}
@end

@interface MallardPanelContent : NSView
@end
@implementation MallardPanelContent
- (BOOL)isFlipped { return YES; }
@end

@interface MallardDialog : NSWindowController
@property NSArray<NSTextField *> *fields;
@property NSInteger cancelIndex;
- (void)finish:(NSControl *)sender;
@end
@implementation MallardDialog
- (void)finish:(NSControl *)sender { [NSApp stopModalWithCode:sender.tag]; }
- (void)cancelOperation:(id)sender { [NSApp stopModalWithCode:self.cancelIndex]; }
@end

static NSTextField *PanelLabel(NSString *text,CGFloat size,CGFloat shade) {
    NSTextField *label=[NSTextField wrappingLabelWithString:text?:@""]; label.font=MallardMono(size); label.textColor=Shade(shade); return label;
}

NSInteger MallardRunDialog(NSWindow *parent,NSString *title,NSString *detail,NSArray<NSString *> *names,NSIndexSet *secure,NSArray<NSString *> *initial,NSArray<NSString *> *buttons,NSArray<NSString *> **values) {
    CGFloat width=MIN(480,parent.contentView.bounds.size.width-48),inside=width-40;
    NSTextField *heading=PanelLabel(title,14,.94),*explanation=PanelLabel(detail,11,.65);
    CGFloat titleHeight=ceil([heading.cell cellSizeForBounds:NSMakeRect(0,0,inside,CGFLOAT_MAX)].height);
    CGFloat detailHeight=detail.length?ceil([explanation.cell cellSizeForBounds:NSMakeRect(0,0,inside,CGFLOAT_MAX)].height):0;
    CGFloat header=20+titleHeight+(detailHeight?12+detailHeight:0)+20;
    CGFloat rows=0; for(NSString *name in names) rows+=name.length?62:38;
    CGFloat visible=MIN(rows,MAX(100,parent.contentView.bounds.size.height-header-98));
    CGFloat height=header+visible+66;
    NSPanel *panel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,width,height) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    panel.title=title; panel.titleVisibility=NSWindowTitleHidden; panel.titlebarAppearsTransparent=YES;
    panel.autorecalculatesKeyViewLoop=YES;
    panel.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]; panel.backgroundColor=Shade(.055);
    MallardPanelContent *content=[[MallardPanelContent alloc] initWithFrame:NSMakeRect(0,0,width,height)]; panel.contentView=content;
    heading.frame=NSMakeRect(20,20,inside,titleHeight); [content addSubview:heading];
    if(detailHeight) { explanation.frame=NSMakeRect(20,20+titleHeight+12,inside,detailHeight); [content addSubview:explanation]; }
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(20,header,inside,visible)]; scroll.hasVerticalScroller=rows>visible; scroll.autohidesScrollers=YES; scroll.drawsBackground=NO;
    MallardPanelContent *document=[[MallardPanelContent alloc] initWithFrame:NSMakeRect(0,0,scroll.contentSize.width,rows)]; scroll.documentView=document; [content addSubview:scroll];
    MallardDialog *dialog=[[MallardDialog alloc] initWithWindow:panel]; NSMutableArray *fields=[NSMutableArray array]; CGFloat y=0;
    dialog.cancelIndex=0;for(NSUInteger i=0;i<buttons.count;i++)if([@[@"Cancel",@"Stay on Page"] containsObject:buttons[i]])dialog.cancelIndex=i;
    for(NSUInteger i=0;i<names.count;i++) {
        CGFloat fieldY=y;
        if(names[i].length) { NSTextField *label=PanelLabel(names[i],11,.70); label.frame=NSMakeRect(0,y,inside-4,18); [document addSubview:label]; fieldY+=21; }
        MallardInput *input=[[MallardInput alloc] initWithFontSize:12 secure:[secure containsIndex:i]]; input.frame=NSMakeRect(0,fieldY,document.bounds.size.width-3,32);
        NSTextField *field=input.field; field.stringValue=i<initial.count?initial[i]:@""; [field setAccessibilityLabel:names[i].length?names[i]:title]; field.target=dialog; field.action=@selector(finish:); field.tag=0;
        [document addSubview:input]; [fields addObject:field]; y+=names[i].length?62:38;
    }
    dialog.fields=fields;
    CGFloat x=width-20;
    for(NSUInteger i=0;i<buttons.count;i++) {
        CGFloat buttonWidth=MAX(86,ceil([buttons[i] sizeWithAttributes:@{NSFontAttributeName:MallardMono(12)}].width)+24); x-=buttonWidth;
        MallardButton *button=[[MallardButton alloc] initWithFrame:NSMakeRect(x,height-48,buttonWidth,30)]; button.title=buttons[i]; button.chosen=i==0; button.tag=i; button.target=dialog; button.action=@selector(finish:);
        button.keyEquivalent=i==0?@"\r":i==dialog.cancelIndex?@"\e":@""; [content addSubview:button]; x-=8;
    }
    panel.initialFirstResponder=fields.firstObject;
    [parent beginSheet:panel completionHandler:nil];
    NSInteger result=[NSApp runModalForWindow:panel];
    if(values) { NSMutableArray *items=[NSMutableArray array]; for(NSTextField *field in fields) [items addObject:field.stringValue]; *values=items; }
    [parent endSheet:panel]; [panel orderOut:nil]; [parent makeKeyAndOrderFront:nil];
    return result;
}
