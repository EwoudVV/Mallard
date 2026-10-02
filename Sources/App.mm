#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import "Core.h"
#import "Vault.h"
#import "FilterUpdater.h"
#import "Chrome.h"
#import "Telemetry.h"
#import "Bookmarks.h"
#import "BookmarkView.h"
#import "Favicons.h"
#include "Blocker.h"
#include <algorithm>
#include <atomic>
#include <memory>
#include <vector>
#include <unordered_map>
#include <set>
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_image.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

static NSColor *Color(CGFloat n) { return [NSColor colorWithWhite:n alpha:1]; }
static NSFont *Mono(CGFloat size) { return MallardMono(size); }
static NSString *Text(const CefString &s) { return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @""; }
static CefString CefText(NSString *s) { return std::string(s.UTF8String ?: ""); }
static NSString *DataDirectory;
static BOOL Quitting=NO;
static NSInteger BrowserCount=0;
static NSString *FilterDirectory;
static BOOL BlockingReady=NO;
static std::atomic<uint64_t> TotalBlocked{0};

@interface MallardView : NSView
@property NSInteger tag;
@end
@implementation MallardView
@synthesize tag;
- (BOOL)isFlipped { return YES; }
@end

struct Tab {
    __strong NSString *identifier=NSUUID.UUID.UUIDString;
    __strong NSString *profile;
    __strong NSString *url=@"";
    __strong NSString *title=@"New tab";
    __strong NSView *host;
    CefRefPtr<CefBrowser> browser;
    std::atomic<unsigned> blocked{0};
    bool creating=false;
    bool closing=false;
    bool loading=false,canGoBack=false,canGoForward=false;
    std::atomic<bool> blocking{true};
    int rendererPID=0;
    std::unordered_map<std::string,int> frameProcesses;
    uint64_t lastMemory=0;
    double lastCPU=0,lastResourceAt=0;
    uint64_t faviconGeneration=0;
};

@interface MallardController : NSObject <NSApplicationDelegate,NSWindowDelegate,NSTextFieldDelegate> {
@public
    std::vector<std::shared_ptr<Tab>> tabs;
    CefRefPtr<CefRequestContext> personalContext,schoolContext;
    std::shared_ptr<Tab> current;
    NSWindow *window;
    NSView *root,*sidebar,*toolbar,*webArea,*home;
    NSScrollView *tabsScroll;
    NSView *tabsDocument;
    NSTextField *address,*homeSearch,*status,*homeLabel,*noticeLabel,*resourceText;
    MallardTelemetry *telemetry;
    MallardBookmarkView *bookmarkView;
    MallardFavicons *favicons;
    NSTimeInterval lastCounterSave;
    MallardInput *addressInput,*homeInput;
    MallardButton *personalButton,*schoolButton,*vaultButton,*shieldButton,*backButton,*forwardButton,*reloadButton,*newTabButton,*updateButton;
    NSProgressIndicator *loading;
    NSString *profile;
    NSMutableDictionary *state;
    NSMutableDictionary<NSString *,NSString *> *selectedTabs;
    NSMutableArray<NSDictionary *> *closedTabs;
    NSMutableDictionary<NSString *,MallardTabRow *> *tabRows;
    NSString *notice,*lastNotice;
    NSTimeInterval noticeExpires;
    BOOL filterUpdateReady;
}
- (void)start;
- (void)layout;
- (void)refresh;
- (void)refreshChrome;
- (void)refreshStatus;
- (void)layoutTabs;
- (void)saveSession;
- (void)navigate:(NSString *)url;
- (void)newTabURL:(NSString *)url profile:(NSString *)target;
- (void)browserUpdated:(std::shared_ptr<Tab>)tab;
- (void)browserClosed:(std::shared_ptr<Tab>)tab;
- (void)quit:(id)sender;
- (void)alert:(NSString *)title detail:(NSString *)detail;
- (void)openOtherProfile:(NSString *)url;
- (void)selectProfile:(NSString *)name;
@end
static MallardController *Controller;

class FaviconDownload : public CefDownloadImageCallback {
public:
    FaviconDownload(std::shared_ptr<Tab> tab,uint64_t generation,NSString *page,std::vector<CefString> urls,size_t index)
        :tab_(tab),generation_(generation),page_(page),urls_(std::move(urls)),index_(index){}
    void OnDownloadImageFinished(const CefString&,int status,CefRefPtr<CefImage> image) override {
        auto tab=tab_.lock();
        if(!tab || Quitting || tab->closing || tab->faviconGeneration!=generation_ || ![MallardFaviconPage(tab->url) isEqual:page_])return;
        if(image && !image->IsEmpty() && (status==0 || (status>=200 && status<300))) {
            int width=0,height=0;auto png=image->GetAsPNG(2.0,true,width,height);
            if(png && png->GetSize()<=1024*1024){NSMutableData *data=[NSMutableData dataWithLength:png->GetSize()];png->GetData(data.mutableBytes,data.length,0);[Controller->favicons storePNG:data page:page_ profile:tab->profile];return;}
        }
        if(tab->browser && index_+1<urls_.size())tab->browser->GetHost()->DownloadImage(urls_[index_+1],true,16,false,new FaviconDownload(tab,generation_,page_,urls_,index_+1));
    }
private:
    std::weak_ptr<Tab> tab_;uint64_t generation_;__strong NSString *page_;std::vector<CefString> urls_;size_t index_;IMPLEMENT_REFCOUNTING(FaviconDownload);
};

class ReplacementResource : public CefResourceHandler {
public:
    explicit ReplacementResource(const std::string &uri) {
        size_t comma=uri.find(','); if(comma==std::string::npos)return;
        auto decoded=CefBase64Decode(uri.substr(comma+1)); if(decoded){data_.resize(decoded->GetSize());decoded->GetData(data_.data(),data_.size(),0);}
        mime_=uri.substr(5,uri.find(';')-5);
    }
    bool Open(CefRefPtr<CefRequest>,bool &handle,CefRefPtr<CefCallback>) override {handle=true;return true;}
    void GetResponseHeaders(CefRefPtr<CefResponse> response,int64_t &length,CefString&) override {response->SetStatus(200);response->SetMimeType(mime_);length=data_.size();}
    bool Read(void *output,int count,int &read,CefRefPtr<CefResourceReadCallback>) override {read=std::min(size_t(count),data_.size()-offset_);if(read)memcpy(output,data_.data()+offset_,read);offset_+=read;return read>0;}
    void Cancel() override {}
private: std::string data_,mime_; size_t offset_=0; IMPLEMENT_REFCOUNTING(ReplacementResource);
};
class ResourceFilter : public CefResourceRequestHandler {
public:
    ResourceFilter(std::shared_ptr<Tab> tab,std::string source):tab_(tab),source_(source){}
    cef_return_value_t OnBeforeResourceLoad(CefRefPtr<CefBrowser>,CefRefPtr<CefFrame>,CefRefPtr<CefRequest> request,CefRefPtr<CefCallback>) override {
        if(!BlockingReady || !tab_->blocking) return RV_CONTINUE;
        const char *kind="other";
        switch(request->GetResourceType()) {case RT_MAIN_FRAME:kind="document";break;case RT_SUB_FRAME:kind="subdocument";break;case RT_SCRIPT:kind="script";break;case RT_STYLESHEET:kind="stylesheet";break;case RT_IMAGE:kind="image";break;case RT_FONT_RESOURCE:kind="font";break;case RT_MEDIA:kind="media";break;case RT_XHR:kind="xmlhttprequest";break;case RT_PING:kind="ping";break;default:break;}
        char *raw=mb_request(request->GetURL().ToString().c_str(),source_.c_str(),kind,request->GetMethod().ToString().c_str()); auto value=CefParseJSON(raw,JSON_PARSER_RFC);mb_free(raw);
        if(!value || !value->GetDictionary())return RV_CONTINUE;auto result=value->GetDictionary();
        if(!result->GetBool("blocked"))return RV_CONTINUE;
        ++tab_->blocked;
        ++TotalBlocked;
        if(result->GetType("redirect")==VTYPE_STRING){replacement_=result->GetString("redirect");return RV_CONTINUE;}
        return RV_CANCEL;
    }
    CefRefPtr<CefResourceHandler> GetResourceHandler(CefRefPtr<CefBrowser>,CefRefPtr<CefFrame>,CefRefPtr<CefRequest>) override {return replacement_.empty()?nullptr:new ReplacementResource(replacement_);}
private: std::shared_ptr<Tab> tab_;std::string source_,replacement_;IMPLEMENT_REFCOUNTING(ResourceFilter);
};

