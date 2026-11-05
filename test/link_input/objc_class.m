// An Objective-C class through the runtime and Foundation (aarch64-macos):
// a message send, a synthesized property and an autorelease pool.
#import <Foundation/Foundation.h>

@interface Counter : NSObject
@property int n;
- (int)bump;
@end

@implementation Counter
- (int)bump {
    self.n += 1;
    return self.n;
}
@end

int f(void) {
    @autoreleasepool {
        Counter *c = [Counter new];
        [c bump];
        [c bump];
        return [c bump];
    }
}
