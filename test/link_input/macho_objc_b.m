// A root class of its own (no Foundation), for MachOInput's tests.
__attribute__((objc_root_class))
@interface RootB
+ (int)answer;
@end
@implementation RootB
+ (int)answer { return 42; }
@end
int call_b(void) { return [RootB answer]; }
