#pragma once
#include "include/cef_app.h"
#include "include/cef_parser.h"
#include "include/cef_v8.h"
#include "Blocker.h"
#include <map>
#include <unistd.h>
inline bool RendererFiltersReady=false;
inline std::string RendererProtectionData;

inline CefRefPtr<CefDictionaryValue> Cosmetics(const std::string &url,const std::string &classes="[]",const std::string &ids="[]") {
    char *raw=mb_cosmetic(url.c_str(),classes.c_str(),ids.c_str());
    auto json=CefParseJSON(raw,JSON_PARSER_RFC); mb_free(raw);
    return json?json->GetDictionary():nullptr;
}
class CosmeticHandler : public CefV8Handler {
public:
    bool Execute(const CefString&,CefRefPtr<CefV8Value>,const CefV8ValueList &args,CefRefPtr<CefV8Value>& result,CefString&) override {
        auto context=CefV8Context::GetCurrentContext();
        if(!context || args.size()!=2) return false;
        auto rules=Cosmetics(context->GetFrame()->GetURL().ToString(),args[0]->GetStringValue(),args[1]->GetStringValue());
        result=CefV8Value::CreateString(rules?rules->GetString("css"):CefString()); return true;
    }
private: IMPLEMENT_REFCOUNTING(CosmeticHandler);
};
class RendererApp : public CefApp,public CefRenderProcessHandler {
    std::map<int,bool> protection_;
public:
    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }
    void OnWebKitInitialized() override {
        auto value=CefParseJSON(RendererProtectionData,JSON_PARSER_RFC);
        if(value && value->GetDictionary()) {auto dictionary=value->GetDictionary();CefDictionaryValue::KeyList keys;dictionary->GetKeys(keys);for(auto &key:keys)protection_[atoi(key.ToString().c_str())]=dictionary->GetBool(key);}
    }
    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,CefRefPtr<CefFrame> frame,CefProcessId source,CefRefPtr<CefProcessMessage> message) override {
        if(source==PID_BROWSER && message->GetName()=="MallardReportRenderer"){auto pid=CefProcessMessage::Create("MallardRendererPID");pid->GetArgumentList()->SetInt(0,getpid());frame->SendProcessMessage(PID_BROWSER,pid);return true;}
        if(source==PID_BROWSER && message->GetName()=="MallardProtection") { protection_[browser->GetIdentifier()]=message->GetArgumentList()->GetBool(0);return true; }
        if(source!=PID_BROWSER || message->GetName()!="MallardAutofill")return false;
        auto context=frame->GetV8Context();if(!context || !context->Enter())return true;
        CefRefPtr<CefV8Value> result;CefRefPtr<CefV8Exception> exception;
        bool ok=context->Eval(message->GetArgumentList()->GetString(0),"mallard:autofill",0,result,exception);
        auto reply=CefProcessMessage::Create("MallardAutofillResult");
        reply->GetArgumentList()->SetInt(0,ok && result && result->IsObject()?result->GetValue("filled")->GetIntValue():0);
        context->Exit();frame->SendProcessMessage(PID_BROWSER,reply);return true;
    }
    void OnContextCreated(CefRefPtr<CefBrowser> browser,CefRefPtr<CefFrame> frame,CefRefPtr<CefV8Context> context) override {
        auto pid=CefProcessMessage::Create("MallardRendererPID");pid->GetArgumentList()->SetInt(0,getpid());frame->SendProcessMessage(PID_BROWSER,pid);
        if(protection_.contains(browser->GetIdentifier()) && !protection_[browser->GetIdentifier()])return;
        std::string url=frame->GetURL(); if(url.rfind("https://",0)!=0 && url.rfind("http://",0)!=0) return;
        auto rules=Cosmetics(url); if(!rules) return;
        context->GetGlobal()->SetValue("__mallardCosmetics",CefV8Value::CreateFunction("__mallardCosmetics",new CosmeticHandler),V8_PROPERTY_ATTRIBUTE_DONTENUM);
        CefRefPtr<CefV8Value> result; CefRefPtr<CefV8Exception> exception;
        CefString script=rules->GetString("script");
        bool scriptletSuccess=script.empty() || context->Eval(script,"mallard:scriptlets",0,result,exception);
        auto value=CefValue::Create();auto cssValue=CefDictionaryValue::Create();cssValue->SetString("css",rules->GetString("css"));value->SetDictionary(cssValue);
        std::string initial="("+CefWriteJSON(value,JSON_WRITER_DEFAULT).ToString()+").css";
        std::string cssScript=R"JS((()=>{
            const getCSS=globalThis.__mallardCosmetics; delete globalThis.__mallardCosmetics;
            let sheet; try {sheet=new CSSStyleSheet();document.adoptedStyleSheets=[...document.adoptedStyleSheets,sheet];}catch{return;}
            let css=)JS"+initial+R"JS(;
            const classes=new Set(),ids=new Set();let queued=false;
            function scan(){queued=false;const c=[],i=[];for(const e of document.querySelectorAll('[class],[id]')){for(const name of e.classList){if(!classes.has(name)){classes.add(name);c.push(name);}}if(e.id&&!ids.has(e.id)){ids.add(e.id);i.push(e.id);}}
                if(c.length||i.length)css+='\n'+getCSS(JSON.stringify(c),JSON.stringify(i));
                try{sheet.replaceSync(css);if(!document.adoptedStyleSheets.includes(sheet))document.adoptedStyleSheets=[...document.adoptedStyleSheets,sheet];}catch{}
            }
            sheet.replaceSync(css);
            function schedule(){if(!queued){queued=true;setTimeout(scan,250);}}
            new MutationObserver(schedule).observe(document,{childList:true,subtree:true,attributes:true,attributeFilter:['class','id']});
            document.addEventListener('DOMContentLoaded',scan,{once:true});schedule();
        })();)JS";
        bool success=context->Eval(cssScript,"mallard:cosmetic-filtering",0,result,exception);
        auto report=CefProcessMessage::Create("MallardFilterDiagnostic");
        report->GetArgumentList()->SetBool(0,RendererFiltersReady);
        report->GetArgumentList()->SetBool(1,success);
        report->GetArgumentList()->SetInt(2,initial.size());
        report->GetArgumentList()->SetString(3,(!success && url.rfind("http://localhost:",0)==0 && exception)?exception->GetMessage():CefString());
        report->GetArgumentList()->SetInt(4,script.length());report->GetArgumentList()->SetBool(5,scriptletSuccess);
        frame->SendProcessMessage(PID_BROWSER,report);
    }
    void OnContextReleased(CefRefPtr<CefBrowser>,CefRefPtr<CefFrame> frame,CefRefPtr<CefV8Context>) override {
        if(frame->IsValid()){auto gone=CefProcessMessage::Create("MallardRendererGone");gone->GetArgumentList()->SetInt(0,getpid());frame->SendProcessMessage(PID_BROWSER,gone);}
    }
private: IMPLEMENT_REFCOUNTING(RendererApp);
};
