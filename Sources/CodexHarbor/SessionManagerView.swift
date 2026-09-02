import SwiftUI
import CodexHarborCore

struct SessionManagerView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var filter = "全部"
    @State private var group = ""
    @State private var renameID: String?
    @State private var renameText = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleBar
            Text("删除会话会移入回收站，不删除原始内容；分组仅保存在 Harbor。").font(.caption).foregroundStyle(.secondary)
            toolbar
            List(selection: $selected) {
                ForEach(groupedKeys, id: \.self) { key in
                    DisclosureGroup {
                        ForEach(sessions(in: key)) { s in sessionRow(s) }
                    } label: {
                        Label(key, systemImage: "folder")
                            .onDrop(of: [.text], isTargeted: nil) { providers in
                                for provider in providers { provider.loadObject(ofClass: NSString.self) { object, _ in if let id = object as? NSString { Task { await model.groupSessions([id as String], group: key) } } } }
                                return true
                            }
                    }
                }
            }
            footer
        }
        .alert("编辑任务名称", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) { TextField("任务名称", text: $renameText); Button("保存") { if let id = renameID { Task { await model.renameSession(id, title: renameText) }; renameID = nil } }; Button("取消", role: .cancel) { renameID = nil } }
    }
    private var groupedKeys: [String] { Array(Set(model.sessions.map { $0.group ?? "未分组" })).sorted() }
    private func sessions(in key: String) -> [CodexSessionEntry] { model.sessions.filter { ($0.group ?? "未分组") == key && (filter == "全部" || key == filter) } }
    private var titleBar: some View { HStack { Text("会话管理").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } } }
    private var toolbar: some View { HStack { Picker("分组", selection: $filter) { Text("全部").tag("全部"); Text("未分组").tag("未分组"); ForEach(Array(Set(model.sessions.compactMap(\.group))).sorted(), id: \.self) { Text($0).tag($0) } }.frame(width: 150); Spacer(); Button("刷新") { Task { await model.refreshSessions() } }; Button("移入回收站", role: .destructive) { Task { await model.deleteSessions(selected); selected.removeAll() } }.disabled(selected.isEmpty); Button("恢复") { Task { await model.restoreSessions(selected); selected.removeAll() } }.disabled(selected.isEmpty) } }
    private var footer: some View { HStack { TextField("分组名称", text: $group); Button("设置分组") { let g = group.trimmingCharacters(in: .whitespacesAndNewlines); guard !g.isEmpty else { return }; Task { await model.groupSessions(selected, group: g); group = "" } }.disabled(selected.isEmpty || group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty); Button("取消分组") { Task { await model.groupSessions(selected, group: nil) } }.disabled(selected.isEmpty) } }

    @ViewBuilder private func sessionRow(_ s: CodexSessionEntry) -> some View {
        HStack { Image(systemName: s.deleted ? "trash" : "bubble.left.and.bubble.right"); Text(s.title).lineLimit(1); Spacer(); if s.deleted { Text("回收站").font(.caption2).foregroundStyle(.secondary) } }
            .tag(s.id).onDrag { NSItemProvider(object: s.id as NSString) }
            .contextMenu { Button("编辑名称") { renameID = s.id; renameText = s.title }; Button("移入回收站", role: .destructive) { Task { await model.deleteSessions([s.id]) } }; Button("恢复") { Task { await model.restoreSessions([s.id]) } }; Button("取消分组") { Task { await model.groupSessions([s.id], group: nil) } } }
    }
}
