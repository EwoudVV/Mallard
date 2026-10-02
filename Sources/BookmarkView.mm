#import "BookmarkView.h"
#import "Chrome.h"
#import "Bookmarks.h"
#import "Favicons.h"

@interface MallardBookmarkView () <NSOutlineViewDataSource,NSOutlineViewDelegate,NSMenuDelegate>
@end
static NSString *BookmarkLabel(NSDictionary *item) {
    NSString *title=[item[@"title"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(title.length)return title;
    NSString *host=[NSURLComponents componentsWithString:item[@"url"]?:@""].host;
    if([host hasPrefix:@"www."])host=[host substringFromIndex:4];
    return host.length?host:item[@"url"]?:@"Untitled";
}
@implementation MallardBookmarkView {
    NSOutlineView *tree;
    NSScrollView *scroll;
    NSTextField *heading,*empty;
    MallardButton *folderButton;
    NSMutableArray *undoStates;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])) {
        _items=[NSMutableArray array];undoStates=[NSMutableArray array];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(faviconChanged:) name:MallardFaviconChanged object:nil];
        heading=[NSTextField labelWithString:@"bookmarks"];heading.font=MallardMono(11);heading.textColor=[NSColor colorWithWhite:.5 alpha:1];[self addSubview:heading];
        folderButton=[MallardButton new];folderButton.image=[NSImage imageWithSystemSymbolName:@"folder.badge.plus" accessibilityDescription:@"New bookmark folder"];folderButton.toolTip=@"New folder";folderButton.target=self;folderButton.action=@selector(newFolder:);[folderButton setAccessibilityLabel:@"New bookmark folder"];[self addSubview:folderButton];
        scroll=[NSScrollView new];scroll.hasVerticalScroller=YES;scroll.autohidesScrollers=YES;scroll.drawsBackground=NO;[self addSubview:scroll];
        tree=[NSOutlineView new];NSTableColumn *column=[[NSTableColumn alloc] initWithIdentifier:@"title"];[tree addTableColumn:column];tree.outlineTableColumn=column;tree.headerView=nil;tree.rowHeight=27;tree.indentationPerLevel=11;tree.intercellSpacing=NSMakeSize(0,1);tree.columnAutoresizingStyle=NSTableViewLastColumnOnlyAutoresizingStyle;
        tree.backgroundColor=[NSColor colorWithWhite:.045 alpha:1];tree.dataSource=self;tree.delegate=self;tree.target=self;tree.action=@selector(openSelected:);[tree setAccessibilityLabel:@"Bookmarks and folders"];scroll.documentView=tree;
        NSMenu *menu=[NSMenu new];menu.delegate=self;tree.menu=menu;
        empty=[NSTextField labelWithString:@"No bookmarks yet"];empty.font=MallardMono(10);empty.textColor=[NSColor colorWithWhite:.45 alpha:1];[self addSubview:empty];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)layout { [super layout];CGFloat width=self.bounds.size.width;heading.frame=NSMakeRect(20,6,width-60,18);folderButton.frame=NSMakeRect(width-42,0,28,28);scroll.frame=NSMakeRect(10,31,width-20,MAX(0,self.bounds.size.height-35));empty.frame=NSMakeRect(22,40,width-30,18);tree.outlineTableColumn.width=MAX(0,scroll.contentSize.width); }
