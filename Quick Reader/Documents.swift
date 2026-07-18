import Foundation
import SwiftUI
import Combine

struct Document: Codable, Identifiable {
    var id = UUID()
    var title: String
    var content: String
    var sentenceIndex: Int = 0
    var bookmark: Int? = nil
}

class DocumentStore: ObservableObject {
    @Published var documents: [Document] = []
    @Published var activeID: UUID?

    private let docsKey  = "v1_documents"
    private let activeKey = "v1_activeID"

    init() {
        load()
        if documents.isEmpty {
            // Migrate single-document AppStorage if present
            let legacy      = UserDefaults.standard.string(forKey: "savedText") ?? "Welcome to Quick Reader!\n\nImport a .txt or .md file using the button at the top left, or tap the pencil to type or paste text. Choose your reading voice with the voice button at the bottom.\n\nTap Play to start listening."
            let legacyIndex = UserDefaults.standard.integer(forKey: "currentSentenceIndex")
            let first = Document(title: derivedTitle(legacy), content: legacy, sentenceIndex: legacyIndex)
            documents = [first]
            activeID  = first.id
            save()
        }
    }

    var activeDocument: Document? {
        get { documents.first(where: { $0.id == activeID }) }
        set {
            guard let new = newValue,
                  let i = documents.firstIndex(where: { $0.id == new.id }) else { return }
            documents[i] = new
            save()
        }
    }

    func addDocument(title: String = "New Document", content: String = "") {
        let doc = Document(title: title, content: content)
        documents.append(doc)
        activeID = doc.id
        save()
    }

    func activate(_ id: UUID) {
        activeID = id
        save()
    }

    func delete(at offsets: IndexSet) {
        documents.remove(atOffsets: offsets)
        if documents.isEmpty {
            let doc = Document(title: "New Document", content: "")
            documents = [doc]
            activeID = doc.id
        } else if !documents.contains(where: { $0.id == activeID }) {
            activeID = documents.first?.id
        }
        save()
    }

    func save() {
        if let data = try? JSONEncoder().encode(documents) {
            UserDefaults.standard.set(data, forKey: docsKey)
        }
        if let id = activeID, let data = try? JSONEncoder().encode(id) {
            UserDefaults.standard.set(data, forKey: activeKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: docsKey),
           let docs = try? JSONDecoder().decode([Document].self, from: data) {
            documents = docs
        }
        if let data = UserDefaults.standard.data(forKey: activeKey),
           let id = try? JSONDecoder().decode(UUID.self, from: data) {
            activeID = id
        }
        if !documents.contains(where: { $0.id == activeID }) {
            activeID = documents.first?.id
        }
    }
}

extension ToolbarItemPlacement {
    /// Leading edge on iOS/iPadOS; default (right-grouped) placement on macOS,
    /// which has no navigation-bar leading region.
    static var leadingCompat: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .automatic
        #endif
    }
}

private func derivedTitle(_ content: String) -> String {
    let first = content.components(separatedBy: "\n")
        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Untitled"
    return String(first.trimmingCharacters(in: CharacterSet(charactersIn: "#* \t")).prefix(40))
}

// Sidebar version for iPad NavigationSplitView — no dismiss binding needed
struct DocumentSidebarView: View {
    @ObservedObject var store: DocumentStore
    var onImport: () -> Void

    @State private var renameTarget: Document?
    @State private var renameText = ""
    @State private var showRenameAlert = false

    var body: some View {
        List {
            ForEach(store.documents) { doc in
                Button {
                    store.activate(doc.id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(doc.title)
                                .fontWeight(doc.id == store.activeID ? .semibold : .regular)
                                .foregroundColor(.primary)
                            if doc.bookmark != nil {
                                Image(systemName: "bookmark.fill")
                                    .font(.caption2)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        Text(doc.content.prefix(60))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        if let i = store.documents.firstIndex(where: { $0.id == doc.id }) {
                            store.delete(at: IndexSet([i]))
                        }
                    } label: { Label("Delete", systemImage: "trash") }
                    Button {
                        renameTarget = doc
                        renameText = doc.title
                        showRenameAlert = true
                    } label: { Label("Rename", systemImage: "pencil") }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle("Documents")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.addDocument() } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .leadingCompat) {
                Button { onImport() } label: { Image(systemName: "doc.badge.plus") }
            }
        }
        .alert("Rename", isPresented: $showRenameAlert) {
            TextField("Title", text: $renameText)
            Button("Save") {
                guard let target = renameTarget,
                      let i = store.documents.firstIndex(where: { $0.id == target.id })
                else { return }
                store.documents[i].title = renameText
                store.save()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct DocumentListView: View {
    @ObservedObject var store: DocumentStore
    @Binding var isPresented: Bool

    @State private var renameTarget: Document?
    @State private var renameText = ""
    @State private var showRenameAlert = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.documents) { doc in
                    Button {
                        store.activate(doc.id)
                        isPresented = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title)
                                .fontWeight(doc.id == store.activeID ? .semibold : .regular)
                                .foregroundColor(.primary)
                            Text(doc.content.prefix(80))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            if let i = store.documents.firstIndex(where: { $0.id == doc.id }) {
                                store.delete(at: IndexSet([i]))
                            }
                        } label: { Label("Delete", systemImage: "trash") }
                        Button {
                            renameTarget = doc
                            renameText = doc.title
                            showRenameAlert = true
                        } label: { Label("Rename", systemImage: "pencil") }
                        .tint(.blue)
                    }
                }
            }
            .navigationTitle("Documents")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.addDocument()
                        isPresented = false
                    } label: { Image(systemName: "plus") }
                }
            }
            .alert("Rename", isPresented: $showRenameAlert) {
                TextField("Title", text: $renameText)
                Button("Save") {
                    guard let target = renameTarget,
                          let i = store.documents.firstIndex(where: { $0.id == target.id })
                    else { return }
                    store.documents[i].title = renameText
                    store.save()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
