#import "BBXObjC.h"

@implementation BBXObjC

+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *description = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""];
            *error = [NSError errorWithDomain:@"BBXObjCException"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: description}];
        }
        return NO;
    }
}

@end