- (void)setItems:(NSMutableArray *)value {
    if(_items==value)return;_items=value;[undoStates removeAllObjects];[tree reloadData];empty.hidden=value.count>0;
    for(id item in value)if(item[@"children"]){[tree expandItem:item];if(item[@"chromeSource"])for(id folder in item[@"children"])if([folder[@"children"] count])[tree expandItem:folder];}
}
- (NSInteger)outlineView:(NSOutlineView *)outline numberOfChildrenOfItem:(id)item { return item?[item[@"children"] count]:self.items.count; }
- (id)outlineView:(NSOutlineView *)outline child:(NSInteger)index ofItem:(id)item { return item?item[@"children"][index]:self.items[index]; }
- (BOOL)outlineView:(NSOutlineView *)outline isItemExpandable:(id)item { return item[@"children"]!=nil; }
- (NSView *)outlineView:(NSOutlineView *)outline viewForTableColumn:(NSTableColumn *)column item:(id)item {
    NSTableCellView *cell=[outline makeViewWithIdentifier:@"bookmark" owner:self];
    if(!cell){cell=[[NSTableCellView alloc] initWithFrame:NSMakeRect(0,0,150,27)];cell.identifier=@"bookmark";NSTextField *label=[NSTextField labelWithString:@""];label.font=MallardMono(11);label.textColor=[NSColor colorWithWhite:.78 alpha:1];label.lineBreakMode=NSLineBreakByTruncatingTail;label.frame=NSMakeRect(25,4,122,19);label.autoresizingMask=NSViewWidthSizable;cell.textField=label;[cell addSubview:label];
        NSImageView *icon=[[NSImageView alloc] initWithFrame:NSMakeRect(3,5,16,16)];icon.imageScaling=NSImageScaleProportionallyDown;[icon setAccessibilityElement:NO];cell.imageView=icon;[cell addSubview:icon];}
    cell.objectValue=item;
    cell.imageView.image=item[@"children"]?MallardSiteSymbol(YES):[self.favicons imageForPage:item[@"url"] profile:self.profile]?:MallardSiteSymbol(NO);
    cell.textField.stringValue=BookmarkLabel(item);cell.toolTip=item[@"url"]?:item[@"title"];[cell setAccessibilityLabel:cell.textField.stringValue];return cell;
}
- (void)faviconChanged:(NSNotification *)notification {
    if(notification.object!=self.favicons || ![notification.userInfo[@"profile"] isEqual:self.profile])return;
    NSRange visible=[tree rowsInRect:tree.visibleRect];if(visible.location==NSNotFound)return;
    for(NSUInteger row=visible.location;row<NSMaxRange(visible);row++) {
        NSTableCellView *cell=[tree viewAtColumn:0 row:row makeIfNecessary:NO];NSDictionary *item=[tree itemAtRow:row];
        if(!item[@"children"] && [MallardFaviconPage(item[@"url"]) isEqual:notification.userInfo[@"page"]])cell.imageView.image=[self.favicons imageForPage:item[@"url"] profile:self.profile]?:MallardSiteSymbol(NO);
    }
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)openSelected:(id)sender { id item=[tree itemAtRow:tree.selectedRow];if(!item)return;if(item[@"children"]){if([tree isItemExpanded:item])[tree collapseItem:item];else[tree expandItem:item];}else if(self.openURL)self.openURL(item[@"url"]); }
- (id)contextItem { NSInteger row=tree.clickedRow>=0?tree.clickedRow:tree.selectedRow;return [tree itemAtRow:row]; }
- (NSMutableArray *)parentOf:(id)item in:(NSMutableArray *)nodes { for(id node in nodes){if(node==item)return nodes;if(node[@"children"]){id result=[self parentOf:item in:node[@"children"]];if(result)return result;}}return nil; }
- (NSMutableArray *)targetFolder { id item=[tree itemAtRow:tree.selectedRow];return item[@"children"]?:[self parentOf:item in:self.items]?:self.items; }
- (void)remember { [undoStates addObject:MallardBookmarkTree(self.items)];if(undoStates.count>20)[undoStates removeObjectAtIndex:0]; }
- (void)commit { [tree reloadData];empty.hidden=self.items.count>0;if(self.changed)self.changed(); }
- (void)addURL:(NSString *)url title:(NSString *)title {
    NSMutableArray *destination=[self targetFolder];for(id node in destination)if([node[@"url"] isEqual:url])return;
    [self remember];[destination addObject:[@{@"id":NSUUID.UUID.UUIDString,@"title":title.length?title:url,@"type":@"url",@"url":url} mutableCopy]];[self commit];
}
- (void)newFolder:(id)sender {
    NSArray *values=nil;if(MallardRunDialog(self.window,@"New bookmark folder",@"Created inside the selected folder.",@[@"Name"],nil,@[@""],@[@"Create",@"Cancel"],&values)!=0)return;
    NSString *name=[values.firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!name.length)return;
    [self remember];[[self targetFolder] addObject:[@{@"id":NSUUID.UUID.UUIDString,@"title":name,@"type":@"folder",@"children":[NSMutableArray array]} mutableCopy]];[self commit];
}
- (void)rename:(NSMenuItem *)sender {
    id item=sender.representedObject;NSArray *values=nil;if(!item || MallardRunDialog(self.window,@"Rename bookmark",@"",@[@"Name"],nil,@[item[@"title"]?:@""],@[@"Rename",@"Cancel"],&values)!=0)return;
    if(![values.firstObject length])return;[self remember];item[@"title"]=values.firstObject;[self commit];
}
- (void)remove:(NSMenuItem *)sender { id item=sender.representedObject;NSMutableArray *parent=[self parentOf:item in:self.items];if(!parent)return;[self remember];[parent removeObjectIdenticalTo:item];[self commit]; }
- (void)undoChange:(id)sender { if(!undoStates.count)return;[self.items setArray:undoStates.lastObject];[undoStates removeLastObject];[self commit]; }
- (void)move:(NSMenuItem *)sender { NSDictionary *move=sender.representedObject;id item=move[@"item"];NSMutableArray *parent=[self parentOf:item in:self.items],*destination=move[@"destination"];if(!parent || parent==destination)return;[self remember];[parent removeObjectIdenticalTo:item];[destination addObject:item];[self commit]; }
- (void)addFolders:(NSArray *)nodes menu:(NSMenu *)menu path:(NSString *)path excluding:(id)excluded {
    for(id node in nodes)if(node[@"children"] && node!=excluded){NSString *title=path.length?[path stringByAppendingFormat:@" / %@",node[@"title"]]:node[@"title"];NSMenuItem *entry=[[NSMenuItem alloc] initWithTitle:title action:@selector(move:) keyEquivalent:@""];entry.target=self;entry.representedObject=@{@"item":excluded,@"destination":node[@"children"]};[menu addItem:entry];[self addFolders:node[@"children"] menu:menu path:title excluding:excluded];}
}
- (void)importChrome:(id)sender { if(self.importRequested)self.importRequested(); }
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if(tree.clickedRow>=0)[tree selectRowIndexes:[NSIndexSet indexSetWithIndex:tree.clickedRow] byExtendingSelection:NO];
    [menu removeAllItems];id item=[self contextItem];
    for(NSArray *entry in @[@[@"New Folder…",@"newFolder:"],@[@"Import Chrome Bookmarks…",@"importChrome:"]]){NSMenuItem *command=[[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""];command.target=self;[menu addItem:command];}
    if(item){[menu addItem:NSMenuItem.separatorItem];for(NSArray *entry in @[@[@"Rename…",@"rename:"],@[@"Remove",@"remove:"]]){NSMenuItem *command=[[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""];command.target=self;command.representedObject=item;[menu addItem:command];}
        NSMenu *destinations=[NSMenu new];NSMenuItem *root=[[NSMenuItem alloc] initWithTitle:@"Bookmarks" action:@selector(move:) keyEquivalent:@""];root.target=self;root.representedObject=@{@"item":item,@"destination":self.items};[destinations addItem:root];[self addFolders:self.items menu:destinations path:@"" excluding:item];NSMenuItem *move=[[NSMenuItem alloc] initWithTitle:@"Move to" action:nil keyEquivalent:@""];move.submenu=destinations;[menu addItem:move];}
    if(undoStates.count){[menu addItem:NSMenuItem.separatorItem];NSMenuItem *undo=[[NSMenuItem alloc] initWithTitle:@"Undo Bookmark Change" action:@selector(undoChange:) keyEquivalent:@""];undo.target=self;[menu addItem:undo];}
}
- (void)focusBookmarks { [self.window makeFirstResponder:tree]; }
@end
