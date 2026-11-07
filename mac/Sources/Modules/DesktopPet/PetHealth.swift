import Foundation
import os
import SceneKit

/// 宠物模块的日志（docs/desktop-pet/WAKE.md）：睡眠 / 唤醒、动画重启、看门狗、挪窝。
/// 查看：`log show --last 1d --predicate 'subsystem == "com.baobox.app" AND category == "pet"'`
enum PetLog {
    static let log = Logger(subsystem: "com.baobox.app", category: "pet")
}

/// 3D 视图的出帧计数：SceneKit 每渲染一帧调一次 `renderer(_:updateAtTime:)`（在它自己的渲染线程上），
/// 看门狗每秒在主线程取走一次。用来分辨「不出画面」和「出画面但骨骼不动」两种卡法。
final class PetRenderHeartbeat: NSObject, SCNSceneRendererDelegate {
    private let lock = NSLock()
    private var frames = 0

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        lock.lock()
        frames += 1
        lock.unlock()
    }

    /// 上次取走以来出了几帧（取完清零）。
    func take() -> Int {
        lock.lock()
        defer {
            frames = 0
            lock.unlock()
        }
        return frames
    }
}

/// 头跟着鼠标转的目标角度：主线程每帧写，SceneKit 渲染线程在约束里读（docs/desktop-pet/SETTLE.md §5.3）。
final class PetLookState {
    private let lock = NSLock()
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var influence: Float = 0

    func set(yaw: Float, pitch: Float, influence: Float) {
        lock.lock()
        self.yaw = yaw
        self.pitch = pitch
        self.influence = influence
        lock.unlock()
    }

    func read() -> (yaw: Float, pitch: Float, influence: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (yaw, pitch, influence)
    }
}
