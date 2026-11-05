// A root class of its own (no Foundation), for MachOInput's tests.
__attribute__((objc_root_class))
@interface RootA
+ (int)answer;
@end
@implementation RootA
+ (int)answer { return 42; }
@end
int call_a(void) { return [RootA answer]; }
