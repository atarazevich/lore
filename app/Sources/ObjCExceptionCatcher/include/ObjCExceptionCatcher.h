#import <Foundation/Foundation.h>

/// Executes a block inside an Objective-C @try/@catch.
/// Returns YES on success, NO if an NSException was thrown.
/// If an exception is caught and errorOut is non-NULL, it receives a description string.
BOOL LRECatchException(void (NS_NOESCAPE ^_Nonnull block)(void),
                        NSString *_Nullable __autoreleasing *_Nullable errorOut);
