import SwiftData
import SwiftUI

struct AppRoot: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }
            PatternListView()
                .tabItem { Label("图纸", systemImage: "square.grid.3x3.fill") }
            NavigationStack {
                TemplateGalleryView()
            }
            .tabItem { Label("模板", systemImage: "gift.fill") }
            WarehouseView()
                .tabItem { Label("豆仓", systemImage: "shippingbox.fill") }
            BoardTabView()
                .tabItem { Label("拼豆板", systemImage: "lightbulb.fill") }
        }
        .tint(.pink)
    }
}

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Pattern.updatedAt, order: .reverse) private var patterns: [Pattern]
    @EnvironmentObject var app: AppState
    @ObservedObject private var board = AppState.shared.board

    var inProgress: [Pattern] { patterns.filter { $0.status == .inProgress } }
    var done: [Pattern] { patterns.filter { $0.status == .done } }

    var body: some View {
        NavigationStack {
            List {
                Section("快速开始") {
                    NavigationLink { ConvertView() } label: {
                        Label("照片转图纸", systemImage: "photo.on.rectangle.angled")
                    }
                    NavigationLink { EditorView(pattern: nil, initialSize: 29) } label: {
                        Label("新建手绘画布", systemImage: "square.and.pencil")
                    }
                    NavigationLink { TemplateGalleryView() } label: {
                        Label("从模板开始", systemImage: "gift")
                    }
                }

                if !inProgress.isEmpty {
                    Section("拼制中") {
                        ForEach(inProgress) { p in
                            NavigationLink { WorkDetailView(pattern: p) } label: {
                                PatternRow(pattern: p)
                            }
                        }
                    }
                }

                Section("统计") {
                    HStack(spacing: 20) {
                        stat("图纸", "\(patterns.count)")
                        stat("拼制中", "\(inProgress.count)")
                        stat("已完成", "\(done.count)")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("豆拼")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                        Image(systemName: board.isConnected ? "lightbulb.fill" : "lightbulb")
                            .foregroundStyle(board.isConnected ? .yellow : .gray)
                    }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title2.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PatternRow: View {
    let pattern: Pattern

    var body: some View {
        HStack(spacing: 12) {
            Image(uiImage: pattern.thumbnailImage)
                .interpolation(.none)
                .resizable()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.3)))
            VStack(alignment: .leading, spacing: 3) {
                Text(pattern.name).font(.headline)
                HStack {
                    Text("\(pattern.width)×\(pattern.height)")
                    Text(pattern.status.label)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(pattern.status.color.opacity(0.15))
                        .foregroundStyle(pattern.status.color)
                        .clipShape(Capsule())
                    if pattern.status == .inProgress {
                        Text("\(Int(pattern.progressPercent * 100))%")
                            .foregroundStyle(.blue)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