class BrowserClient : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler, public CefLoadHandler, public CefDownloadHandler, public CefRequestHandler, public CefContextMenuHandler, public CefKeyboardHandler, public CefJSDialogHandler {
public:
    explicit BrowserClient(std::shared_ptr<Tab> tab):tab_(tab){}
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
    bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>,const CefString&,bool reload,CefRefPtr<CefJSDialogCallback> callback) override {
        BOOL leave=MallardRunDialog(Controller->window,reload?@"Reload this page?":@"Close this page?",@"The page reports unsaved changes.",@[],nil,@[],@[reload?@"Reload":@"Close",@"Stay on Page"],nil)==0;
        if(!leave){Quitting=NO;tab_->closing=false;[Controller selectProfile:tab_->profile];}
        callback->Continue(leave,CefString());return true;
    }
    bool OnPreKeyEvent(CefRefPtr<CefBrowser>,const CefKeyEvent &event,CefEventHandle,bool*) override {
        if(event.type!=KEYEVENT_RAWKEYDOWN && event.type!=KEYEVENT_KEYDOWN) return false;
        NSString *action=nil; bool command=event.modifiers&EVENTFLAG_COMMAND_DOWN,shift=event.modifiers&EVENTFLAG_SHIFT_DOWN;
        if(command) switch(event.windows_key_code) {
            case 'T':action=shift?@"reopen:":@"newTab:";break;case 'W':action=@"closeTab:";break;case 'L':action=@"focusAddress:";break;case 'K':action=@"palette:";break;case 'R':action=@"reload:";break;case 'F':action=(event.modifiers&EVENTFLAG_CONTROL_DOWN)?@"fullscreen:":@"find:";break;case 'D':action=@"bookmark:";break;case 'J':action=@"showDownloads:";break;case 'Y':action=@"showHistory:";break;case 'Q':action=@"quit:";break;
        }
        if((event.modifiers&EVENTFLAG_CONTROL_DOWN) && (event.modifiers&EVENTFLAG_ALT_DOWN)) {
            if(event.windows_key_code=='1')action=@"personal:";if(event.windows_key_code=='2')action=@"school:";
        }
        if(!action)return false;
        [Controller performSelector:NSSelectorFromString(action) withObject:nil afterDelay:0];return true;
    }
    bool OnProcessMessageReceived(CefRefPtr<CefBrowser>,CefRefPtr<CefFrame> frame,CefProcessId source,CefRefPtr<CefProcessMessage> message) override {
        if(source==PID_RENDERER && message->GetName()=="MallardRendererPID") {int pid=message->GetArgumentList()->GetInt(0);tab_->frameProcesses[frame->GetIdentifier()]=pid;if(frame->IsMain())tab_->rendererPID=pid;return true;}
        if(source==PID_RENDERER && message->GetName()=="MallardRendererGone") {auto found=tab_->frameProcesses.find(frame->GetIdentifier());if(found!=tab_->frameProcesses.end() && found->second==message->GetArgumentList()->GetInt(0))tab_->frameProcesses.erase(found);return true;}
        if(source==PID_RENDERER && message->GetName()=="MallardAutofillResult") {
            int count=message->GetArgumentList()->GetInt(0);
            if(Controller->current==tab_) { Controller->notice=count?[NSString stringWithFormat:@"Filled %d fields",count]:@"No supported fields found · embedded payment forms are not supported yet";[Controller refresh]; }
            return true;
        }
        if(source!=PID_RENDERER || message->GetName()!="MallardFilterDiagnostic") return false;
        if(!frame->IsMain())return true;
        auto args=message->GetArgumentList();
        NSDictionary *report=@{@"filtersLoaded":@(args->GetBool(0)),@"cosmeticScriptExecuted":@(args->GetBool(1)),@"initialCSSBytes":@(args->GetInt(2)),@"fixtureError":Text(args->GetString(3)),@"scriptletBytes":@(args->GetInt(4)),@"scriptletsExecuted":@(args->GetBool(5))};
        NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[DataDirectory stringByAppendingPathComponent:@"filter-diagnostic.json"] options:NSDataWritingAtomic error:nil];
        return true;
    }
    CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser>,CefRefPtr<CefFrame> frame,CefRefPtr<CefRequest>,bool,bool,const CefString &initiator,bool&) override {
        return new ResourceFilter(tab_,frame?frame->GetURL().ToString():initiator.ToString());
    }
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        tab_->browser=browser; tab_->creating=false; ++BrowserCount;
        browser->GetHost()->SetAccessibilityState(STATE_ENABLED);
        NSView *view=(__bridge NSView *)browser->GetHost()->GetWindowHandle();
        view.frame=tab_->host.bounds; view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        [Controller browserUpdated:tab_];
    }
    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        NSView *view=(__bridge NSView *)browser->GetHost()->GetWindowHandle();
        [view removeFromSuperview];
        return false;
    }
    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        tab_->browser=nullptr; --BrowserCount;
        [Controller browserClosed:tab_];
        if(Quitting && BrowserCount==0) { [Controller->telemetry stop];CefQuitMessageLoop(); }
    }
    bool OnBeforePopup(CefRefPtr<CefBrowser>,CefRefPtr<CefFrame>,int,const CefString& url,const CefString&,WindowOpenDisposition,bool gesture,const CefPopupFeatures&,CefWindowInfo&,CefRefPtr<CefClient>&,CefBrowserSettings&,CefRefPtr<CefDictionaryValue>&,bool*) override {
        if(gesture && !url.empty()) [Controller newTabURL:Text(url) profile:tab_->profile];
        return true;
    }
    void OnTitleChange(CefRefPtr<CefBrowser>,const CefString &title) override { tab_->title=Text(title); [Controller browserUpdated:tab_]; }
    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,const std::vector<CefString> &urls) override {
        NSString *page=MallardFaviconPage(tab_->url);if(!page || tab_->closing || Quitting)return;
        std::vector<CefString> candidates;for(auto &url:urls)if(MallardFaviconURLAllowed(Text(url)) && candidates.size()<4)candidates.push_back(url);
        uint64_t generation=++tab_->faviconGeneration;
        if(!candidates.empty())browser->GetHost()->DownloadImage(candidates.front(),true,16,false,new FaviconDownload(tab_,generation,page,candidates,0));
    }
    void OnAddressChange(CefRefPtr<CefBrowser>,CefRefPtr<CefFrame> frame,const CefString &url) override {
        if(!frame->IsMain()) return;
        if(![MallardFaviconPage(tab_->url) isEqual:MallardFaviconPage(Text(url))])++tab_->faviconGeneration;
        tab_->url=Text(url); [Controller browserUpdated:tab_]; [Controller saveSession];
    }
    void OnLoadingStateChange(CefRefPtr<CefBrowser>,bool isLoading,bool canGoBack,bool canGoForward) override {
        tab_->loading=isLoading;tab_->canGoBack=canGoBack;tab_->canGoForward=canGoForward;
        if(Controller->current==tab_) [Controller refreshChrome];
    }
    void OnLoadEnd(CefRefPtr<CefBrowser>,CefRefPtr<CefFrame> frame,int) override {
        if(frame->IsValid())frame->SendProcessMessage(PID_RENDERER,CefProcessMessage::Create("MallardReportRenderer"));
        if(!frame->IsMain()) return;
        NSMutableDictionary *p=Controller->state[tab_->profile];
        NSMutableArray *history=p[@"history"];
        if(tab_->url.length && ![history.lastObject[@"url"] isEqual:tab_->url]) {
            [history addObject:@{@"url":tab_->url,@"title":tab_->title,@"date":@([[NSDate date] timeIntervalSince1970])}];
            if(history.count>1000) [history removeObjectsInRange:NSMakeRange(0,history.count-1000)];
            [Controller saveSession];
        }
    }
    bool OnBeforeDownload(CefRefPtr<CefBrowser>,CefRefPtr<CefDownloadItem>,const CefString &name,CefRefPtr<CefBeforeDownloadCallback> cb) override {
        NSString *destination=[NSHomeDirectory() stringByAppendingPathComponent:[@"Downloads" stringByAppendingPathComponent:Text(name)]];
        cb->Continue(CefText(destination),true); return true;
    }
    void OnDownloadUpdated(CefRefPtr<CefBrowser>,CefRefPtr<CefDownloadItem> item,CefRefPtr<CefDownloadItemCallback>) override {
        if(item->IsCanceled()) Controller->notice=@"Download canceled";
        else if(item->IsComplete()) { Controller->notice=[@"Saved: " stringByAppendingString:Text(item->GetFullPath()).lastPathComponent];
            NSMutableArray *downloads=Controller->state[tab_->profile][@"downloads"]; [downloads addObject:@{@"path":Text(item->GetFullPath()),@"name":Text(item->GetFullPath()).lastPathComponent}]; [Controller saveSession]; }
        else Controller->notice=[NSString stringWithFormat:@"Downloading: %d%%",item->GetPercentComplete()];
        [Controller refresh];
    }
    bool OnOpenURLFromTab(CefRefPtr<CefBrowser>,CefRefPtr<CefFrame>,const CefString &url,WindowOpenDisposition,bool gesture) override {
        if(gesture)[Controller newTabURL:Text(url) profile:tab_->profile]; return true;
    }
    void OnBeforeContextMenu(CefRefPtr<CefBrowser>,CefRefPtr<CefFrame>,CefRefPtr<CefContextMenuParams> params,CefRefPtr<CefMenuModel> model) override {
        if(!params->GetLinkUrl().empty()) { model->AddSeparator(); model->AddItem(26501,[tab_->profile isEqual:@"personal"]?"Open link in School":"Open link in Personal"); }
    }
    bool OnContextMenuCommand(CefRefPtr<CefBrowser>,CefRefPtr<CefFrame>,CefRefPtr<CefContextMenuParams> params,int command,EventFlags) override {
        if(command==26501) { [Controller openOtherProfile:Text(params->GetLinkUrl())]; return true; } return false;
    }
