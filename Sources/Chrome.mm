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
    CGContextSetTextPosition(context,0,round((self.bounds.size.height-ink.size.height)/2-ink.origin.y));
    CTLineDraw(line,context);CGContextRestoreGState(context);CFRelease(line);
}
@end

@interface MallardTextField : NSTextField
@property BOOL selectsAllOnFirstClick;
@end
@implementation MallardTextField
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return self.selectsAllOnFirstClick || [super acceptsFirstMouse:event]; }
@end

@implementation MallardInput {
    MallardPrompt *promptLabel;
    BOOL lastFocused;
    BOOL clickedWhileFocused;
    id clickMonitor;
}
- (instancetype)initWithFontSize:(CGFloat)size secure:(BOOL)secure {
    if((self=[super initWithFrame:NSZeroRect])) {
        _field=secure?[NSSecureTextField new]:[MallardTextField new];
        _field.font=MallardMono(size); _field.bordered=NO; _field.drawsBackground=NO;
        _field.textColor=Shade(.94); _field.focusRingType=NSFocusRingTypeNone;
        _field.cell.usesSingleLineMode=YES; _field.cell.scrollable=YES;
        _field.cell.sendsActionOnEndEditing=NO;
        [self addSubview:_field];
        for(NSNotificationName name in @[NSControlTextDidBeginEditingNotification,NSControlTextDidEndEditingNotification])
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(focusChanged:) name:name object:_field];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowUpdated:) name:NSWindowDidUpdateNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowResigned:) name:NSWindowDidResignKeyNotification object:nil];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)focusChanged:(NSNotification *)notification { self.needsDisplay=YES; }
- (BOOL)hasFocus { return self.window.firstResponder==_field || (_field.currentEditor && self.window.firstResponder==_field.currentEditor); }
- (void)tintCursor {
    NSText *editor=_field.currentEditor;
    if([editor isKindOfClass:NSTextView.class] && ![((NSTextView *)editor).insertionPointColor isEqual:_field.textColor])((NSTextView *)editor).insertionPointColor=_field.textColor;
}
- (void)windowUpdated:(NSNotification *)notification {
    if(notification.object!=self.window)return;
    BOOL focused=[self hasFocus];if(!focused)clickedWhileFocused=NO;else [self tintCursor];
    if(focused!=lastFocused){lastFocused=focused;self.needsDisplay=YES;}
}
- (void)windowResigned:(NSNotification *)notification { if(notification.object==self.window)clickedWhileFocused=NO; }
- (void)setMinimal:(BOOL)value { _minimal=value; [self setNeedsLayout:YES]; self.needsDisplay=YES; }
- (void)setSelectsAllOnFirstClick:(BOOL)value {
    _selectsAllOnFirstClick=value;
    if([_field isKindOfClass:MallardTextField.class])((MallardTextField *)_field).selectsAllOnFirstClick=value;
    if(!value && clickMonitor){[NSEvent removeMonitor:clickMonitor];clickMonitor=nil;}
    if(!value || clickMonitor)return;
    __weak MallardInput *weakSelf=self;
    // The field editor receives later clicks directly, bypassing NSTextField.mouseDown.
    clickMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *event) {
        MallardInput *owner=weakSelf;if(!owner)return event;
        BOOL inside=event.window==owner.window && ![owner isHiddenOrHasHiddenAncestor] && NSPointInRect([owner convertPoint:event.locationInWindow fromView:nil],owner.bounds);
        if(!inside){owner->clickedWhileFocused=NO;return event;}
        BOOL selectAll=!owner->clickedWhileFocused || ![owner hasFocus];owner->clickedWhileFocused=YES;
        if(selectAll && event.clickCount==1 && !(event.modifierFlags&(NSEventModifierFlagShift|NSEventModifierFlagCommand))){[owner focusAndSelectAll];return nil;}
        return event;
    }];
}
- (void)focusAndSelectAll { [self.window makeFirstResponder:_field];[_field selectText:nil];[self tintCursor];clickedWhileFocused=YES; }
- (void)setTrailingInset:(CGFloat)value { _trailingInset=value; [self setNeedsLayout:YES]; }
- (void)setPrompt:(NSString *)value {
    _prompt=[value copy];
    if(!promptLabel) { promptLabel=[MallardPrompt new]; promptLabel.font=_field.font; [self addSubview:promptLabel]; }
    promptLabel.text=value?:@""; [self setNeedsLayout:YES];
}
- (void)layout {
    [super layout];
    CGFloat height=ceil(_field.cell.cellSize.height);
    // Minimal inputs keep the underline 5 points under the text line.
    CGFloat lineArea=self.minimal?self.bounds.size.height-5:self.bounds.size.height;
    // Editable text draws 2 points inside the field. Start it one space after the prompt, like a terminal.
    CGFloat promptWidth=self.prompt.length?ceil([[self.prompt stringByAppendingString:@" "] sizeWithAttributes:@{NSFontAttributeName:_field.font}].width):0;
    CGFloat inset=self.minimal?promptWidth-2:9;
    NSRect text=NSMakeRect(inset,round((lineArea-height)/2),MAX(0,self.bounds.size.width-inset-(self.minimal?0:9)-self.trailingInset),height);
    _field.frame=text;
    if(promptLabel) {
        CGFloat letterCenter=NSMinY(text)+_field.firstBaselineOffsetFromTop-_field.font.capHeight/2;
        promptLabel.frame=NSMakeRect(0,letterCenter-lineArea/2,MAX(1,promptWidth),lineArea);
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
- (void)mouseDown:(NSEvent *)event { if(self.selectsAllOnFirstClick)[self focusAndSelectAll];else{[self.window makeFirstResponder:_field];[self tintCursor];} }
- (void)dealloc { if(clickMonitor)[NSEvent removeMonitor:clickMonitor];[NSNotificationCenter.defaultCenter removeObserver:self]; }
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
    // One margin on every side. Text frames sit 2 points left so letters start on the same edge as the boxes and buttons.
    const CGFloat margin=20,inset=2,labelGap=3,fieldHeight=32,rowGap=12;
    CGFloat width=MIN(480,parent.contentView.bounds.size.width-48),inside=width-2*margin;
    NSTextField *heading=PanelLabel(title,14,.94),*explanation=PanelLabel(detail,11,.65);
    CGFloat titleHeight=ceil([heading.cell cellSizeForBounds:NSMakeRect(0,0,inside+2*inset,CGFLOAT_MAX)].height);
    CGFloat detailHeight=detail.length?ceil([explanation.cell cellSizeForBounds:NSMakeRect(0,0,inside+2*inset,CGFLOAT_MAX)].height):0;
    // The heading's line box has room above its capitals. Pull it up so the capitals start at the margin.
    CGFloat headingY=margin-round(heading.font.ascender-heading.font.capHeight);
    CGFloat y=headingY+titleHeight,detailY=0; if(detailHeight){y+=8;detailY=y;y+=detailHeight;}
    CGFloat rows=0; for(NSUInteger i=0;i<names.count;i++) rows+=(i?rowGap:0)+(names[i].length?18+labelGap:0)+fieldHeight;
    CGFloat fieldsTop=y+(names.count?margin:0);
    CGFloat visible=names.count?MIN(rows,MAX(100,parent.contentView.bounds.size.height-fieldsTop-2*margin-30-48)):0;
    CGFloat buttonsY=fieldsTop+visible+margin,height=buttonsY+30+margin;
    NSPanel *panel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,width,height) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    panel.title=title; panel.titleVisibility=NSWindowTitleHidden; panel.titlebarAppearsTransparent=YES;
    panel.autorecalculatesKeyViewLoop=YES;
    panel.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]; panel.backgroundColor=Shade(.055);
    MallardPanelContent *content=[[MallardPanelContent alloc] initWithFrame:NSMakeRect(0,0,width,height)]; panel.contentView=content;
    heading.frame=NSMakeRect(margin-inset,headingY,inside+2*inset,titleHeight); [content addSubview:heading];
    if(detailHeight) { explanation.frame=NSMakeRect(margin-inset,detailY,inside+2*inset,detailHeight); [content addSubview:explanation]; }
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(margin,fieldsTop,inside,visible)]; scroll.hasVerticalScroller=rows>visible; scroll.autohidesScrollers=YES; scroll.drawsBackground=NO;
    MallardPanelContent *document=[[MallardPanelContent alloc] initWithFrame:NSMakeRect(0,0,scroll.contentSize.width,rows)]; scroll.documentView=document; [content addSubview:scroll];
    MallardDialog *dialog=[[MallardDialog alloc] initWithWindow:panel]; NSMutableArray *fields=[NSMutableArray array]; y=0;
    dialog.cancelIndex=0;for(NSUInteger i=0;i<buttons.count;i++)if([@[@"Cancel",@"Stay on Page"] containsObject:buttons[i]])dialog.cancelIndex=i;
    for(NSUInteger i=0;i<names.count;i++) {
        CGFloat fieldY=y;
        if(names[i].length) { NSTextField *label=PanelLabel(names[i],11,.70); label.frame=NSMakeRect(-inset,y,document.bounds.size.width+2*inset,18); [document addSubview:label]; fieldY+=18+labelGap; }
        MallardInput *input=[[MallardInput alloc] initWithFontSize:12 secure:[secure containsIndex:i]]; input.frame=NSMakeRect(0,fieldY,document.bounds.size.width,fieldHeight);
        NSTextField *field=input.field; field.stringValue=i<initial.count?initial[i]:@""; [field setAccessibilityLabel:names[i].length?names[i]:title]; field.target=dialog; field.action=@selector(finish:); field.tag=0;
        [document addSubview:input]; [fields addObject:field]; y=fieldY+fieldHeight+rowGap;
    }
    dialog.fields=fields;
    CGFloat x=width-margin;
    for(NSUInteger i=0;i<buttons.count;i++) {
        CGFloat buttonWidth=MAX(86,ceil([buttons[i] sizeWithAttributes:@{NSFontAttributeName:MallardMono(12)}].width)+24); x-=buttonWidth;
        MallardButton *button=[[MallardButton alloc] initWithFrame:NSMakeRect(x,buttonsY,buttonWidth,30)]; button.title=buttons[i]; button.chosen=i==0; button.tag=i; button.target=dialog; button.action=@selector(finish:);
        button.keyEquivalent=i==0?@"\r":i==dialog.cancelIndex?@"\e":@""; [content addSubview:button]; x-=8;
    }
    panel.initialFirstResponder=fields.firstObject;
    [parent beginSheet:panel completionHandler:nil];
    NSInteger result=[NSApp runModalForWindow:panel];
    if(values) { NSMutableArray *items=[NSMutableArray array]; for(NSTextField *field in fields) [items addObject:field.stringValue]; *values=items; }
    [parent endSheet:panel]; [panel orderOut:nil]; [parent makeKeyAndOrderFront:nil];
    return result;
}
