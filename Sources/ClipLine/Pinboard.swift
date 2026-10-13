import AppKit
import SwiftUI

/// 用户自建标签（对齐 Paste 的 Pinboard）：名字 + 色点 + 顶栏里的顺序。
/// 条目可同时归入多个标签；标签只是引用，条目仍留在剪贴板历史里。
struct Pinboard: Identifiable, Equatable {
    let id: UUID
    var name: String
    var color: PinboardColor
    var position: Int
}

/// 标签色板：Paste 标签右键里那排 8 个色点（系统色）。
enum PinboardColor: String, CaseIterable {
    case red, orange, yellow, green, blue, purple, pink, gray

    var displayName: String {
        switch self {
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .blue: return "蓝"
        case .purple: return "紫"
        case .pink: return "粉"
        case .gray: return "灰"
        }
    }

    var color: Color {
        switch self {
        case .red: return Color(.sRGB, red: 1.00, green: 0.23, blue: 0.19)
        case .orange: return Color(.sRGB, red: 1.00, green: 0.58, blue: 0.00)
        case .yellow: return Color(.sRGB, red: 1.00, green: 0.80, blue: 0.00)
        case .green: return Color(.sRGB, red: 0.20, green: 0.78, blue: 0.35)
        case .blue: return Color(.sRGB, red: 0.00, green: 0.48, blue: 1.00)
        case .purple: return Color(.sRGB, red: 0.75, green: 0.35, blue: 0.95)
        case .pink: return Color(.sRGB, red: 1.00, green: 0.18, blue: 0.33)
        case .gray: return Color(.sRGB, red: 0.56, green: 0.56, blue: 0.58)
        }
    }
}

/// 磁盘上的标签行。
struct PinboardRecord {
    var id: UUID
    var name: String
    var color: String
    var position: Int
}
