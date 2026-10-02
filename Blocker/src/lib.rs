use adblock::{Engine,lists::{FilterSet,ParseOptions},request::Request,resources::Resource};
use std::{ffi::{CStr,CString},os::raw::c_char,path::Path,sync::{Mutex,OnceLock}};
static ENGINE: OnceLock<Mutex<Engine>>=OnceLock::new();
fn text<'a>(ptr:*const c_char)-> &'a str { if ptr.is_null(){""} else {unsafe{CStr::from_ptr(ptr)}.to_str().unwrap_or("")} }
fn returned(value:String)->*mut c_char { CString::new(value).unwrap_or_default().into_raw() }

fn condition(expression:&str)->bool {
    if expression.contains("||"){return expression.split("||").any(|e|condition(e.trim()));}
    if expression.contains("&&"){return expression.split("&&").all(|e|condition(e.trim()));}
    if let Some(e)=expression.strip_prefix('!'){return !condition(e.trim());}
    matches!(expression.trim(),"env_chromium"|"env_chrome")
}
fn preprocess(text:&str)->String {
    let mut stack=Vec::new();let mut active=true;let mut output=String::new();
    for line in text.lines(){
        if let Some(expression)=line.strip_prefix("!#if "){let yes=condition(expression);stack.push((active,yes));active=active&&yes;}
        else if line.starts_with("!#else"){if let Some((parent,yes))=stack.last(){active=*parent && !yes;}}
        else if line.starts_with("!#endif"){if let Some((parent,_))=stack.pop(){active=parent;}}
        else if active && !line.starts_with("!#include"){output.push_str(line);output.push('\n');}
    }output
}

fn load(path:&Path)->Result<Engine,String>{
    let mut filters=FilterSet::new(false);
    let mut files:Vec<_>=std::fs::read_dir(path).map_err(|e|e.to_string())?.flatten().map(|e|e.path()).filter(|p|p.extension().is_some_and(|s|s=="txt")).collect();
    files.sort();
    if files.is_empty(){return Err("No filter lists were found".into());}
    for file in files { filters.add_filter_list(preprocess(&std::fs::read_to_string(file).map_err(|e|e.to_string())?),ParseOptions::default()); }
    let mut engine=Engine::new_with_filter_set(filters);
    let resources:Vec<Resource>=serde_json::from_slice(&std::fs::read(path.join("resources.json")).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?;
    let mut merged:std::collections::HashMap<String,Resource>=resources.into_iter().map(|r|(r.name.clone(),r)).collect();
    if let Ok(bytes)=std::fs::read(path.join("resources-brave.json")) {
        let extras:Vec<Resource>=serde_json::from_slice(&bytes).map_err(|e|e.to_string())?;
        for r in extras{merged.insert(r.name.clone(),r);}
    }
    engine.use_resources(merged.into_values());
    Ok(engine)
}

#[no_mangle]
pub extern "C" fn mb_validate(path:*const c_char)->bool { load(Path::new(text(path))).is_ok() }
#[no_mangle]
pub extern "C" fn mb_init(path:*const c_char)->bool {
    match load(Path::new(text(path))) {
        Ok(engine)=>{ if let Some(lock)=ENGINE.get(){*lock.lock().unwrap()=engine;}else{let _=ENGINE.set(Mutex::new(engine));} true },
        Err(error)=>{eprintln!("Mallard filter load failed: {error}");false}
    }
}
#[no_mangle]
pub extern "C" fn mb_request(url:*const c_char,source:*const c_char,kind:*const c_char,method:*const c_char)->*mut c_char {
    let Some(engine)=ENGINE.get() else{return returned("{}".into())};
    let Ok(request)=Request::new(text(url),text(source),text(kind),text(method)) else{return returned("{}".into())};
    let result=engine.lock().unwrap().check_network_request(&request);
    returned(serde_json::json!({"blocked":result.should_block(),"redirect":result.redirect}).to_string())
}
#[no_mangle]
pub extern "C" fn mb_cosmetic(url:*const c_char,classes:*const c_char,ids:*const c_char)->*mut c_char {
    let Some(engine)=ENGINE.get() else{return returned("{}".into())};
    let engine=engine.lock().unwrap();
    let rules=engine.url_cosmetic_resources(text(url));
    let classes:Vec<String>=serde_json::from_str(text(classes)).unwrap_or_default();
    let ids:Vec<String>=serde_json::from_str(text(ids)).unwrap_or_default();
    let mut selectors:Vec<String>=rules.hide_selectors.into_iter().collect();
    if !rules.generichide { selectors.extend(engine.hidden_class_id_selectors(&classes,&ids,&rules.exceptions)); }
    let css=selectors.iter().map(|s|format!("{s} {{ display: none !important; }}\n")).collect::<String>();
    returned(serde_json::json!({"css":css,"script":rules.injected_script}).to_string())
}
#[no_mangle]
pub extern "C" fn mb_free(ptr:*mut c_char){if !ptr.is_null(){unsafe{drop(CString::from_raw(ptr));}}}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn bundled_cosmetic_and_youtube_resources(){
        let path=Path::new(env!("CARGO_MANIFEST_DIR")).join("../Resources/blocking");
        let e=load(&path).unwrap();
        assert!(e.url_cosmetic_resources("http://localhost:8742/browser.html").generichide,"Respect EasyList's localhost exception");
        let rules=e.url_cosmetic_resources("http://mallard.localhost:8742/browser.html");
        assert!(!rules.generichide);
        let selectors=e.hidden_class_id_selectors(["advertisement-banner"],std::iter::empty::<&str>(),&rules.exceptions);
        assert!(selectors.iter().any(|s|s==".advertisement-banner"));
        assert!(!e.url_cosmetic_resources("https://www.youtube.com/watch?v=fixture").injected_script.is_empty());
    }
    #[test] fn platform_conditions(){assert_eq!(preprocess("!#if env_firefox\nwrong\n!#else\nright\n!#endif\n!#if cap_html_filtering\nunsupported\n!#endif"),"right\n");}
    #[test] fn matching_preserves_exceptions(){
        let mut f=FilterSet::new(false);f.add_filter_list("||ads.example^\n@@||ads.example/allowed.js$script\nexample.test##.sponsor\n||post.example^$method=post".to_owned(),ParseOptions::default());
        let e=Engine::new_with_filter_set(f);
        assert!(e.check_network_request(&Request::new("https://ads.example/banner.js","https://example.test","script","GET").unwrap()).should_block());
        assert!(!e.check_network_request(&Request::new("https://ads.example/allowed.js","https://example.test","script","GET").unwrap()).should_block());
        assert!(e.url_cosmetic_resources("https://example.test").hide_selectors.contains(".sponsor"));
        assert!(!e.url_cosmetic_resources("https://other.test").hide_selectors.contains(".sponsor"));
        assert!(e.check_network_request(&Request::new("https://post.example/metric","https://example.test","xmlhttprequest","POST").unwrap()).should_block());
        assert!(!e.check_network_request(&Request::new("https://post.example/metric","https://example.test","xmlhttprequest","GET").unwrap()).should_block());
    }
}