private:
    std::shared_ptr<Tab> tab_;
    IMPLEMENT_REFCOUNTING(BrowserClient);
};

static NSTextField *Label(NSString *text,CGFloat size,NSColor *color) {
    NSTextField *field=[NSTextField labelWithString:text]; field.font=Mono(size); field.textColor=color; field.lineBreakMode=NSLineBreakByTruncatingTail; return field;
}
static MallardButton *Button(NSString *title,id target,SEL action) {
    MallardButton *b=[MallardButton new]; b.title=title; b.target=target; b.action=action; return b;
}
static void SetIcon(NSButton *button,NSString *symbol,NSString *label) {
    button.image=[[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label] imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular]];
    button.toolTip=label; [button setAccessibilityLabel:label];
}
static MallardButton *Icon(NSString *symbol,NSString *label,id target,SEL action) {
    MallardButton *b=Button(@"",target,action); SetIcon(b,symbol,label); return b;
}
static void FillBackground(NSView *view,NSColor *color) { view.wantsLayer=YES; view.layer.backgroundColor=color.CGColor; }

@implementation MallardController
- (void)start {
    selectedTabs=[NSMutableDictionary dictionary]; closedTabs=[NSMutableArray array]; tabRows=[NSMutableDictionary dictionary]; notice=@""; lastNotice=@"";
    NSString *saved=[DataDirectory stringByAppendingPathComponent:@"session.json"];
    NSData *data=[NSData dataWithContentsOfFile:saved];
    state=data?[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil]:nil;
    if(![state isKindOfClass:NSMutableDictionary.class]) state=[NSMutableDictionary dictionary];
    TotalBlocked=[state[@"totalBlocked"] unsignedLongLongValue];telemetry=[MallardTelemetry new];
    for(NSString *name in @[@"personal",@"school"]) {
        if(![state[name] isKindOfClass:NSMutableDictionary.class]) state[name]=[NSMutableDictionary dictionary];
        for(NSString *key in @[@"history",@"bookmarks",@"downloads"]) if(![state[name][key] isKindOfClass:NSMutableArray.class]) state[name][key]=[NSMutableArray array];
        state[name][@"bookmarks"]=MallardBookmarkTree(state[name][@"bookmarks"]);
    }
    favicons=[[MallardFavicons alloc] initWithDirectory:DataDirectory];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(faviconChanged:) name:MallardFaviconChanged object:favicons];
    for(NSString *name in @[@"personal",@"school"])[favicons primeBookmarks:state[name][@"bookmarks"] profile:name];
    profile=[state[@"activeProfile"] isEqual:@"school"]?@"school":@"personal";
    for(NSString *name in @[@"personal",@"school"]) {
        CefRequestContextSettings settings;
        CefString(&settings.cache_path)=CefText([DataDirectory stringByAppendingPathComponent:[@"Profiles" stringByAppendingPathComponent:name]]);
        settings.persist_session_cookies=true;
        auto ctx=CefRequestContext::CreateContext(settings,nullptr);
        if([name isEqual:@"personal"]) personalContext=ctx; else schoolContext=ctx;
    }
    window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,1160,760) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    window.delegate=self; window.title=@"Mallard"; window.titlebarAppearsTransparent=YES; window.backgroundColor=Color(.06); window.minSize=NSMakeSize(740,480); window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    window.autorecalculatesKeyViewLoop=YES;
    root=[[MallardView alloc] initWithFrame:window.contentView.bounds]; root.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; window.contentView=root; FillBackground(root,Color(.02));
    sidebar=[MallardView new]; FillBackground(sidebar,Color(.045)); [root addSubview:sidebar];
    personalButton=Button(@"Personal",self,@selector(changeProfile:)); personalButton.tag=0; [sidebar addSubview:personalButton];
    schoolButton=Button(@"School",self,@selector(changeProfile:)); schoolButton.tag=1; [sidebar addSubview:schoolButton];
    NSTextField *tabsLabel=Label(@"tabs",11,Color(.5)); tabsLabel.frame=NSMakeRect(20,74,140,18); [sidebar addSubview:tabsLabel];
    tabsScroll=[NSScrollView new];tabsScroll.hasVerticalScroller=YES;tabsScroll.autohidesScrollers=YES;tabsScroll.drawsBackground=YES;tabsScroll.backgroundColor=Color(.045);tabsScroll.borderType=NSNoBorder;
    tabsDocument=[MallardView new];tabsDocument.autoresizingMask=NSViewWidthSizable;tabsScroll.documentView=tabsDocument;[sidebar addSubview:tabsScroll];
    newTabButton=Button(@"+ new tab",self,@selector(newTab:));newTabButton.leftAligned=YES;[tabsDocument addSubview:newTabButton];
    bookmarkView=[MallardBookmarkView new];bookmarkView.favicons=favicons;__weak MallardController *weakSelf=self;
    bookmarkView.openURL=^(NSString *url){[weakSelf navigate:url];};bookmarkView.changed=^{[weakSelf saveSession];};bookmarkView.importRequested=^{[weakSelf importBookmarks:nil];};[sidebar addSubview:bookmarkView];
    toolbar=[MallardView new]; FillBackground(toolbar,Color(.065)); [root addSubview:toolbar];
    backButton=Icon(@"chevron.left",@"Back",self,@selector(goBack:));forwardButton=Icon(@"chevron.right",@"Forward",self,@selector(goForward:));reloadButton=Icon(@"arrow.clockwise",@"Reload",self,@selector(stopOrReload:));
    NSInteger navigationIndex=0;for(NSButton *b in @[backButton,forwardButton,reloadButton]) { b.frame=NSMakeRect(8+navigationIndex++*29,12,28,28); [toolbar addSubview:b]; }
    addressInput=[[MallardInput alloc] initWithFontSize:12 secure:NO]; addressInput.trailingInset=24;address=addressInput.field;
    address.placeholderAttributedString=[[NSAttributedString alloc] initWithString:@"Search or enter address" attributes:@{NSFontAttributeName:Mono(12),NSForegroundColorAttributeName:Color(.55)}]; address.target=self; address.action=@selector(addressEntered:); address.delegate=self; [address setAccessibilityLabel:@"Address"]; [toolbar addSubview:addressInput];
    vaultButton=Icon(@"key.horizontal",@"Passwords and cards",self,@selector(showVault:)); [toolbar addSubview:vaultButton];
    shieldButton=Icon(@"shield",@"Ad blocking",self,@selector(showProtection:)); [toolbar addSubview:shieldButton];
    NSButton *menu=Icon(@"ellipsis",@"Browser menu",self,@selector(showMore:)); menu.tag=44; [toolbar addSubview:menu];
    loading=[[NSProgressIndicator alloc] initWithFrame:NSZeroRect]; loading.style=NSProgressIndicatorStyleSpinning; loading.controlSize=NSControlSizeSmall; loading.displayedWhenStopped=NO; [toolbar addSubview:loading];
    webArea=[MallardView new]; FillBackground(webArea,Color(.02)); [root addSubview:webArea];
    home=[MallardView new]; FillBackground(home,Color(.02)); [webArea addSubview:home];
    homeLabel=Label(@"personal / new tab",12,Color(.55)); [home addSubview:homeLabel];
    homeInput=[[MallardInput alloc] initWithFontSize:16 secure:NO];homeInput.minimal=YES;homeInput.prompt=@">";homeSearch=homeInput.field;
    homeSearch.placeholderAttributedString=[[NSAttributedString alloc] initWithString:@"Search or enter address" attributes:@{NSFontAttributeName:Mono(16),NSForegroundColorAttributeName:Color(.68)}]; homeSearch.target=self; homeSearch.action=@selector(addressEntered:); [homeSearch setAccessibilityLabel:@"Search with Brave"]; [home addSubview:homeInput];
    NSTextField *keys=Label(@"⌘L address    ⌘T new tab    ⌘K find tab",11,Color(.52)); keys.tag=3; [home addSubview:keys];
    status=Label(@"Mallard · development build",11,Color(.55)); [root addSubview:status];
    noticeLabel=Label(@"",11,Color(.65));[root addSubview:noticeLabel];
    resourceText=Label(@"Reading app usage...",10,Color(.60));resourceText.alignment=NSTextAlignmentRight;[resourceText setAccessibilityLabel:@"Mallard resource usage"];[root addSubview:resourceText];
    updateButton=Button(@"Update ready",self,@selector(showFilterUpdate:));updateButton.font=Mono(10);updateButton.hidden=YES;[root addSubview:updateButton];
    [self buildMenu];
    NSArray *storedTabs=[state[@"tabs"] isKindOfClass:NSArray.class]?state[@"tabs"]:@[];
    for(NSDictionary *entry in storedTabs) {
        if(![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *p=[entry[@"profile"] isEqual:@"school"]?@"school":@"personal";
        NSString *url=[entry[@"url"] isKindOfClass:NSString.class]?entry[@"url"]:@"";
        if(url.length && !MallardOrigin(url))url=@"";
        auto tab=std::make_shared<Tab>(); tab->profile=p; tab->url=url; tab->title=[entry[@"title"] isKindOfClass:NSString.class]?entry[@"title"]:@"New tab";
        tab->blocked=[entry[@"blocked"] unsignedIntValue];
        tab->host=[NSView new]; tab->host.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; [webArea addSubview:tab->host]; tab->host.hidden=YES; tabs.push_back(tab);
        if([entry[@"selected"] boolValue]) selectedTabs[p]=tab->identifier;
    }
    for(NSString *p in @[@"personal",@"school"]) {
        bool has=false; for(auto &t:tabs) if([t->profile isEqual:p]) has=true;
        if(!has) { auto t=std::make_shared<Tab>(); t->profile=p; t->host=[NSView new]; t->host.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; [webArea addSubview:t->host]; t->host.hidden=YES; tabs.push_back(t); }
    }
    [self selectProfile:profile]; [self layout]; [window center]; [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(statusTick:) userInfo:nil repeats:YES];
    [MallardFilterUpdater check:FilterDirectory dataDirectory:DataDirectory completion:^(BOOL updated){if(updated){filterUpdateReady=YES;[self layout];[self refreshStatus];}}];
}
- (void)buildMenu {
    NSMenu *bar=[NSMenu new];
    auto addMenu=[&](NSString *name)->NSMenu* { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:name action:nil keyEquivalent:@""]; NSMenu *menu=[[NSMenu alloc] initWithTitle:name]; item.submenu=menu; [bar addItem:item]; return menu; };
    auto add=[&](NSMenu *m,NSString *title,SEL action,NSString *key,NSEventModifierFlags modifiers){ NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key]; item.target=self; item.keyEquivalentModifierMask=modifiers; [m addItem:item]; };
    NSMenu *app=addMenu(@"Mallard"); add(app,@"About Mallard",@selector(about:),@"",0); add(app,@"Settings…",@selector(settings:),@",",NSEventModifierFlagCommand); [app addItem:NSMenuItem.separatorItem]; add(app,@"Quit Mallard",@selector(quit:),@"q",NSEventModifierFlagCommand);
    NSMenu *file=addMenu(@"File"); add(file,@"New Tab",@selector(newTab:),@"t",NSEventModifierFlagCommand); add(file,@"Close Tab",@selector(closeTab:),@"w",NSEventModifierFlagCommand); add(file,@"Reopen Closed Tab",@selector(reopen:),@"t",NSEventModifierFlagCommand|NSEventModifierFlagShift); [file addItem:NSMenuItem.separatorItem]; add(file,@"Import Chrome Passwords…",@selector(importPasswords:),@"i",NSEventModifierFlagCommand|NSEventModifierFlagShift);
    NSMenu *edit=addMenu(@"Edit"); for(NSArray *entry in @[@[@"Undo",@"undo:",@"z"],@[@"Cut",@"cut:",@"x"],@[@"Copy",@"copy:",@"c"],@[@"Paste",@"paste:",@"v"],@[@"Select All",@"selectAll:",@"a"]]) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:entry[2]]; [edit addItem:item]; }
    NSMenu *view=addMenu(@"View"); add(view,@"Focus Address",@selector(focusAddress:),@"l",NSEventModifierFlagCommand); add(view,@"Find Tab or Search…",@selector(palette:),@"k",NSEventModifierFlagCommand); add(view,@"Find in Page…",@selector(find:),@"f",NSEventModifierFlagCommand); add(view,@"Reload",@selector(reload:),@"r",NSEventModifierFlagCommand); add(view,@"Zoom In",@selector(zoomIn:),@"+",NSEventModifierFlagCommand); add(view,@"Zoom Out",@selector(zoomOut:),@"-",NSEventModifierFlagCommand); add(view,@"Actual Size",@selector(zoomReset:),@"0",NSEventModifierFlagCommand); add(view,@"Toggle Full Screen",@selector(fullscreen:),@"f",NSEventModifierFlagCommand|NSEventModifierFlagControl);
    NSMenu *history=addMenu(@"History"); add(history,@"Show History",@selector(showHistory:),@"y",NSEventModifierFlagCommand); add(history,@"Downloads",@selector(showDownloads:),@"j",NSEventModifierFlagCommand);
    NSMenu *bookmarks=addMenu(@"Bookmarks"); add(bookmarks,@"Bookmark This Page",@selector(bookmark:),@"d",NSEventModifierFlagCommand); add(bookmarks,@"Show Bookmarks",@selector(showBookmarks:),@"",0);add(bookmarks,@"New Folder...",@selector(newBookmarkFolder:),@"",0);add(bookmarks,@"Import Chrome Bookmarks...",@selector(importBookmarks:),@"",0);
    NSMenu *profiles=addMenu(@"Profiles"); add(profiles,@"Personal",@selector(personal:),@"1",NSEventModifierFlagControl|NSEventModifierFlagOption); add(profiles,@"School",@selector(school:),@"2",NSEventModifierFlagControl|NSEventModifierFlagOption);
    NSMenu *developer=addMenu(@"Developer");add(developer,@"Test Synthetic Password Fill",@selector(testPasswordFill:),@"",0);add(developer,@"Test Synthetic Card Fill",@selector(testCardFill:),@"",0);
    NSApp.mainMenu=bar;
}
- (void)layout {
    CGFloat w=root.bounds.size.width,h=root.bounds.size.height,s=210,top=53,bottom=w<1100?46:25;
    sidebar.frame=NSMakeRect(0,0,s,h-bottom); toolbar.frame=NSMakeRect(s,0,w-s,top); webArea.frame=NSMakeRect(s,top,w-s,h-top-bottom); status.frame=NSMakeRect(15,h-bottom+4,310,18);
    CGFloat metricsWidth=MIN(w-30,MAX(600,[resourceText.stringValue sizeWithAttributes:@{NSFontAttributeName:resourceText.font}].width+8));
    resourceText.frame=NSMakeRect(w-metricsWidth-15,h-21,metricsWidth,18);
    CGFloat noticeEnd=bottom>25?w-130:w-metricsWidth-25;
    updateButton.frame=NSMakeRect(w-120,h-bottom+2,108,21);updateButton.hidden=!filterUpdateReady || bottom==25;
    noticeLabel.frame=NSMakeRect(327,h-bottom+4,MAX(0,noticeEnd-327),18);
    personalButton.frame=NSMakeRect(12,16,90,30); schoolButton.frame=NSMakeRect(108,16,90,30);
    CGFloat bookmarkHeight=MIN(260,MAX(130,(h-bottom-96)*.40));
    tabsScroll.frame=NSMakeRect(0,96,s,MAX(100,h-bottom-96-bookmarkHeight));
    bookmarkView.frame=NSMakeRect(0,NSMaxY(tabsScroll.frame),s,bookmarkHeight);
    [self layoutTabs];
    CGFloat tw=toolbar.bounds.size.width;
    addressInput.frame=NSMakeRect(102,12,tw-227,28); vaultButton.frame=NSMakeRect(tw-117,12,30,28); shieldButton.frame=NSMakeRect(tw-80,12,30,28); [toolbar viewWithTag:44].frame=NSMakeRect(tw-43,12,30,28); loading.frame=NSMakeRect(NSMaxX(addressInput.frame)-25,18,16,16);
    home.frame=webArea.bounds;
    CGFloat width=MIN(470,webArea.bounds.size.width-65),left=(webArea.bounds.size.width-width)/2,y=MAX(70,(webArea.bounds.size.height-150)/2);
    homeLabel.frame=NSMakeRect(left,y-40,width,18);homeInput.frame=NSMakeRect(left,y,width,44);[home viewWithTag:3].frame=NSMakeRect(left,y+67,width,24);
    for(auto &tab:tabs) tab->host.frame=webArea.bounds;
}
- (void)layoutTabs {
    NSInteger count=0;for(auto &tab:tabs)if([tab->profile isEqual:profile] && !tab->closing)++count;
    CGFloat height=MAX(count*38+46,tabsScroll.contentSize.height);
    NSPoint origin=tabsScroll.contentView.bounds.origin;
    tabsDocument.frame=NSMakeRect(0,0,tabsScroll.contentSize.width,height);
    [tabsScroll tile];
    tabsDocument.frame=NSMakeRect(0,0,tabsScroll.contentSize.width,height);
    NSInteger index=0;
    CGFloat rowWidth=MAX(0,tabsScroll.contentSize.width-24);
    for(auto &tab:tabs) {
        MallardTabRow *row=tabRows[tab->identifier];row.hidden=![tab->profile isEqual:profile] || tab->closing;
        if(![tab->profile isEqual:profile] || tab->closing)continue;
        row.frame=NSMakeRect(12,index++*38,rowWidth,34);
    }
    newTabButton.frame=NSMakeRect(12,index*38+8,rowWidth,30);
    origin.y=MIN(MAX(0,origin.y),MAX(0,height-tabsScroll.contentSize.height));origin.x=0;
    [tabsScroll.contentView scrollToPoint:origin];[tabsScroll reflectScrolledClipView:tabsScroll.contentView];
}
- (void)windowDidResize:(NSNotification *)notification { [self layout]; }
- (void)refresh {
    NSMutableSet *live=[NSMutableSet set];
    for(auto &tab:tabs) {
        if(tab->closing)continue;[live addObject:tab->identifier];
        MallardTabRow *row=tabRows[tab->identifier];
        if(!row) {
            row=[MallardTabRow new];tabRows[tab->identifier]=row;[tabsDocument addSubview:row];
            row.selectButton.target=self;row.selectButton.action=@selector(selectTab:);row.selectButton.identifier=tab->identifier;
            row.closeButton.target=self;row.closeButton.action=@selector(closeTabButton:);row.closeButton.identifier=tab->identifier;
            [row.selectButton setAccessibilityRole:NSAccessibilityRadioButtonRole];
        }
        row.selectButton.title=tab->title.length?tab->title:@"New tab";row.selectButton.chosen=current==tab;
        row.selectButton.leadingImage=[favicons imageForPage:tab->url profile:tab->profile]?:MallardSiteSymbol(NO);
        row.selectButton.toolTip=row.selectButton.title;[row.selectButton setAccessibilityLabel:row.selectButton.title];
        row.closeButton.toolTip=[@"Close " stringByAppendingString:row.selectButton.title];
    }
    for(NSString *identifier in tabRows.allKeys)if(![live containsObject:identifier]){[tabRows[identifier] removeFromSuperview];[tabRows removeObjectForKey:identifier];}
    [self layoutTabs];
    personalButton.chosen=[profile isEqual:@"personal"];schoolButton.chosen=[profile isEqual:@"school"];
    bookmarkView.profile=profile;bookmarkView.items=state[profile][@"bookmarks"];
    [personalButton setAccessibilityRole:NSAccessibilityRadioButtonRole];[schoolButton setAccessibilityRole:NSAccessibilityRadioButtonRole];
    window.title=[NSString stringWithFormat:@"Mallard - %@",profile.capitalizedString]; homeLabel.stringValue=[profile stringByAppendingString:@" / new tab"];
    if(current) {
        if(window.firstResponder!=address.currentEditor) address.stringValue=current->url;
        home.hidden=current->url.length>0;
    }
    [self refreshChrome];[self refreshStatus];
}
- (void)faviconChanged:(NSNotification *)notification {
    for(auto &tab:tabs)if([tab->profile isEqual:notification.userInfo[@"profile"]] && [MallardFaviconPage(tab->url) isEqual:notification.userInfo[@"page"]])
        tabRows[tab->identifier].selectButton.leadingImage=[favicons imageForPage:tab->url profile:tab->profile]?:MallardSiteSymbol(NO);
}
- (void)statusTick:(NSTimer *)timer {
    if(Quitting)return;[telemetry sample];NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    [self refreshStatus];if(now-lastCounterSave>15){lastCounterSave=now;[self saveSession];}
}
- (void)refreshChrome {
    BOOL hasPage=current && current->browser;
    backButton.enabled=hasPage && current->canGoBack;forwardButton.enabled=hasPage && current->canGoForward;reloadButton.enabled=hasPage;
    BOOL busy=current && current->loading;
    SetIcon(reloadButton,busy?@"xmark":@"arrow.clockwise",busy?@"Stop loading":@"Reload");
    for(NSButton *button in @[backButton,forwardButton,reloadButton]){button.contentTintColor=Color(button.enabled?.82:.28);button.needsDisplay=YES;}
    if(busy)[loading startAnimation:nil];else[loading stopAnimation:nil];
    BOOL paused=current && !current->blocking;
    NSString *symbol=!BlockingReady?@"exclamationmark.shield":paused?@"shield.slash":@"shield";
    NSString *label=!BlockingReady?@"Ad blocking unavailable":paused?@"Ad blocking paused for this tab":@"Ad blocking on";
    SetIcon(shieldButton,symbol,label);shieldButton.contentTintColor=(!BlockingReady||paused)?[NSColor colorWithRed:.90 green:.65 blue:.28 alpha:1]:Color(.85);shieldButton.needsDisplay=YES;
}
- (void)refreshStatus {
    if(!current)return;
    status.stringValue=[NSString stringWithFormat:@"%@ · %u blocked · %llu total",profile,current->blocked.load(),(unsigned long long)TotalBlocked.load()];
    status.toolTip=[NSString stringWithFormat:@"Current tab / all-time Mallard total. %@%@",!BlockingReady?@"Blocking unavailable.":!current->blocking?@"Blocking paused for this tab.":@"Blocking on.",filterUpdateReady?@" New filters apply on the next launch.":@""];
    std::set<int> pids;for(auto &entry:current->frameProcesses)pids.insert(entry.second);if(current->rendererPID)pids.insert(current->rendererPID);
    uint64_t memory=0;double cpu=0;BOOL hasUsage=NO,shared=NO;
    for(int pid:pids){NSDictionary *usage=telemetry.processes[@(pid)];if(usage){hasUsage=YES;memory+=[usage[@"memory"] unsignedLongLongValue];cpu+=[usage[@"cpu"] doubleValue];}for(auto &tab:tabs)if(tab!=current){if(tab->rendererPID==pid)shared=YES;for(auto &entry:tab->frameProcesses)if(entry.second==pid)shared=YES;}}
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(hasUsage){current->lastMemory=memory;current->lastCPU=cpu;current->lastResourceAt=now;}
    BOOL recent=!hasUsage && current->lastResourceAt>0 && now-current->lastResourceAt<4;
    NSString *tabMemory=hasUsage?MallardBytes(memory):recent?[@"~" stringByAppendingString:MallardBytes(current->lastMemory)]:current->url.length?@"...":@"0 B";
    NSString *tabCPU=(hasUsage||recent)?[NSString stringWithFormat:@"%.1f%%",hasUsage?cpu:current->lastCPU]:current->url.length?@"...":@"0.0%";
    NSString *appDown=telemetry.networkReady?MallardRate(telemetry.downloadRate):@"...",*appUp=telemetry.networkReady?MallardRate(telemetry.uploadRate):@"...";
    resourceText.stringValue=[NSString stringWithFormat:@"RAM %@%@ / %@   CPU %@ / %.1f%%   NET ↓%@ ↑%@",tabMemory,shared?@"*":@"",MallardBytes(telemetry.memory),tabCPU,telemetry.cpu,appDown,appUp];
    resourceText.toolTip=[NSString stringWithFormat:@"Memory and CPU pairs are tab / Mallard. CPU is a percentage of the whole Mac's capacity. App totals include %lu Mallard processes, including the resource meter's helper.\n\nTab memory/CPU cover its frame renderers%@. A tilde means the last sample is being held briefly while a renderer changes. Shared workers and browser services are included in the app total.\n\nNetwork is all Mallard socket traffic in megabits per second (Mbps). Transferred since monitoring began: ↓%@ ↑%@.",(unsigned long)telemetry.processes.count,shared?@", including a process shared with another tab":@"",MallardBytes(telemetry.downloaded),MallardBytes(telemetry.uploaded)];
    if(![notice isEqual:lastNotice]){lastNotice=[notice copy];noticeExpires=NSDate.timeIntervalSinceReferenceDate+8;}
    if(notice.length && NSDate.timeIntervalSinceReferenceDate>=noticeExpires){notice=@"";lastNotice=@"";}
    noticeLabel.stringValue=notice?:@"";noticeLabel.toolTip=notice.length?notice:nil;
}
- (void)showFilterUpdate:(id)sender { [self alert:@"Ad filters are ready" detail:@"The updated filters will load the next time you open Mallard. Your tabs are saved when you quit."]; }
- (void)selectProfile:(NSString *)name {
    if(current) selectedTabs[profile]=current->identifier;
    profile=name; current.reset();
    for(auto &tab:tabs) if([tab->profile isEqual:name] && !tab->closing && (!current || [selectedTabs[name] isEqual:tab->identifier])) current=tab;
    if(!current) { [self newTabURL:@"" profile:name]; return; }
    [self activateCurrent];
}
- (void)activateCurrent {
    selectedTabs[profile]=current->identifier;
    for(auto &tab:tabs) { BOOL hidden=(tab!=current || !tab->url.length); tab->host.hidden=hidden; if(tab->browser) { NSView *native=(__bridge NSView *)tab->browser->GetHost()->GetWindowHandle(); native.hidden=hidden; } }
    if(current->browser) {
        NSView *native=(__bridge NSView *)current->browser->GetHost()->GetWindowHandle();
        native.hidden=NO;
        native.frame=current->host.bounds;
        [native setNeedsDisplay:YES];
        current->browser->GetHost()->NotifyMoveOrResizeStarted();
        current->browser->GetHost()->SetAccessibilityState(STATE_ENABLED);
    }
    if(current->url.length && !current->browser && !current->creating) {
        current->creating=true; current->host.frame=webArea.bounds;
        CefWindowInfo info; info.SetAsChild((__bridge CefWindowHandle)current->host,CefRect(0,0,webArea.bounds.size.width,webArea.bounds.size.height)); info.runtime_style=CEF_RUNTIME_STYLE_ALLOY;
        CefBrowserSettings settings; settings.background_color=CefColorSetARGB(255,5,5,5);
        if(!CefBrowserHost::CreateBrowser(info,new BrowserClient(current),CefText(current->url),settings,nullptr,[profile isEqual:@"personal"]?personalContext:schoolContext)) { current->creating=false; [self alert:@"Couldn't create this tab" detail:@"Chromium did not accept the browser view request."]; }
    }
    [self refresh]; [self saveSession];
    MallardTabRow *selectedRow=tabRows[current->identifier];[selectedRow scrollRectToVisible:selectedRow.bounds];
    if(!current->url.length) [window makeFirstResponder:homeSearch]; else if(current->browser) current->browser->GetHost()->SetFocus(true);
}
- (void)selectTab:(NSButton *)sender { for(auto &tab:tabs) if([tab->identifier isEqual:sender.identifier]) { current=tab; notice=@""; [self activateCurrent]; break; } }
- (void)changeProfile:(NSButton *)sender { [self selectProfile:sender.tag?@"school":@"personal"]; }
- (void)personal:(id)sender { [self selectProfile:@"personal"]; }
- (void)school:(id)sender { [self selectProfile:@"school"]; }
- (void)newTabURL:(NSString *)url profile:(NSString *)target {
    if(url.length && !MallardOrigin(url)){notice=@"This link type is not supported";[self refresh];return;}
    auto tab=std::make_shared<Tab>(); tab->profile=target; tab->url=url; tab->host=[NSView new]; tab->host.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; [webArea addSubview:tab->host]; tabs.push_back(tab);
    if(current) selectedTabs[profile]=current->identifier;
    profile=target; current=tab; notice=@""; [self activateCurrent];
}
- (void)newTab:(id)sender { [self newTabURL:@"" profile:profile]; }
- (void)navigate:(NSString *)url {
    if(!url.length || !MallardOrigin(url)) return;
    current->url=url; current->title=[NSURLComponents componentsWithString:url].host ?: url; notice=@"";
    if(current->browser) current->browser->GetMainFrame()->LoadURL(CefText(url));
    [self activateCurrent];
}
- (void)addressEntered:(NSTextField *)sender { [self navigate:MallardURL(sender.stringValue)]; homeSearch.stringValue=@""; }
- (void)focusAddress:(id)sender { [window makeFirstResponder:address]; [address selectText:nil]; }
- (void)goBack:(id)sender { if(current->browser) current->browser->GoBack(); }
- (void)goForward:(id)sender { if(current->browser) current->browser->GoForward(); }
- (void)reload:(id)sender { if(current->browser) current->browser->Reload(); }
- (void)stopOrReload:(id)sender { if(current && current->browser){if(current->loading)current->browser->StopLoad();else current->browser->Reload();} }
- (void)zoomIn:(id)sender { if(current->browser) current->browser->GetHost()->SetZoomLevel(current->browser->GetHost()->GetZoomLevel()+.5); }
- (void)zoomOut:(id)sender { if(current->browser) current->browser->GetHost()->SetZoomLevel(current->browser->GetHost()->GetZoomLevel()-.5); }
- (void)zoomReset:(id)sender { if(current->browser) current->browser->GetHost()->SetZoomLevel(0); }
- (void)fullscreen:(id)sender { [window toggleFullScreen:nil]; }
- (void)browserUpdated:(std::shared_ptr<Tab>)tab { if(!Quitting) { [self layout]; [self refresh]; } }
- (void)close:(std::shared_ptr<Tab>)tab {
    if(tab->closing) return;
    [closedTabs addObject:@{@"url":tab->url,@"profile":tab->profile}]; if(closedTabs.count>100)[closedTabs removeObjectAtIndex:0];tab->closing=true;
    if(tab->browser) tab->browser->GetHost()->CloseBrowser(false);
    else [self browserClosed:tab];
}
- (void)closeTab:(id)sender { if(current) [self close:current]; }
- (void)closeTabButton:(NSButton *)sender { for(auto &tab:tabs) if([tab->identifier isEqual:sender.identifier]) { [self close:tab]; break; } }
- (void)browserClosed:(std::shared_ptr<Tab>)tab {
    [tab->host removeFromSuperview];
    tabs.erase(std::remove(tabs.begin(),tabs.end(),tab),tabs.end());
    if(Quitting) { [closedTabs addObject:@{@"url":tab->url,@"profile":tab->profile}];return; }
    if(current==tab) { current.reset(); [self selectProfile:profile]; } else [self refresh];
    [self saveSession];
}
- (void)reopen:(id)sender { for(NSInteger i=closedTabs.count-1;i>=0;i--) { NSDictionary *entry=closedTabs[i];if([entry[@"profile"] isEqual:profile]){[closedTabs removeObjectAtIndex:i];[self newTabURL:entry[@"url"] profile:profile];return;} } }
- (void)openOtherProfile:(NSString *)url { [self newTabURL:url profile:[profile isEqual:@"personal"]?@"school":@"personal"]; }
- (void)saveSession {
    if(Quitting) return;
    NSMutableArray *saved=[NSMutableArray array];
    for(auto &t:tabs) if(!t->closing) [saved addObject:@{@"url":t->url,@"title":t->title,@"profile":t->profile,@"blocked":@(t->blocked.load()),@"selected":@(t==current || [selectedTabs[t->profile] isEqual:t->identifier])}];
    state[@"totalBlocked"]=@(TotalBlocked.load());
    state[@"tabs"]=saved; state[@"activeProfile"]=profile?:@"personal";
    NSData *data=[NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    NSString *path=[DataDirectory stringByAppendingPathComponent:@"session.json"];
    [data writeToFile:path options:NSDataWritingAtomic error:nil]; [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];
}
- (void)alert:(NSString *)title detail:(NSString *)detail { MallardRunDialog(window,title,detail,@[],nil,@[],@[@"OK"],nil); }
- (NSString *)prompt:(NSString *)title value:(NSString *)value {
    NSArray *values=nil;return MallardRunDialog(window,title,@"",@[@""],nil,@[value?:@""],@[@"Open",@"Cancel"],&values)==0?values.firstObject:nil;
}
- (void)palette:(id)sender { NSString *text=[self prompt:@"Find a tab or search with Brave" value:@""]; if(!text.length) return; for(auto &t:tabs) if([t->profile isEqual:profile] && ([t->title localizedCaseInsensitiveContainsString:text] || [t->url localizedCaseInsensitiveContainsString:text])) { current=t; [self activateCurrent]; return; } [self navigate:MallardURL(text)]; }
- (void)find:(id)sender { NSString *text=[self prompt:@"Find in this page" value:@""]; if(text.length && current->browser) current->browser->GetHost()->Find(CefText(text),true,false,false); }
- (void)bookmark:(id)sender { if(!current->url.length) return;[bookmarkView addURL:current->url title:current->title];notice=@"Bookmark saved";[self refresh]; }
- (void)openSaved:(NSMenuItem *)sender { [self navigate:sender.representedObject]; }
- (void)showList:(NSArray *)list title:(NSString *)title {
    NSMenu *menu=[[NSMenu alloc] initWithTitle:title];
    for(NSDictionary *entry in [list reverseObjectEnumerator]) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:entry[@"title"]?:entry[@"url"] action:@selector(openSaved:) keyEquivalent:@""]; item.target=self; item.representedObject=entry[@"url"]; [menu addItem:item]; if(menu.numberOfItems>=40) break; }
    if(!menu.numberOfItems) [menu addItemWithTitle:@"Nothing saved yet" action:nil keyEquivalent:@""];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(12,92) inView:sidebar];
}
- (void)showBookmarks:(id)sender { [bookmarkView focusBookmarks]; }
- (void)newBookmarkFolder:(id)sender { [bookmarkView newFolder:sender]; }
- (void)importBookmarks:(id)sender {
    NSString *rootPath=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Google/Chrome"];
    NSData *data=[NSData dataWithContentsOfFile:[rootPath stringByAppendingPathComponent:@"Local State"]];NSDictionary *local=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;NSDictionary *profiles=local[@"profile"][@"info_cache"];
    NSMenu *menu=[[NSMenu alloc] initWithTitle:@"Import Chrome bookmarks"];
    for(NSString *directory in [[profiles allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if([directory containsString:@"/"] || [directory isEqual:@".."] || [directory isEqual:@"."])continue;
        NSString *path=[[rootPath stringByAppendingPathComponent:directory] stringByAppendingPathComponent:@"Bookmarks"];if(![NSFileManager.defaultManager fileExistsAtPath:path])continue;
        NSString *name=profiles[directory][@"name"]?:directory;NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ into %@",name,profile.capitalizedString] action:@selector(importChromeProfile:) keyEquivalent:@""];item.target=self;item.representedObject=@{@"path":path,@"name":name};[menu addItem:item];
    }
    if(!menu.numberOfItems){[self alert:@"No Chrome bookmarks found" detail:@"Open Chrome once on this Mac, then try again."];return;}
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(20,20) inView:bookmarkView];
}
- (void)importChromeProfile:(NSMenuItem *)sender {
    NSError *error=nil;NSDictionary *result=MallardImportChrome(sender.representedObject[@"path"],sender.representedObject[@"name"],state[profile][@"bookmarks"],&error);
    if(!result){[self alert:@"Couldn't import bookmarks" detail:error.localizedDescription];return;}
    // Assign a fresh tree so the outline refreshes without changing existing entries.
    state[profile][@"bookmarks"]=MallardBookmarkTree(state[profile][@"bookmarks"]);[favicons primeBookmarks:state[profile][@"bookmarks"] profile:profile];[self saveSession];[self refresh];
    [self alert:@"Bookmarks imported" detail:[NSString stringWithFormat:@"%@ bookmarks added to %@. Existing bookmarks were kept; %@ repeated or unsupported entries were skipped.",result[@"imported"],profile.capitalizedString,result[@"skipped"]]];
}
- (void)showHistory:(id)sender { [self showList:state[profile][@"history"] title:@"History"]; }
- (void)revealDownload:(NSMenuItem *)sender { [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:sender.representedObject]]]; }
- (void)showDownloads:(id)sender { NSMenu *menu=[NSMenu new]; for(NSDictionary *entry in [state[profile][@"downloads"] reverseObjectEnumerator]) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:entry[@"name"] action:@selector(revealDownload:) keyEquivalent:@""]; item.target=self; item.representedObject=entry[@"path"]; [menu addItem:item]; } if(!menu.numberOfItems) [menu addItemWithTitle:@"No completed downloads" action:nil keyEquivalent:@""]; [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(12,92) inView:sidebar]; }
- (void)showMore:(id)sender { NSMenu *menu=[NSMenu new]; for(NSArray *row in @[@[@"Bookmarks",@"showBookmarks:"],@[@"History",@"showHistory:"],@[@"Downloads",@"showDownloads:"],@[@"Find in Page…",@"find:"],@[@"Mute / Unmute Tab",@"mute:"],@[@"Developer Tools",@"devtools:"]]) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:row[0] action:NSSelectorFromString(row[1]) keyEquivalent:@""]; item.target=self; [menu addItem:item]; } [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(toolbar.bounds.size.width-30,46) inView:toolbar]; }
- (void)mute:(id)sender { if(current->browser) current->browser->GetHost()->SetAudioMuted(!current->browser->GetHost()->IsAudioMuted()); }
- (void)devtools:(id)sender { if(current->browser) { CefWindowInfo info; CefBrowserSettings settings; current->browser->GetHost()->ShowDevTools(info,nullptr,settings,CefPoint()); } }
- (void)about:(id)sender { [self alert:@"Mallard 0.1" detail:@"A browser for school and everything else.\n\nLocal development build · Chromium 154"]; }
- (void)settings:(id)sender { [self alert:@"Mallard settings" detail:@"Search: Brave\nStartup: last-used profile\nProfiles: Personal and School\n\nUse the key button for passwords, card autofill, and Chrome import."]; }
- (void)showProtection:(id)sender {
    if(!current || !current->browser || !BlockingReady){[self alert:@"Ad and tracker blocking" detail:BlockingReady?@"Open a page to view its blocking controls.":@"The filter data could not be loaded."];return;}
    NSString *detail=[NSString stringWithFormat:@"%u requests blocked in this tab.\n\nPausing affects this tab until you turn blocking back on or restart Mallard. The page will reload.",current->blocked.load()];
    if(MallardRunDialog(window,current->blocking?@"Ad blocking is on":@"Ad blocking is paused",detail,@[],nil,@[],@[@"Done",current->blocking?@"Pause for this tab":@"Turn blocking on"],nil)!=1)return;
    current->blocking=!current->blocking;notice=@"";
    NSMutableDictionary *settings=[NSMutableDictionary dictionary];for(auto &tab:tabs)if(tab->browser)settings[[NSString stringWithFormat:@"%d",tab->browser->GetIdentifier()]]=@(tab->blocking.load());
    NSData *data=[NSJSONSerialization dataWithJSONObject:settings options:0 error:nil];[data writeToFile:[DataDirectory stringByAppendingPathComponent:@"blocking-state.json"] options:NSDataWritingAtomic error:nil];
    auto message=CefProcessMessage::Create("MallardProtection");message->GetArgumentList()->SetBool(0,current->blocking);current->browser->GetMainFrame()->SendProcessMessage(PID_RENDERER,message);
    current->browser->Reload();[self refreshChrome];[self refreshStatus];
}
- (void)showVault:(id)sender {
    NSMenu *menu=[NSMenu new]; NSString *origin=MallardOrigin(current->url);
    for(NSDictionary *entry in [MallardVault entriesForProfile:profile]) {
        BOOL card=[entry[@"kind"] isEqual:@"card"];
        if(!card && ![entry[@"origin"] isEqual:origin]) continue;
        NSString *label=card?[NSString stringWithFormat:@"%@ · •••• %@",entry[@"nickname"],entry[@"last4"]]:[NSString stringWithFormat:@"Fill %@",entry[@"username"]];
        NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:label action:@selector(fillEntry:) keyEquivalent:@""]; item.target=self; item.representedObject=@{@"id":entry[@"id"],@"origin":origin?:@"",@"profile":profile,@"tab":current->identifier}; [menu addItem:item];
    }
    if(menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];
    for(NSArray *row in @[@[@"Save a Password…",@"addPassword:"],@[@"Add a Card…",@"addCard:"],@[@"Import Chrome Passwords…",@"importPasswords:"]]) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:row[0] action:NSSelectorFromString(row[1]) keyEquivalent:@""]; item.target=self; [menu addItem:item]; }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(vaultButton.frame.origin.x,46) inView:toolbar];
}
- (NSArray<NSString *> *)form:(NSString *)title fields:(NSArray<NSString *> *)names secure:(NSIndexSet *)secure {
    NSString *detail=[NSString stringWithFormat:@"Saved only in %@. Touch ID or your Mac password protects access.",profile.capitalizedString];
    NSArray *values=nil;return MallardRunDialog(window,title,detail,names,secure,@[],@[@"Save",@"Cancel"],&values)==0?values:nil;
}
- (void)addPassword:(id)sender {
    NSString *origin=MallardOrigin(current->url); if(![origin hasPrefix:@"https://"]) { [self alert:@"Open the sign-in site first" detail:@"Password autofill is available on secure HTTPS pages."]; return; }
    NSArray *v=[self form:[@"Save password for " stringByAppendingString:origin] fields:@[@"Username",@"Password"] secure:[NSIndexSet indexSetWithIndex:1]]; if(!v) return;
    if(![v[1] length]) { [self alert:@"Password is empty" detail:@"Nothing was saved."]; return; }
    NSError *error=nil; if(![MallardVault save:@{@"kind":@"password",@"origin":origin,@"username":v[0],@"password":v[1]} profile:profile error:&error]) [self alert:@"Couldn't save password" detail:error.localizedDescription]; else { notice=@"Password saved in Keychain"; [self refresh]; }
}
- (void)addCard:(id)sender {
    NSArray *v=[self form:@"Add a card" fields:@[@"Nickname",@"Name on card",@"Card number",@"Expiry month (MM)",@"Expiry year (YYYY)"] secure:[NSIndexSet indexSetWithIndex:2]]; if(!v) return;
    NSString *number=[[v[2] componentsSeparatedByCharactersInSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet] componentsJoinedByString:@""];
    int sum=0; BOOL alternate=NO; for(NSInteger i=number.length-1;i>=0;i--) { int n=[number characterAtIndex:i]-'0'; if(alternate){ n*=2;if(n>9)n-=9; }sum+=n;alternate=!alternate; }
    NSDateComponents *today=[NSCalendar.currentCalendar components:NSCalendarUnitYear|NSCalendarUnitMonth fromDate:NSDate.date];
    BOOL expired=[v[4] integerValue]<today.year || ([v[4] integerValue]==today.year && [v[3] integerValue]<today.month);
    if(number.length<12 || number.length>19 || sum%10 || [v[3] intValue]<1 || [v[3] intValue]>12 || expired) { [self alert:@"Check the card details" detail:@"The number or expiry is invalid. Nothing was saved."]; return; }
    NSError *error=nil; NSDictionary *record=@{@"kind":@"card",@"nickname":[v[0] length]?v[0]:@"Card",@"name":v[1],@"number":number,@"month":[NSString stringWithFormat:@"%02d",[v[3] intValue]],@"year":v[4]};
    if(![MallardVault save:record profile:profile error:&error]) [self alert:@"Couldn't save card" detail:error.localizedDescription]; else { notice=@"Card saved in Keychain"; [self refresh]; }
}
- (void)importPasswords:(id)sender {
    NSOpenPanel *panel=[NSOpenPanel openPanel]; panel.allowedFileTypes=@[@"csv"]; panel.allowsMultipleSelection=NO; panel.message=[NSString stringWithFormat:@"Choose a Chrome password export for %@. The file stays on this Mac.",profile.capitalizedString];
    if([panel runModal]!=NSModalResponseOK) return;
    NSError *error=nil; NSString *text=[NSString stringWithContentsOfURL:panel.URL encoding:NSUTF8StringEncoding error:&error]; NSArray *records=text?MallardParsePasswordCSV(text,&error):nil;
    if(!records) { [self alert:@"Couldn't read the password export" detail:error.localizedDescription]; return; }
    NSArray *existing=[MallardVault entriesForProfile:profile]; NSMutableSet *keys=[NSMutableSet set]; for(NSDictionary *e in existing) if([e[@"kind"] isEqual:@"password"]) [keys addObject:@[e[@"origin"],e[@"username"]]];
    NSMutableArray *pending=[NSMutableArray array]; for(NSDictionary *r in records) { NSArray *key=@[r[@"origin"],r[@"username"]]; if(![keys containsObject:key]) { [pending addObject:r]; [keys addObject:key]; } }
    NSString *title=[NSString stringWithFormat:@"Import %lu passwords into %@?",(unsigned long)pending.count,profile.capitalizedString]; NSString *detail=[NSString stringWithFormat:@"%lu existing or repeated accounts will be skipped. Your existing passwords will be kept. The original export is not modified.",(unsigned long)(records.count-pending.count)]; if(MallardRunDialog(window,title,detail,@[],nil,@[],@[@"Import",@"Cancel"],nil)!=0)return;
    NSUInteger saved=0; for(NSDictionary *record in pending) { if(![MallardVault save:record profile:profile error:&error]) break; ++saved; }
    [self alert:error?@"Import stopped":@"Import complete" detail:[NSString stringWithFormat:@"%lu passwords saved in %@.%@\n\nThe Chrome export contains readable passwords. Remove it when you no longer need it.",(unsigned long)saved,profile.capitalizedString,error?[@"\n" stringByAppendingString:error.localizedDescription]:@""]];
}
- (void)fillEntry:(NSMenuItem *)sender {
    NSDictionary *selection=sender.representedObject; NSString *origin=selection[@"origin"];
    if(![origin hasPrefix:@"https://"] || !current->browser) { [self alert:@"Open a secure page first" detail:@"Autofill requires an HTTPS page."]; return; }
    [MallardVault read:selection[@"id"] profile:selection[@"profile"] completion:^(NSDictionary *record,NSError *error) {
    if(Quitting || !current || !current->browser)return;
    if(!record) { if(error.code!=errSecUserCanceled && error.code!=LAErrorUserCancel && error.code!=LAErrorSystemCancel && error.code!=LAErrorAppCancel) [self alert:@"Couldn't unlock this item" detail:error.localizedDescription?:@"Authentication did not complete."]; return; }
    if(![profile isEqual:selection[@"profile"]] || ![current->identifier isEqual:selection[@"tab"]] || ![MallardOrigin(Text(current->browser->GetMainFrame()->GetURL())) isEqual:origin]) { [self alert:@"The page changed" detail:@"Select the saved item again on the page where you want to fill it."]; return; }
    if([record[@"kind"] isEqual:@"password"] && ![record[@"origin"] isEqual:origin]) return;
    [self sendAutofill:record origin:origin];
    }];
}
- (void)sendAutofill:(NSDictionary *)record origin:(NSString *)origin {
    if(!current || !current->browser)return;
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"origin":origin,@"record":record} options:0 error:nil];
    NSString *payload=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    NSString *function=[NSString stringWithContentsOfFile:[[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"autofill.js"] encoding:NSUTF8StringEncoding error:nil];
    if(!function)return;
    auto message=CefProcessMessage::Create("MallardAutofill");message->GetArgumentList()->SetString(0,CefText([NSString stringWithFormat:@"%@(%@)",function,payload]));current->browser->GetMainFrame()->SendProcessMessage(PID_RENDERER,message);
}
- (BOOL)onTestFixture { return current && [MallardOrigin(current->url) isEqual:@"http://mallard.localhost:8742"]; }
- (void)testPasswordFill:(id)sender {
    if(![self onTestFixture]){[self alert:@"Open the local test fixture" detail:@"This developer action only fills synthetic data on mallard.localhost:8742."];return;}
    [self sendAutofill:@{@"kind":@"password",@"username":@"mallard-test@example.invalid",@"password":@"synthetic-password-4931"} origin:@"http://mallard.localhost:8742"];
}
- (void)testCardFill:(id)sender {
    if(![self onTestFixture]){[self alert:@"Open the local test fixture" detail:@"This developer action only fills synthetic data on mallard.localhost:8742."];return;}
    [self sendAutofill:@{@"kind":@"card",@"name":@"Mallard Test",@"number":@"4242424242424242",@"month":@"12",@"year":@"2030"} origin:@"http://mallard.localhost:8742"];
}
- (BOOL)windowShouldClose:(NSWindow *)sender { if(Quitting) return BrowserCount==0; for(auto &tab:tabs)if(tab->closing)return NO;[self quit:sender];return NO; }
- (void)quit:(id)sender {
    [self saveSession]; Quitting=YES;
    auto copy=tabs; for(auto &tab:copy) if(tab->browser) tab->browser->GetHost()->CloseBrowser(false);
    if(BrowserCount==0) { [telemetry stop];CefQuitMessageLoop(); }
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag { [window makeKeyAndOrderFront:nil]; return YES; }
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }
@end

