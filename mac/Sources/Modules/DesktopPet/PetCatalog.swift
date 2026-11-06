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
    static let revision = "1c39c54a57497f487e296d33de96927db9f734be"

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
            .init(name: "pet.json", size: 596, sha256: "22852148c98f0e643190981919e55c77ed781ad019e37fb5ed279dcdbb55ab0f"),
            .init(name: "model.glb", size: 851196, sha256: "9cbd4f1e12f85024126eab6a2c5706c099196df1a10db74e6c8b67bac3fff54a"),
        ]),
        PetPackInfo(id: "husky", name: L("pet.pack.husky"), credit: "Quaternius", files: [
            .init(name: "pet.json", size: 596, sha256: "22852148c98f0e643190981919e55c77ed781ad019e37fb5ed279dcdbb55ab0f"),
            .init(name: "model.glb", size: 927536, sha256: "a1e107ec4c2c62ce8cad86f750a7f6f9f2065c691dc6f88fce39667d3f4877eb"),
        ]),
        PetPackInfo(id: "fox", name: L("pet.pack.fox"), credit: "Quaternius", files: [
            .init(name: "pet.json", size: 596, sha256: "22852148c98f0e643190981919e55c77ed781ad019e37fb5ed279dcdbb55ab0f"),
            .init(name: "model.glb", size: 960228, sha256: "9917771e1414c46557b011cbaaee6de82a827605008227a364c3862f0be62ddc"),
        ]),
        PetPackInfo(id: "pug", name: L("pet.pack.pug"), credit: "Quaternius", files: [
            .init(name: "pet.json", size: 794, sha256: "d8b3049083dd8ca2d996a0aa3b549aedbeac0a3ae5600aecfdfef8dbb817d1d1"),
            .init(name: "model.glb", size: 460496, sha256: "31ec7b2dcece73228760fbce8b1520883c13f7b2bcb94dee0d755c201f87c149"),
        ]),
        PetPackInfo(id: "panda", name: L("pet.pack.panda"), credit: "Quaternius", files: [
            .init(name: "pet.json", size: 1760, sha256: "6cc4eb30b7ffbd8e428fe8db9a60789317d298a361dcb345a8c87e9c171877d9"),
            .init(name: "model.glb", size: 625748, sha256: "09c6f59cabf681ebcedca595645291eed2162c6e47d50b02d410fed5ddedc7ad"),
        ]),
        PetPackInfo(id: "rabbit", name: L("pet.pack.rabbit"), credit: "Quaternius", files: [
            .init(name: "pet.json", size: 1760, sha256: "6cc4eb30b7ffbd8e428fe8db9a60789317d298a361dcb345a8c87e9c171877d9"),
            .init(name: "model.glb", size: 640356, sha256: "f97a7c07b367e829a0d5ca6a2609f353fbac5ddcd8bbd073b4b03a1f9de663de"),
        ]),
        PetPackInfo(id: "frog", name: L("pet.pack.frog"), credit: "Quaternius", files: [
            .init(name: "pet.json", size: 819, sha256: "50bef90b87b6b4c122cc32386afa52cd004e2944fe9bbf36a0250b7f1fb24e25"),
            .init(name: "model.glb", size: 379892, sha256: "e649e23848548c74f22a22071ebcd5ddcf78254a9f4ce94417078a7431482309"),
        ]),
        PetPackInfo(id: "raccoon", name: L("pet.pack.raccoon"), credit: "Quaternius", files: [
            .init(name: "pet.json", size: 895, sha256: "1a4196d2779a9846e3e9c9e31ea85d2fb53724318f3ca85baa92fb1d0ba4b344"),
            .init(name: "model.glb", size: 238560, sha256: "4844072432a3e474ef32426d3d74be895fe9e203d643d26670e5a23da6d7fc5a"),
        ]),
        PetPackInfo(id: "chick", name: L("pet.pack.chick"), credit: "Quaternius", files: [
            .init(name: "pet.json", size: 716, sha256: "2a8abf85cbc30db0fea2f59b3800bd68d25a89475436be107199dd4f64112847"),
            .init(name: "model.glb", size: 157592, sha256: "8ce75b5c8c1e7a631508941b742c0271f83239dfbecc44266d1c71f5db895dee"),
        ]),
        PetPackInfo(id: "cat-blob", name: L("pet.pack.cat-blob"), credit: "Quaternius", files: [
            .init(name: "pet.json", size: 656, sha256: "e0098c8de2549356387179a1153f7c4e86f5d2cf2e1a7004f2f972dcfc838a2e"),
            .init(name: "model.glb", size: 111948, sha256: "aa098d43c1006110d5a4fa3a6e6d4c843c8d8d90ffccc48f5bf32e3aadf7a3a9"),
        ]),
        PetPackInfo(id: "cube-cat", name: L("pet.pack.cube-cat"), credit: "Kenney", files: [
            .init(name: "pet.json", size: 251, sha256: "98d22196b5acc751e7a07a3c1111af917b9adca29342494b6d31bd5acc18aafc"),
            .init(name: "model.glb", size: 95192, sha256: "b00463ca440787774c26db3d5617ae3474664ba556566fb1142f43270d84d644"),
        ]),
        PetPackInfo(id: "cube-dog", name: L("pet.pack.cube-dog"), credit: "Kenney", files: [
            .init(name: "pet.json", size: 251, sha256: "98d22196b5acc751e7a07a3c1111af917b9adca29342494b6d31bd5acc18aafc"),
            .init(name: "model.glb", size: 73172, sha256: "4e0fadb99d34c05329449474c0dba1a3fd5185efbc7f993799a71f7e28265078"),
        ]),
        PetPackInfo(id: "cube-bunny", name: L("pet.pack.cube-bunny"), credit: "Kenney", files: [
            .init(name: "pet.json", size: 251, sha256: "98d22196b5acc751e7a07a3c1111af917b9adca29342494b6d31bd5acc18aafc"),
            .init(name: "model.glb", size: 73748, sha256: "3d5c2b7c6961c1d780ac2f4478f6ea8dbf93aaccd6055a33bbc27f73dcc62402"),
        ]),
        PetPackInfo(id: "cube-pig", name: L("pet.pack.cube-pig"), credit: "Kenney", files: [
            .init(name: "pet.json", size: 251, sha256: "98d22196b5acc751e7a07a3c1111af917b9adca29342494b6d31bd5acc18aafc"),
            .init(name: "model.glb", size: 67796, sha256: "20807e00b6f9404e3f3925aa8f8ebfcf1d1fb30455316573085e4669a2cadd3e"),
        ]),
        PetPackInfo(id: "cube-lion", name: L("pet.pack.cube-lion"), credit: "Kenney", files: [
            .init(name: "pet.json", size: 251, sha256: "98d22196b5acc751e7a07a3c1111af917b9adca29342494b6d31bd5acc18aafc"),
            .init(name: "model.glb", size: 109456, sha256: "ed7d21e1f039c46220e8597e9e98ab021e399d361b2f6c7185d701bcdf0bfcbd"),
        ]),
        PetPackInfo(id: "robot", name: L("pet.pack.robot"), credit: "three.js · Tomás Laulhé", files: [
            .init(name: "pet.json", size: 642, sha256: "41a8ae59d34a8a8099a32765b8b5f30eedc5ea65e501590c011fbd994daa4364"),
            .init(name: "model.glb", size: 463988, sha256: "047f5e5fb3bb6d378bd1df16ca6137f2a596c99b3a1b5690b4020c05aaf6f319"),
        ]),
        // VRM 人形（docs/desktop-pet/VRM.md §7）：作者在 VRoid Hub 上允许他人使用、改模、再分发；
        // 贴图已从 2048 压到 1024（< 20 MB，jsDelivr 单文件上限），其余原样。
        PetPackInfo(id: "vroid-toka", name: L("pet.pack.vroid-toka"), credit: "あわ · VRoid Hub", files: [
            .init(name: "pet.json", size: 27, sha256: "3a9e0afc4b531c9986c04d4238cadbbabe611e4c16888e8c102e820453d2ab73"),
            .init(name: "model.vrm", size: 14653092, sha256: "5f718b2cdc846ccaee5b98aefcafecce784f8a5a873062dafe022a940fcba2eb"),
        ]),
        PetPackInfo(id: "vroid-alchemist", name: L("pet.pack.vroid-alchemist"), credit: "マユラ · VRoid Hub", files: [
            .init(name: "pet.json", size: 27, sha256: "3a9e0afc4b531c9986c04d4238cadbbabe611e4c16888e8c102e820453d2ab73"),
            .init(name: "model.vrm", size: 14079256, sha256: "c4f6e85326dc02d4ca7605f67fa0dde61b6139acc4d347665d9482517ad0440e"),
        ]),
    ]

    static func info(for id: String) -> PetPackInfo? {
        builtIn.first { $0.id == id } ?? downloadable.first { $0.id == id }
    }
}
