#import <Foundation/Foundation.h>
#import "Tweak.h"

@interface NSObject (GoldgramNativeArchiveMetadataContract)
+ (void)resolve:(NSDictionary *)request completion:(void (^)(NSDictionary *))completion;
@end

// Runtime-only boundary: Mx does not link against TelegramUI or duplicate peers.
void goldgramResolveNativeMetadata(NSDictionary *request, void (^completion)(NSDictionary *)) {
    Class resolver = NSClassFromString(@"GoldgramNativeArchiveMetadata");
    if (![resolver respondsToSelector:@selector(resolve:completion:)]) {
        completion(@{@"status": @"unavailable", @"items": @[]});
        return;
    }
    // Native Postbox work is bounded and asynchronous. Fall back to IDs if a
    // stalled transaction outlives this screen; never keep the archive loading.
    __block BOOL finished = NO;
    void (^finish)(NSDictionary *) = ^(NSDictionary *answer) {
        if (finished) return;
        finished = YES;
        completion(answer);
    };
    [resolver resolve:request completion:finish];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        finish(@{@"status": @"unavailable", @"items": @[]});
    });
}