@interface MallardApplication : NSApplication <CefAppProtocol> { BOOL handling_; }
@end
@implementation MallardApplication
- (BOOL)isHandlingSendEvent { return handling_; }
- (void)setHandlingSendEvent:(BOOL)value { handling_=value; }
- (void)sendEvent:(NSEvent *)event { CefScopedSendingEvent scope; [super sendEvent:event]; }
- (void)terminate:(id)sender { [Controller quit:sender]; }
@end

class BrowserApp : public CefApp, public CefBrowserProcessHandler {
public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
    void OnContextInitialized() override { [Controller start]; }
    void OnBeforeChildProcessLaunch(CefRefPtr<CefCommandLine> command) override { command->AppendSwitchWithValue("mallard-filters",CefText(FilterDirectory));command->AppendSwitchWithValue("mallard-protection",CefText([DataDirectory stringByAppendingPathComponent:@"blocking-state.json"])); }
private: IMPLEMENT_REFCOUNTING(BrowserApp);
};

int main(int argc,char **argv) {
    @autoreleasepool {
        if(argc>1 && strcmp(argv[1],"--test-core")==0) return MallardCoreTests()?0:1;
        if(argc>1 && strcmp(argv[1],"--test-telemetry")==0) return MallardTelemetryTests()?0:1;
        if(argc>1 && strcmp(argv[1],"--test-bookmarks")==0) return MallardBookmarkTests()?0:1;
        if(argc>1 && strcmp(argv[1],"--test-favicons")==0) return MallardFaviconTests()?0:1;
        if(argc==5 && strcmp(argv[1],"--import-chrome-bookmarks")==0) return MallardImportChromeSession([NSString stringWithUTF8String:argv[2]],[NSString stringWithUTF8String:argv[3]],[NSString stringWithUTF8String:argv[4]]);
        if(argc>1 && strcmp(argv[1],"--test-vault-storage")==0) return MallardVaultStorageTest()?0:1;
        if(argc>1 && strcmp(argv[1],"--test-vault-auth")==0) return MallardVaultAuthenticationTest()?0:1;
        CefScopedLibraryLoader loader; if(!loader.LoadInMain()) return 1;
        [MallardApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSImage *appIcon=[[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Mallard.icns"]];if(appIcon)NSApp.applicationIconImage=appIcon;
        NSString *font=[[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"fonts/JetBrainsMono-Regular.ttf"];
        if([[NSFileManager defaultManager] fileExistsAtPath:font]) CTFontManagerRegisterFontsForURL((__bridge CFURLRef)[NSURL fileURLWithPath:font],kCTFontManagerScopeProcess,NULL);
        DataDirectory=[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"Mallard"];
        FilterDirectory=[[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"blocking"];
        NSData *pointer=[NSData dataWithContentsOfFile:[DataDirectory stringByAppendingPathComponent:@"current-filters.json"]];
        NSDictionary *filterState=pointer?[NSJSONSerialization JSONObjectWithData:pointer options:0 error:nil]:nil;
        NSString *revision=filterState[@"revision"];
        if([revision isKindOfClass:NSString.class] && [[NSUUID alloc] initWithUUIDString:revision]) {
            NSString *candidate=[[DataDirectory stringByAppendingPathComponent:@"FilterRevisions"] stringByAppendingPathComponent:revision];
            if(mb_validate(candidate.UTF8String))FilterDirectory=candidate;
        }
        BlockingReady=mb_init(FilterDirectory.UTF8String);
        [[NSFileManager defaultManager] createDirectoryAtPath:DataDirectory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
        [@"{}" writeToFile:[DataDirectory stringByAppendingPathComponent:@"blocking-state.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Controller=[MallardController new]; NSApp.delegate=Controller;
        CefSettings settings; CefString(&settings.root_cache_path)=CefText([DataDirectory stringByAppendingPathComponent:@"Profiles"]); CefString(&settings.cache_path)=CefText([DataDirectory stringByAppendingPathComponent:@"Profiles/Global"]); CefString(&settings.log_file)=CefText([DataDirectory stringByAppendingPathComponent:@"chromium.log"]); settings.log_severity=LOGSEVERITY_ERROR;
        CefRefPtr<BrowserApp> app=new BrowserApp;
        if(!CefInitialize(CefMainArgs(argc,argv),settings,app,nullptr)) return CefGetExitCode();
        CefRunMessageLoop();
        Controller->tabs.clear(); Controller->current.reset(); Controller->personalContext=nullptr; Controller->schoolContext=nullptr;
        CefShutdown();
    }
    return 0;
}
