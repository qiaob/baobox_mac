import Foundation

/// Vimium 式标签生成：给 N 个元素分配**最短、互不为前缀**的字母标签。
///
/// BFS：从单字符起，队首前缀扩展成 k 个孩子（前缀本身变内部节点），未被扩展的即叶子；
/// 叶子互不为前缀，且短的先产出。
enum HintLabelGenerator {
    static func labels(count: Int, chars: String) -> [String] {
        let alphabet = Array(chars).map { String($0) }
        let k = alphabet.count
        guard k >= 1, count >= 1 else { return [] }
        if k == 1 {
            // 退化：单字符集只能用递增长度（a, aa, aaa…）。实践中字符集恒 >1，不会走到。
            return (0..<count).map { String(repeating: alphabet[0], count: $0 + 1) }
        }
        var nodes = alphabet
        var head = 0
        while (nodes.count - head) < count {
            let prefix = nodes[head]; head += 1
            for c in alphabet { nodes.append(prefix + c) }
        }
        return Array(nodes[head...].prefix(count))
    }
}
