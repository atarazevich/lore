#import "include/ObjCExceptionCatcher.h"

BOOL LRECatchException(void (NS_NOESCAPE ^_Nonnull block)(void),
                        NSString *_Nullable __autoreleasing *_Nullable errorOut) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"%@: %@",
                         exception.name, exception.reason ?: @"(no reason)"];
        }
        return NO;
    }
}
