import SwiftUI
import CodexHarborCore

struct SessionManagerView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var filter = "全部"
    @State private var group = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("会话管理").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("删除会话会移入回收站，不删除原始内容；分组仅保存在 Harbor。").font(.caption).foregroundStyle(.secondary)
            HStack { Picker("分组", selection: $filter) { Text("全部").tag("全部"); Text("未分组").tag("未分组"); ForEach(Array(Set(model.sessions.compactMap(\.group))).sorted(), id: \.self) { Text($0).tag($0) } }.frame(width: 150); Spacer(); Button("刷新") { Task { await model.refreshSessions() } }; Button("移入回收站", role: .destructive) { Task { await model.deleteSessions(selected); selected.removeAll() } }.disabled(selected.isEmpty); Button("恢复") { Task { await model.restoreSessions(selected); selected.removeAll() } }.disabled(selected.isEmpty) }
            List(selection: $selected) {
                ForEach(groupedKeys, id: \.self) { key in
                    Section { ForEach(model.sessions.filter { ($0.group ?? "未分组") == key && (filter == "全部" || key == filter) }) { s in HStack { Image(systemName: s.deleted ? "trash" : "bubble.left.and.bubble.right"); Text(s.title).lineLimit(1); Spacer(); if s.deleted { Text("回收站").font(.caption2).foregroundStyle(.secondary) } }.tag(s.id) } } header: { Label(key, systemImage: "folder") }
                }
            }
            HStack { TextField("分组名称", text: $group); Button("设置分组") { let g = group.trimmingCharacters(in: .whitespacesAndNewlines); guard !g.isEmpty else { return }; Task { await model.groupSessions(selected, group: g); group = "" } }.disabled(selected.isEmpty || group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty); Button("取消分组") { Task { await model.groupSessions(selected, group: nil) } }.disabled(selected.isEmpty) }
        }
    }
    private var groupedKeys: [String] { Array(Set(model.sessions.map { $0.group ?? "未分组" })).sorted() }
}
