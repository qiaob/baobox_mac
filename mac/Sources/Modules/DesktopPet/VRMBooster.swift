import AppKit
import SceneKit
import simd

/// 背包式助推器（远的、高的地方飞过去）：两个白色推进筒（红箍 + 背面红十字 + 顶上蓝灯）挂在上胸骨背后，筒顶从肩膀后面冒出来，
/// 喷口在腰后往斜下方两边撇。火焰是三层圆锥（红外沿 → 橙 → 白黄芯）+ 根部亮球 + 暖色光晕，自己闪烁；火星、烟用粒子。
/// 默认藏着。show / hide 带回弹；thrust 0 熄火、0.45 慢慢降下来、1 全开，火焰长短亮暗和粒子多少平滑跟上
/// （SCNTransaction 隐式动画、SCNAction、CAKeyframeAnimation、SCNParticleSystem，不用每帧回调）。
/// 宠物窗是透明的、背后什么颜色都有：火焰用正常混合的卡通色块加半透明光晕 —— 叠加发光在浅色背景上会发白看不见。
/// 挂在模型骨骼上，换形象时跟着旧模型一起丢掉，新模型重新建一个。
final class VRMBooster {
    /// 弹出 / 收起时缩放的节点。
    private let root = SCNNode()
    private var flames: [Flame] = []
    private var sparks: [SCNParticleSystem] = []
    private var smoke: [SCNParticleSystem] = []

    /// 0 熄火，0.45 慢慢降下来（悬停），1 全开；改了以后火焰在 0.2 s 里跟过去。
    var thrust: Float = 0 {
        didSet { if !settingQuietly { applyThrust(animated: true) } }
    }
    private var settingQuietly = false

