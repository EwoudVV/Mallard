#import <Foundation/Foundation.h>

NSString *MallardBytes(double bytes);
NSString *MallardRate(double bytes);
BOOL MallardTelemetryTests(void);

@interface MallardTelemetry : NSObject
@property(readonly) NSDictionary<NSNumber *,NSDictionary *> *processes;
@property(readonly) uint64_t memory;
@property(readonly) double cpu;
@property(readonly) BOOL networkReady;
@property(readonly) double downloadRate;
@property(readonly) double uploadRate;
@property(readonly) uint64_t downloaded;
@property(readonly) uint64_t uploaded;
- (void)sample;
- (void)stop;
@end
