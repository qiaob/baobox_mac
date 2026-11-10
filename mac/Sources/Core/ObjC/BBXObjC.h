#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C 异常转成 Swift 能接住的错误。
///
/// 有些系统 API 出错时不返回错误、而是抛 Objective-C 异常（如 AVFAudio 的
/// `installTapOnBus:` 在格式和设备对不上时抛 "required condition is false"）。
/// Swift 接不住这种异常，进程直接 abort —— 2026-11-10 换蓝牙耳机时整个 App 因此崩溃。
/// 只用来包这类调用，别拿它吞掉自己代码里的错误。
@interface BBXObjC : NSObject

/// 执行 `block`；里面抛出的 Objective-C 异常被接住，转成 NSError（domain `BBXObjCException`，
/// `localizedDescription` = 异常名 + 原因）。Swift 里是 `try BBXObjC.catchException { … }`。
+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