    /// 挂在 upperChest（没有就 chest、spine）上；骨骼都没有返回 nil。
    init?(rig: VRMRig) {
        guard let boneName = ["upperChest", "chest", "spine"].first(where: { rig.bones[$0] != nil }),
              let bone = rig.bones[boneName] else { return nil }
        // 按腿长缩放（ぱペコ 的腿长 0.646 = 1）：大个子模型背大一点的筒。
        let k = max((rig.body.thigh + rig.body.shin) / 0.646, 0.3)
        let white = Self.toon(.white, shade: SIMD3(0.74, 0.8, 0.92))
        let red = Self.toon(NSColor(srgbRed: 0.86, green: 0.17, blue: 0.22, alpha: 1), shade: SIMD3(0.72, 0.55, 0.62))
        let navy = Self.toon(NSColor(srgbRed: 0.17, green: 0.25, blue: 0.56, alpha: 1), shade: SIMD3(0.62, 0.62, 0.78))
        let metal = Self.toon(NSColor(white: 0.38, alpha: 1), shade: SIMD3(0.6, 0.62, 0.68))
        let sparkImage = Self.radialImage([(0, NSColor(white: 1, alpha: 1)), (0.4, NSColor(white: 1, alpha: 0.6)),
                                           (1, NSColor(white: 1, alpha: 0))])
        let smokeImage = Self.radialImage([(0, NSColor(white: 1, alpha: 0.95)), (0.55, NSColor(white: 1, alpha: 0.5)),
                                           (1, NSColor(white: 1, alpha: 0))])

        let pack = SCNNode()
        pack.simdScale = SIMD3(repeating: k)
        root.addChildNode(pack)
        // 中间一块深蓝圆角背板，贴着背。
        let plate = SCNNode(geometry: SCNBox(width: 0.13, height: 0.2, length: 0.03, chamferRadius: 0.014))
        plate.geometry?.materials = [navy]
        plate.simdPosition = SIMD3(0, 0, 0.035)
        pack.addChildNode(plate)
        for (index, side) in [Float(-1), 1].enumerated() {
            let tube = SCNNode()
            tube.simdPosition = SIMD3(side * 0.105, 0, 0)
            tube.simdEulerAngles = SIMD3(0, 0, side * 0.12)   // 下面往外撇
            pack.addChildNode(tube)
            func part(_ geometry: SCNGeometry, _ material: SCNMaterial, _ position: SIMD3<Float>) {
                geometry.materials = [material]
                let node = SCNNode(geometry: geometry)
                node.simdPosition = position
                tube.addChildNode(node)
            }
            part(SCNCapsule(capRadius: 0.05, height: 0.33), white, .zero)
            part(SCNCylinder(radius: 0.0515, height: 0.026), red, SIMD3(0, -0.07, 0))
            part(SCNBox(width: 0.04, height: 0.013, length: 0.007, chamferRadius: 0.002), red, SIMD3(0, 0.035, -0.049))
            part(SCNBox(width: 0.013, height: 0.04, length: 0.007, chamferRadius: 0.002), red, SIMD3(0, 0.035, -0.049))
            part(SCNSphere(radius: 0.02), navy, SIMD3(0, 0.168, 0))
            part(SCNCone(topRadius: 0.03, bottomRadius: 0.041, height: 0.04), metal, SIMD3(0, -0.183, 0))
            part(SCNTorus(ringRadius: 0.041, pipeRadius: 0.0065), red, SIMD3(0, -0.203, 0))
            // 喷口：火往本地 −Y 喷。
            let exit = SCNNode()
            exit.simdPosition = SIMD3(0, -0.205, 0)
            tube.addChildNode(exit)
            let flame = Flame(length: 0.44, radius: 0.07, flickerPeriod: index == 0 ? 0.47 : 0.53)
            exit.addChildNode(flame.node)
            flames.append(flame)
            let spark = Self.sparkSystem(image: sparkImage)
            let puff = Self.smokeSystem(image: smokeImage)
            exit.addParticleSystem(spark)
            exit.addParticleSystem(puff)
            sparks.append(spark)
            smoke.append(puff)
        }

        // 规范化空间（面朝 +Z）里的位置换到骨骼本地：背在上背，中心在这根骨骼后面一点。
        let flip = rig.isVRM0 ? simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0)) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let toLocal = (bone.parentWorldRest * bone.restLocal).inverse * flip
        let frame = SCNNode()
        frame.simdOrientation = toLocal
        frame.simdPosition = toLocal.act(SIMD3(0, -0.02 * k, -0.175 * k)) / bone.parentWorldScale
        frame.addChildNode(root)
        bone.node.addChildNode(frame)
        root.isHidden = true
        root.simdScale = SIMD3(repeating: 0.001)
        applyThrust(animated: false)
    }

    /// 宠物动画整个重建以后（模型子树上的动画都被清掉了）：把火焰的闪烁、光晕的明暗装回去。
    func restartEffects() {
        for flame in flames { flame.startEffects() }
    }

    /// 弹出来：0.35 s，从 0 放大到 1.18 再回到 1（animated = false 直接出现）。
    func show(animated: Bool) {
        root.removeAction(forKey: "pop")
        root.isHidden = false
        guard animated else {
            root.simdScale = SIMD3(repeating: 1)
            return
        }
        root.simdScale = SIMD3(repeating: 0.001)
        let grow = SCNAction.scale(to: 1.18, duration: 0.23)
        grow.timingMode = .easeOut
        let settle = SCNAction.scale(to: 1, duration: 0.12)
        settle.timingMode = .easeInEaseOut
        root.runAction(.sequence([grow, settle]), forKey: "pop")
    }

    /// 收起来（同时熄火）：先胀一下再缩没，0.3 s。
    func hide(animated: Bool) {
        thrust = 0
        root.removeAction(forKey: "pop")
        guard animated, !root.isHidden else {
            root.isHidden = true
            root.simdScale = SIMD3(repeating: 0.001)
            return
        }
        let swell = SCNAction.scale(to: 1.12, duration: 0.08)
        swell.timingMode = .easeOut
        let shrink = SCNAction.scale(to: 0.001, duration: 0.22)
        shrink.timingMode = .easeIn
        root.runAction(.sequence([swell, shrink, .hide()]), forKey: "pop")
    }

    /// 和设 thrust 一样，只是可以不带过渡（取景、出静帧时用）。
    func setThrust(_ value: Float, animated: Bool) {
        settingQuietly = true
        thrust = value
        settingQuietly = false
        applyThrust(animated: animated)
    }

    private func applyThrust(animated: Bool) {
        let t = min(max(thrust, 0), 1)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.2 : 0
        for flame in flames { flame.set(throttle: t) }
        SCNTransaction.commit()
        for system in sparks { system.birthRate = CGFloat(70 * t) }
        for system in smoke { system.birthRate = CGFloat(16 * t) }
    }

    // MARK: - 火焰

    /// 一个喷口的火：三层圆锥（外红、中橙、芯白黄）+ 根部亮球 + 光晕。原点在喷口，往本地 −Y 喷。
    /// thrustNode 按推力缩放（SCNTransaction 隐式动画跟过去），flickerNode 自己循环闪烁。
    private final class Flame {
        let node = SCNNode()
        private let thrustNode = SCNNode()
        private let halo: SCNNode
        private let haloMaterial: SCNMaterial
        private var materials: [(SCNMaterial, CGFloat)] = []

        init(length: Float, radius: Float, flickerPeriod: Double) {
            let flickerNode = SCNNode()
            let layers: [(NSColor, Float, Float, CGFloat)] = [
                (NSColor(srgbRed: 0.95, green: 0.2, blue: 0.08, alpha: 1), 1.0, 1.0, 0.72),
                (NSColor(srgbRed: 1, green: 0.55, blue: 0.08, alpha: 1), 0.76, 0.72, 0.9),
                (NSColor(srgbRed: 1, green: 0.95, blue: 0.62, alpha: 1), 0.48, 0.44, 1.0),
            ]
            for (layer, (color, lengthFactor, radiusFactor, alpha)) in layers.enumerated() {
                let h = CGFloat(length * lengthFactor)
                let cone = SCNCone(topRadius: CGFloat(radius * radiusFactor), bottomRadius: CGFloat(radius * radiusFactor * 0.06), height: h)
                cone.radialSegmentCount = 24
                let coneMaterial = VRMBooster.glow(color, alpha: alpha)
                cone.materials = [coneMaterial]
                materials.append((coneMaterial, alpha))
                let coneNode = SCNNode(geometry: cone)
                coneNode.simdPosition = SIMD3(0, -Float(h) / 2, 0)
                // 外层先画、芯最后画：从哪个角度看都透得出白黄的芯（按距离排序的话外层常常盖在芯上面）。
                coneNode.renderingOrder = 20 + layer
                flickerNode.addChildNode(coneNode)
                let bulb = SCNSphere(radius: CGFloat(radius * radiusFactor * 0.95))
                bulb.segmentCount = 16
                let bulbMaterial = VRMBooster.glow(color, alpha: alpha * 0.8)
                bulb.materials = [bulbMaterial]
                materials.append((bulbMaterial, alpha * 0.8))
                let bulbNode = SCNNode(geometry: bulb)
                bulbNode.simdPosition = SIMD3(0, -radius * radiusFactor * 0.5, 0)
                bulbNode.renderingOrder = 20 + layer
                flickerNode.addChildNode(bulbNode)
            }
            thrustNode.addChildNode(flickerNode)
            node.addChildNode(thrustNode)
            let plane = SCNPlane(width: CGFloat(radius * 9), height: CGFloat(radius * 9))
            haloMaterial = VRMBooster.glow(NSColor(srgbRed: 1, green: 0.7, blue: 0.28, alpha: 1), alpha: 0.75,
                                           texture: VRMBooster.radialImage([(0, NSColor(white: 1, alpha: 0.9)), (0.3, NSColor(white: 1, alpha: 0.4)),
                                                                            (1, NSColor(white: 1, alpha: 0))]))
            plane.materials = [haloMaterial]
            halo = SCNNode(geometry: plane)
            halo.renderingOrder = 18
            halo.simdPosition = SIMD3(0, -radius * 1.2, 0)
            halo.constraints = [SCNBillboardConstraint()]
            node.addChildNode(halo)

            self.flickerNode = flickerNode
            self.flickerPeriod = flickerPeriod
            startEffects()
            set(throttle: 0)
        }

        private let flickerNode: SCNNode
        private let flickerPeriod: Double

        /// 闪烁：长短、粗细不规则地抖（两个喷口周期不同，不会一起抖）；光晕亮暗跟着抖。
        /// 宠物动画整个重建时（PetModelView.restartAnimations 清掉模型子树上的所有动画）要再装一遍。
        func startEffects() {
            let flicker = CAKeyframeAnimation(keyPath: "scale")
            let shapes: [(Double, Double)] = [(1, 1), (1.04, 0.86), (0.97, 1.13), (1.02, 0.92), (0.98, 1.08), (1.03, 0.9), (1, 1)]
            flicker.values = shapes.map { NSValue(scnVector3: SCNVector3(CGFloat($0.0), CGFloat($0.1), CGFloat($0.0))) }
            flicker.keyTimes = [0, 0.16, 0.33, 0.5, 0.68, 0.84, 1]
            flicker.duration = flickerPeriod
            flicker.repeatCount = .infinity
            flickerNode.addAnimation(flicker, forKey: "pet.booster.flicker")
            let glow = CAKeyframeAnimation(keyPath: "opacity")
            glow.values = [1, 0.82, 1, 0.9, 1]
            glow.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            glow.duration = flickerPeriod * 0.8
            glow.repeatCount = .infinity
            halo.addAnimation(glow, forKey: "pet.booster.glow")
        }

        /// throttle 0–1（0 = 灭）：长度跟推力、粗细和亮度跟推力的平方根（小火也有点粗、不会细成一根线）。
        func set(throttle t: Float) {
            let width = 0.55 + 0.45 * sqrtf(t)
            thrustNode.simdScale = SIMD3(width, max(t, 0.001), width)
            let bright = CGFloat(t > 0.01 ? 0.55 + 0.45 * t : 0)
            for (material, alpha) in materials { material.transparency = alpha * bright }
            haloMaterial.transparency = 0.75 * bright
            halo.simdScale = SIMD3(repeating: 0.6 + 0.5 * t)
        }
    }

    // MARK: - 粒子

    /// 火星：从喷口往下溅，带重力，橙黄 → 红、变小变淡。
    private static func sparkSystem(image: NSImage) -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.loops = true
        system.birthRate = 0
        system.emissionDuration = 1
        system.particleLifeSpan = 0.42
        system.particleLifeSpanVariation = 0.15
        system.particleVelocity = 1.1
        system.particleVelocityVariation = 0.45
        system.emittingDirection = SCNVector3(0, -1, 0)
        system.spreadingAngle = 26
        system.acceleration = SCNVector3(0, -1.2, 0)
        system.particleSize = 0.02
        system.particleSizeVariation = 0.006
        system.particleImage = image
        system.particleColor = NSColor(srgbRed: 1, green: 0.82, blue: 0.4, alpha: 1)
        system.blendMode = .alpha
        system.isLightingEnabled = false
        system.isLocal = false
        let fade = CAKeyframeAnimation()
        fade.values = [1, 0.9, 0]
        fade.keyTimes = [0, 0.5, 1]
        system.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        return system
    }

    /// 烟：慢慢往后下方飘，越来越大、越来越淡，最后往上浮一点。
    private static func smokeSystem(image: NSImage) -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.loops = true
        system.birthRate = 0
        system.emissionDuration = 1
        system.particleLifeSpan = 1.0
        system.particleLifeSpanVariation = 0.3
        system.particleVelocity = 0.35
        system.particleVelocityVariation = 0.12
        system.emittingDirection = SCNVector3(0, -1, 0)
        system.spreadingAngle = 20
        system.dampingFactor = 1.5
        system.acceleration = SCNVector3(0, 0.05, 0)
        system.particleSize = 0.06
        system.particleImage = image
        // 中灰：浅色、深色背景上都看得出来（太白在浅色桌面上就没了）。
        system.particleColor = NSColor(white: 0.7, alpha: 1)
        system.blendMode = .alpha
        system.isLightingEnabled = false
        system.isLocal = false
        let grow = CAKeyframeAnimation()
        grow.values = [0.6, 1.5, 2.4]
        grow.keyTimes = [0, 0.4, 1]
        let fade = CAKeyframeAnimation()
        fade.values = [0, 0.75, 0.55, 0]
        fade.keyTimes = [0, 0.12, 0.5, 1]
        system.propertyControllers = [.size: SCNParticlePropertyController(animation: grow),
                                      .opacity: SCNParticlePropertyController(animation: fade)]
        return system
    }

    // MARK: - 材质与贴图

    /// 和模型一样的卡通光影（MToon 近似）。
    private static func toon(_ color: NSColor, shade: SIMD3<Float>) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        VRMToon.apply(to: material, params: VRMToonParams(shade: shade, shift: -0.05, toony: 0.85), alpha: .opaque)
        return material
    }

    /// 火焰、光晕：不受光照、不写深度（读深度，被身子挡住）、两面都画，正常透明混合。
    private static func glow(_ color: NSColor, alpha: CGFloat, texture: NSImage? = nil) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = texture ?? color
        if texture != nil { material.multiply.contents = color }
        material.transparency = alpha
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        return material
    }

    /// 中间亮、往外淡的圆点。
    private static func radialImage(_ stops: [(CGFloat, NSColor)], size: Int = 64) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext,
           let space = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(colorsSpace: space, colors: stops.map { $0.1.cgColor } as CFArray, locations: stops.map { $0.0 }) {
            let center = CGPoint(x: size / 2, y: size / 2)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: CGFloat(size) / 2, options: [])
        }
        image.unlockFocus()
        return image
    }
}
