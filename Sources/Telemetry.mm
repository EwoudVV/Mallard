#import "Telemetry.h"
#import <Cocoa/Cocoa.h>
#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>
#include <set>
#include <vector>
#include <cmath>
#include <atomic>
#include <util.h>
#include <termios.h>
#include <mach/mach_time.h>

NSString *MallardBytes(double bytes) {
    const char *units[]={"B","KB","MB","GB","TB"};int unit=0;
    double value=std::max(0.0,bytes);while(value>=1000 && unit<4){value/=1000;++unit;}
    return value<10 && unit>0?[NSString stringWithFormat:@"%.1f %s",value,units[unit]]:[NSString stringWithFormat:@"%.0f %s",value,units[unit]];
}
NSString *MallardRate(double bytes) { return [NSString stringWithFormat:@"%.2f Mbps",std::max(0.0,bytes)*8.0/1000000.0]; }
static double NanosecondsPerTick(void) {
    static const double scale=[](){mach_timebase_info_data_t info;mach_timebase_info(&info);return double(info.numer)/info.denom;}();return scale;
}
static double CPUShare(uint64_t before,uint64_t after,double seconds,NSInteger cores,double scale=NanosecondsPerTick()) {
    if(after<before || seconds<=0 || cores<1)return 0;
    return std::min(100.0,(after-before)*scale/1e9/seconds/cores*100.0);
}
static NSDictionary *NetworkRows(NSString *text) {
    NSMutableDictionary *rows=[NSMutableDictionary dictionary];NSInteger input=-1,output=-1;
    for(NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSArray *columns=[line componentsSeparatedByString:@","];
        if([columns containsObject:@"bytes_in"] && [columns containsObject:@"bytes_out"]){input=[columns indexOfObject:@"bytes_in"];output=[columns indexOfObject:@"bytes_out"];continue;}
        if(input<0 || output<0 || columns.count<=MAX(input,output))continue;
        // nettop's first column is the process name followed by its pid.
        NSString *identity=columns.firstObject;NSRange dot=[identity rangeOfString:@"." options:NSBackwardsSearch];
        if(dot.location==NSNotFound)continue;
        NSString *suffix=[identity substringFromIndex:dot.location+1];
        if(!suffix.length || [suffix rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location!=NSNotFound)continue;
        NSString *down=[columns[input] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet],*up=[columns[output] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if(!down.length || !up.length || [down rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location!=NSNotFound || [up rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location!=NSNotFound)continue;
        rows[@(suffix.intValue)]=@[@(down.longLongValue),@(up.longLongValue)];
    }
    return rows;
}

@implementation MallardTelemetry {
    NSMutableDictionary *previousCPU,*previousNetwork;
    NSTimeInterval sampledAt,networkAt,lastNetworkRequest;
    NSUInteger networkGeneration;
    NSTimeInterval lastNetworkOutput;
    NSFileHandle *networkReader;
    NSMutableString *networkBuffer,*networkFrame;
    std::atomic<bool> stopped;
    NSTask *networkTask;
}
- (instancetype)init { if((self=[super init])){stopped=false;previousCPU=[NSMutableDictionary dictionary];previousNetwork=[NSMutableDictionary dictionary];_processes=@{};_cpu=0;}return self; }
- (void)sample {
    if(stopped)return;
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime,elapsed=sampledAt?now-sampledAt:0;sampledAt=now;
    std::vector<pid_t> pending={getpid()};std::set<pid_t> seen;NSMutableDictionary *snapshot=[NSMutableDictionary dictionary];
    NSString *bundle=[NSBundle.mainBundle.bundlePath stringByAppendingString:@"/"];
    uint64_t memory=0;double cpu=0;
    for(size_t i=0;i<pending.size();i++) {
        pid_t pid=pending[i];if(!seen.insert(pid).second)continue;
        pid_t children[512];int count=proc_listchildpids(pid,children,sizeof(children));for(int j=0;j<std::min(count,512);j++)if(children[j]>0)pending.push_back(children[j]);
        char path[PROC_PIDPATHINFO_MAXSIZE]={0};if(!proc_pidpath(pid,path,sizeof(path)))continue;
        BOOL meter=networkTask.running && pid==networkTask.processIdentifier;
        if(pid!=getpid() && !meter && ![[NSString stringWithUTF8String:path] hasPrefix:bundle])continue;
        rusage_info_v4 usage={};if(proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t *)&usage)!=0)continue;
        NSNumber *key=@(pid);NSDictionary *previous=previousCPU[key];uint64_t ticks=usage.ri_user_time+usage.ri_system_time;
        BOOL same=previous && [previous[@"start"] unsignedLongLongValue]==usage.ri_proc_start_abstime;
        double share=same?CPUShare([previous[@"ticks"] unsignedLongLongValue],ticks,elapsed,NSProcessInfo.processInfo.activeProcessorCount):0;
        previousCPU[key]=@{@"ticks":@(ticks),@"start":@(usage.ri_proc_start_abstime)};
        snapshot[key]=@{@"memory":@(usage.ri_phys_footprint),@"cpu":@(share),@"start":@(usage.ri_proc_start_abstime)};
        memory+=usage.ri_phys_footprint;cpu+=share;
    }
    for(NSNumber *pid in previousCPU.allKeys)if(!snapshot[pid])[previousCPU removeObjectForKey:pid];
    _processes=snapshot;_memory=memory;_cpu=std::min(100.0,cpu);
    if(!snapshot.count || now-lastNetworkRequest<2)return;
    if(networkTask.running && now-lastNetworkOutput<6)return;
    [self startNetwork];
}
- (void)acceptNetworkFrame:(NSString *)frame {
    NSDictionary *rows=NetworkRows(frame);uint64_t incoming=0,outgoing=0;
    for(NSNumber *pid in rows) {
        NSDictionary *process=_processes[pid];if(!process)continue;
        NSArray *counts=rows[pid],*old=previousNetwork[pid];
        BOOL same=old && [old[2] isEqual:process[@"start"]];
        uint64_t down=[counts[0] unsignedLongLongValue],up=[counts[1] unsignedLongLongValue];
        if(same){uint64_t lastDown=[old[0] unsignedLongLongValue],lastUp=[old[1] unsignedLongLongValue];incoming+=down>=lastDown?down-lastDown:down;outgoing+=up>=lastUp?up-lastUp:up;}
        else if(networkAt>0){incoming+=down;outgoing+=up;}
        previousNetwork[pid]=@[counts[0],counts[1],process[@"start"]];
    }
    double now=NSProcessInfo.processInfo.systemUptime,interval=networkAt?now-networkAt:0;networkAt=now;
    _downloadRate=interval>0?incoming/interval:0;_uploadRate=interval>0?outgoing/interval:0;
    _downloaded+=incoming;_uploaded+=outgoing;_networkReady=interval>0;
    for(NSNumber *pid in previousNetwork.allKeys)if(!_processes[pid])[previousNetwork removeObjectForKey:pid];
}
- (void)acceptNetworkChunk:(NSString *)chunk {
    lastNetworkOutput=NSProcessInfo.processInfo.systemUptime;
    [networkBuffer appendString:[chunk stringByReplacingOccurrencesOfString:@"\r" withString:@""]];
    NSRange newline;
    while((newline=[networkBuffer rangeOfString:@"\n"]).location!=NSNotFound) {
        NSString *line=[networkBuffer substringToIndex:newline.location];[networkBuffer deleteCharactersInRange:NSMakeRange(0,newline.location+1)];
        if([line containsString:@"bytes_in"] && [line containsString:@"bytes_out"]) {
            if(networkFrame.length)[self acceptNetworkFrame:networkFrame];
            networkFrame=[NSMutableString stringWithFormat:@"%@\n",line];
        } else if(networkFrame.length)[networkFrame appendFormat:@"%@\n",line];
    }
}
- (void)startNetwork {
    lastNetworkRequest=NSProcessInfo.processInfo.systemUptime;
    networkReader.readabilityHandler=nil;if(networkTask.running)[networkTask terminate];
    networkReader=nil;networkTask=nil;NSUInteger generation=++networkGeneration;
    _networkReady=NO;networkAt=0;[previousNetwork removeAllObjects];
    networkBuffer=[NSMutableString string];networkFrame=[NSMutableString string];
    int master=-1,slave=-1;if(openpty(&master,&slave,NULL,NULL,NULL)!=0)return;
    struct termios attributes;if(tcgetattr(slave,&attributes)==0){cfmakeraw(&attributes);tcsetattr(slave,TCSANOW,&attributes);}
    networkReader=[[NSFileHandle alloc] initWithFileDescriptor:master closeOnDealloc:YES];
    NSFileHandle *output=[[NSFileHandle alloc] initWithFileDescriptor:slave closeOnDealloc:YES];
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:@"/usr/bin/nettop"];
    // A tty keeps nettop's CSV output line-buffered. Only Mallard process names
    // are requested, and every row is checked against our own process tree.
    task.arguments=@[@"-n",@"-P",@"-x",@"-L",@"0",@"-s",@"1",@"-J",@"bytes_in,bytes_out",@"-p",@"Mallard",@"-p",@"Mallard Helper"];
    task.standardOutput=output;task.standardError=NSFileHandle.fileHandleWithNullDevice;
    // nettop polls stdin even in CSV mode. /dev/null is always readable and
    // causes a busy loop; keep its input on the same open tty as its output.
    task.standardInput=output;
    __weak MallardTelemetry *weak=self;
    networkReader.readabilityHandler=^(NSFileHandle *reader){
        char bytes[8192];ssize_t length=read(reader.fileDescriptor,bytes,sizeof(bytes));if(length<=0){reader.readabilityHandler=nil;return;}
        NSString *chunk=[[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];if(!chunk)return;
        dispatch_async(dispatch_get_main_queue(),^{MallardTelemetry *owner=weak;if(owner && !owner->stopped && owner->networkGeneration==generation)[owner acceptNetworkChunk:chunk];});
    };
    task.terminationHandler=^(NSTask *finished){dispatch_async(dispatch_get_main_queue(),^{MallardTelemetry *owner=weak;if(owner && owner->networkGeneration==generation){owner->_networkReady=NO;owner->networkReader.readabilityHandler=nil;owner->networkReader=nil;owner->networkTask=nil;}});};
    NSError *error=nil;if([task launchAndReturnError:&error]){networkTask=task;lastNetworkOutput=NSProcessInfo.processInfo.systemUptime;}else{networkReader.readabilityHandler=nil;networkReader=nil;}
    [output closeFile];
}
- (void)stop { stopped=true;++networkGeneration;networkReader.readabilityHandler=nil;if(networkTask.running)[networkTask terminate];networkReader=nil;networkTask=nil; }
@end

BOOL MallardTelemetryTests(void) {
    BOOL ok=[MallardBytes(999) isEqual:@"999 B"] && [MallardBytes(1000) isEqual:@"1.0 KB"] && [MallardBytes(1000000) isEqual:@"1.0 MB"] && [MallardBytes(2500000000) isEqual:@"2.5 GB"];
    ok=ok && [MallardRate(1000000) isEqual:@"8.00 Mbps"] && [MallardRate(0) isEqual:@"0.00 Mbps"];
    ok=ok && fabs(CPUShare(100,1000000100,1,10,1)-10)<.001 && CPUShare(200,100,1,10,1)==0;
    ok=ok && fabs(CPUShare(0,24000000,1,10,125.0/3)-10)<.001;
    NSDictionary *rows=NetworkRows(@",bytes_in,bytes_out,\nMallard.42,1200,600,\nMallard Helper.43,99,10,\n");
    ok=ok && [rows[@42][0] integerValue]==1200 && [rows[@43][1] integerValue]==10 && rows.count==2;
    ok=ok && NetworkRows(@",bytes_in,bytes_out,\nMallard.44,n/a,0,\n").count==0;
    fprintf(stderr,"Telemetry checks: %s\n",ok?"passed":"failed");return ok;
}
