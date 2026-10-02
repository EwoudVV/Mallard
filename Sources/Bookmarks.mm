#import "Bookmarks.h"
#import "Core.h"
#import <Cocoa/Cocoa.h>

static NSMutableDictionary *Node(NSDictionary *input,NSUInteger depth) {
    if(![input isKindOfClass:NSDictionary.class] || depth>64)return nil;
    BOOL folder=[input[@"children"] isKindOfClass:NSArray.class];NSString *url=[input[@"url"] isKindOfClass:NSString.class]?input[@"url"]:nil;
    if(!folder && !MallardOrigin(url))return nil;
    NSString *title=[input[@"title"] isKindOfClass:NSString.class]?input[@"title"]:[input[@"name"] isKindOfClass:NSString.class]?input[@"name"]:folder?@"Folder":url;
    NSMutableDictionary *node=[@{@"id":[input[@"id"] isKindOfClass:NSString.class]?input[@"id"]:NSUUID.UUID.UUIDString,@"title":title,@"type":folder?@"folder":@"url"} mutableCopy];
    if(folder){NSMutableArray *children=[NSMutableArray array];for(id child in input[@"children"]){id value=Node(child,depth+1);if(value)[children addObject:value];}node[@"children"]=children;}else node[@"url"]=url;
    for(NSString *key in @[@"chromeSource",@"chromeID"])if([input[key] isKindOfClass:NSString.class])node[key]=input[key];
    return node;
}
NSMutableArray *MallardBookmarkTree(NSArray *items) { NSMutableArray *result=[NSMutableArray array];for(id item in items){id node=Node(item,0);if(node)[result addObject:node];}return result; }
NSUInteger MallardBookmarkCount(NSArray *items) { NSUInteger count=0;for(NSDictionary *node in items)count+=node[@"children"]?MallardBookmarkCount(node[@"children"]):1;return count; }
static void ChromeIDs(NSArray *items,NSMutableSet *ids) { for(NSDictionary *node in items){if(node[@"chromeID"])[ids addObject:node[@"chromeID"]];if(node[@"children"])ChromeIDs(node[@"children"],ids);} }
static NSMutableDictionary *ImportNode(NSDictionary *source,NSString *prefix,NSMutableSet *ids,NSUInteger *imported,NSUInteger *skipped,NSUInteger depth) {
    if(depth>64 || ![source isKindOfClass:NSDictionary.class])return nil;
    NSString *url=[source[@"url"] isKindOfClass:NSString.class]?source[@"url"]:nil,*name=[source[@"name"] isKindOfClass:NSString.class]?source[@"name"]:nil;
    NSString *identifier=[NSString stringWithFormat:@"%@:%@",prefix,source[@"id"]?:source[@"guid"]?:url?:name?:@""];
    BOOL folder=[source[@"type"] isEqual:@"folder"] && [source[@"children"] isKindOfClass:NSArray.class];
    if(folder){NSMutableDictionary *result=[@{@"id":NSUUID.UUID.UUIDString,@"title":name?:@"Folder",@"type":@"folder",@"chromeID":identifier,@"children":[NSMutableArray array]} mutableCopy];for(id child in source[@"children"]){id value=ImportNode(child,prefix,ids,imported,skipped,depth+1);if(value)[result[@"children"] addObject:value];}return result;}
    if(![source[@"type"] isEqual:@"url"] || !MallardOrigin(url)){++*skipped;return nil;}
    if([ids containsObject:identifier]){++*skipped;return nil;}[ids addObject:identifier];++*imported;
    return [@{@"id":NSUUID.UUID.UUIDString,@"title":name?:url,@"url":url,@"type":@"url",@"chromeID":identifier} mutableCopy];
}
static void MergeFolders(NSMutableArray *destination,NSArray *incoming) {
    for(NSMutableDictionary *node in incoming){NSMutableDictionary *match=nil;if(node[@"children"])for(NSMutableDictionary *existing in destination)if(existing[@"children"] && [existing[@"chromeID"] isEqual:node[@"chromeID"]]){match=existing;break;}if(match)MergeFolders(match[@"children"],node[@"children"]);else[destination addObject:node];}
}
NSDictionary *MallardImportChrome(NSString *path,NSString *sourceName,NSMutableArray *destination,NSError **error) {
    NSData *data=[NSData dataWithContentsOfFile:path options:0 error:error];if(!data)return nil;
    id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if(![json isKindOfClass:NSDictionary.class] || ![json[@"roots"] isKindOfClass:NSDictionary.class]){if(error)*error=[NSError errorWithDomain:@"MallardBookmarks" code:1 userInfo:@{NSLocalizedDescriptionKey:@"This file is not a Chrome bookmarks file."}];return nil;}
    NSMutableSet *ids=[NSMutableSet set];ChromeIDs(destination,ids);NSUInteger imported=0,skipped=0;
    NSString *prefix=path.stringByDeletingLastPathComponent.lastPathComponent;
    NSMutableDictionary *group=nil;for(NSMutableDictionary *node in destination)if([node[@"chromeSource"] isEqual:prefix] && node[@"children"]){group=node;break;}
    NSMutableArray *folders=[NSMutableArray array];for(NSString *root in @[@"bookmark_bar",@"other",@"synced"]){id node=ImportNode(json[@"roots"][root],prefix,ids,&imported,&skipped,0);if(node)[folders addObject:node];}
    if(folders.count){if(!group){group=[@{@"id":NSUUID.UUID.UUIDString,@"title":[@"Chrome - " stringByAppendingString:sourceName],@"type":@"folder",@"chromeSource":prefix,@"children":[NSMutableArray array]} mutableCopy];[destination addObject:group];}MergeFolders(group[@"children"],folders);}
    return @{@"imported":@(imported),@"skipped":@(skipped)};
}
int MallardImportChromeSession(NSString *profile,NSString *path,NSString *sourceName) {
    if(![@[@"personal",@"school"] containsObject:profile])return 2;
    for(NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.ewoudvv.Mallard"])if(!app.terminated && app.processIdentifier!=NSProcessInfo.processInfo.processIdentifier){fprintf(stderr,"Quit Mallard before importing.\n");return 2;}
    NSString *directory=[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"Mallard"];
    NSString *file=[directory stringByAppendingPathComponent:@"session.json"];NSData *data=[NSData dataWithContentsOfFile:file];NSError *error=nil;
    NSMutableDictionary *state=data?[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error]:[NSMutableDictionary dictionary];if(![state isKindOfClass:NSMutableDictionary.class])return 2;
    if(![state[profile] isKindOfClass:NSMutableDictionary.class])state[profile]=[NSMutableDictionary dictionary];
    NSMutableArray *items=MallardBookmarkTree([state[profile][@"bookmarks"] isKindOfClass:NSArray.class]?state[profile][@"bookmarks"]:@[]);
    NSDictionary *result=MallardImportChrome(path,sourceName,items,&error);if(!result){fprintf(stderr,"Bookmark import failed: %s\n",error.localizedDescription.UTF8String);return 1;}
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];if(error)return 1;
    if(data){NSString *backup=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"session-before-bookmarks-%@.json",NSUUID.UUID.UUIDString]];if(![data writeToFile:backup options:NSDataWritingAtomic error:&error])return 1;[[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:backup error:nil];}
    state[profile][@"bookmarks"]=items;NSData *saved=[NSJSONSerialization dataWithJSONObject:state options:0 error:&error];if(![saved writeToFile:file options:NSDataWritingAtomic error:&error])return 1;
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:file error:nil];
    fprintf(stderr,"%s: imported %lu bookmarks, skipped %lu; profile now has %lu.\n",profile.UTF8String,[result[@"imported"] unsignedLongValue],[result[@"skipped"] unsignedLongValue],MallardBookmarkCount(items));return 0;
}
BOOL MallardBookmarkTests(void) {
    NSMutableArray *items=MallardBookmarkTree(@[@{@"title":@"Existing",@"url":@"https://example.com"},@{@"url":@"javascript:alert(1)"}]);
    BOOL ok=items.count==1 && MallardBookmarkCount(items)==1;
    NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];NSString *path=[directory stringByAppendingPathComponent:@"Bookmarks"];
    NSDictionary *fixture=@{@"roots":@{@"bookmark_bar":@{@"type":@"folder",@"name":@"Bookmarks Bar",@"children":@[@{@"id":@"1",@"type":@"folder",@"name":@"School",@"children":@[@{@"id":@"2",@"type":@"url",@"name":@"Example",@"url":@"https://example.org"}]}]}}};
    [[NSJSONSerialization dataWithJSONObject:fixture options:0 error:nil] writeToFile:path atomically:YES];
    NSDictionary *first=MallardImportChrome(path,@"Test",items,nil),*second=MallardImportChrome(path,@"Test",items,nil);
    ok=ok && [first[@"imported"] intValue]==1 && [second[@"imported"] intValue]==0 && MallardBookmarkCount(items)==2 && [items[1][@"children"][0][@"children"][0][@"title"] isEqual:@"School"];
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];fprintf(stderr,"Bookmark checks: %s\n",ok?"passed":"failed");return ok;
}
