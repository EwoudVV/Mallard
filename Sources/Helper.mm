#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include "Renderer.h"
#include <string>
#include <fstream>
#include <sstream>

int main(int argc, char **argv) {
    bool renderer=false;std::string filters;
    for(int i=1;i<argc;i++) { std::string arg=argv[i];if(arg=="--type=renderer")renderer=true;if(arg.rfind("--mallard-filters=",0)==0)filters=arg.substr(18); }
    if(renderer && !filters.empty()) RendererFiltersReady=mb_init(filters.c_str());
    for(int i=1;i<argc;i++){std::string arg=argv[i],prefix="--mallard-protection=";if(renderer && arg.rfind(prefix,0)==0){std::ifstream file(arg.substr(prefix.size()));std::ostringstream data;data<<file.rdbuf();RendererProtectionData=data.str();}}
    CefScopedSandboxContext sandbox;
    if(!sandbox.Initialize(argc,argv)) return 1;
    CefScopedLibraryLoader loader;
    if(!loader.LoadInHelper()) return 2;
    return CefExecuteProcess(CefMainArgs(argc,argv),new RendererApp,nullptr);
}
