import Foundation

/// 已知形象：内置（随 App 打包）与可下载（设置页一键下载）。设计见 docs/desktop-pet/PACKS.md。
///
/// 素材全部放在本仓库（公开仓库，只收 CC0 / CC-BY 这类允许再分发的素材，署名写在各形象文件夹的
/// CREDITS.txt 与设置页）：
/// - 内置：`mac/Sources/Resources/Pets/<id>/`，以文件夹引用整体打进 `Baobox.app/Contents/Resources/Pets/`；
/// - 可下载：`assets/pets/<id>/`，不进 App 包，下载地址钉在 `revision` 这个提交上，逐文件校验大小 + SHA-256。
struct PetPackInfo {
    struct File {
        let name: String
        let size: Int64
        let sha256: String
    }

    let id: String
    /// 按界面语言的显示名。
    let name: String
    /// 作者 · 许可，设置页署名用（CC-BY 素材必须署名）。
    let credit: String
    /// 可下载形象的文件清单；内置形象为空。
    let files: [File]

    var byteSize: Int64 { files.reduce(0) { $0 + $1.size } }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

enum PetCatalog {
    /// 可下载素材所在的提交。素材只增不改：要换图就提交新文件、改这里和下面的校验值。
    static let revision = "661547da6b8e0402cb58a613f5c7891a7433565c"

    /// 按顺序尝试：GitHub 原始文件 → jsDelivr（国内网络更稳）。
    static var mirrors: [String] {
        [
            "https://raw.githubusercontent.com/qiaob/baobox_mac/\(revision)/assets/pets/",
            "https://cdn.jsdelivr.net/gh/qiaob/baobox_mac@\(revision)/assets/pets/",
        ]
    }

    static let builtIn: [PetPackInfo] = [
        PetPackInfo(id: "plush-cat", name: L("pet.pack.plush-cat"), credit: "BabyPurrPal", files: []),
        PetPackInfo(id: "plush-dog", name: L("pet.pack.plush-dog"), credit: "BabyPurrPal", files: []),
        PetPackInfo(id: "plush-bunny", name: L("pet.pack.plush-bunny"), credit: "BabyPurrPal", files: []),
    ]

    static let downloadable: [PetPackInfo] = [
        PetPackInfo(id: "shiba", name: L("pet.pack.shiba"), credit: "Quaternius", files: [
            .init(name: "pet.json", size: 212, sha256: "df9462cc07f97ad2d322bfc680d1173b24c74597d7afac125c072d226df2f368"),
            .init(name: "model.glb", size: 851196, sha256: "9cbd4f1e12f85024126eab6a2c5706c099196df1a10db74e6c8b67bac3fff54a"),
        ]),
        PetPackInfo(id: "husky", name: L("pet.pack.husky"), credit: "Quaternius", files: [
            .init(name: "pet.json", size: 212, sha256: "df9462cc07f97ad2d322bfc680d1173b24c74597d7afac125c072d226df2f368"),
            .init(name: "model.glb", size: 927536, sha256: "a1e107ec4c2c62ce8cad86f750a7f6f9f2065c691dc6f88fce39667d3f4877eb"),
        ]),
        PetPackInfo(id: "fox", name: L("pet.pack.fox"), credit: "Quaternius", files: [
            .init(name: "pet.json", size: 212, sha256: "df9462cc07f97ad2d322bfc680d1173b24c74597d7afac125c072d226df2f368"),
            .init(name: "model.glb", size: 960228, sha256: "9917771e1414c46557b011cbaaee6de82a827605008227a364c3862f0be62ddc"),
        ]),
        PetPackInfo(id: "pug", name: L("pet.pack.pug"), credit: "Quaternius", files: [
            .init(name: "pet.json", size: 311, sha256: "7551b3c21243a4f803d60bedc6e9a8f803c59dc63cd8949e34ff88fdd4be2d47"),
            .init(name: "model.glb", size: 460496, sha256: "31ec7b2dcece73228760fbce8b1520883c13f7b2bcb94dee0d755c201f87c149"),
        ]),
        PetPackInfo(id: "cube-cat", name: L("pet.pack.cube-cat"), credit: "Kenney", files: [
            .init(name: "pet.json", size: 125, sha256: "09648d838a1171c6c54135270bf688129f93bb2956251aaff1c59529c70991e2"),
            .init(name: "model.glb", size: 95192, sha256: "b00463ca440787774c26db3d5617ae3474664ba556566fb1142f43270d84d644"),
        ]),
        PetPackInfo(id: "cube-dog", name: L("pet.pack.cube-dog"), credit: "Kenney", files: [
            .init(name: "pet.json", size: 125, sha256: "09648d838a1171c6c54135270bf688129f93bb2956251aaff1c59529c70991e2"),
            .init(name: "model.glb", size: 73172, sha256: "4e0fadb99d34c05329449474c0dba1a3fd5185efbc7f993799a71f7e28265078"),
        ]),
        PetPackInfo(id: "robot", name: L("pet.pack.robot"), credit: "three.js · Tomás Laulhé", files: [
            .init(name: "pet.json", size: 253, sha256: "e6ad9959f13f5d83d067c7c70cac2fcafc6821a9bd9e4c841836302fe15d8dbb"),
            .init(name: "model.glb", size: 463988, sha256: "047f5e5fb3bb6d378bd1df16ca6137f2a596c99b3a1b5690b4020c05aaf6f319"),
        ]),
    ]

    static func info(for id: String) -> PetPackInfo? {
        builtIn.first { $0.id == id } ?? downloadable.first { $0.id == id }
    }
}
