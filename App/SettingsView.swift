import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var s: Settings
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var engine: ChatEngine
    @Environment(\.dismiss) var dismiss
    var openModels: Bool
    @State private var path: [String] = []
    @State private var cloudModels: [String] = []
    @State private var loadingModels = false

    private let hues: [Double] = [0, 50, 100, 150, 200, 260, 310]

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    Picker(s.s("language"), selection: $s.lang) {
                        ForEach(Texts.shared.languages) { l in Text(l.native).tag(l.code) }
                    }
                    Toggle(s.s("voice"), isOn: $s.voice)
                    Toggle(s.web("search"), isOn: $s.webSearch)
                }

                Section(s.ui("models")) {
                    Picker("Brain", selection: $s.brain) {
                        Text("On this phone").tag("local")
                        Text("Cloud (your API key)").tag("cloud")
                    }
                    .pickerStyle(.segmented)

                    if s.brain == "local" {
                        NavigationLink(value: "models") {
                            HStack {
                                Text(s.ui("models"))
                                Spacer()
                                Text(engine.localModel?.name ?? "—").foregroundColor(Theme.dim).lineLimit(1)
                            }
                        }
                    } else {
                        Picker("Provider", selection: $s.provider) {
                            ForEach(Provider.all) { p in Text(p.name).tag(p.id) }
                        }
                        SecureField("API key", text: Binding(get: { s.apiKey }, set: { s.apiKey = $0 }))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        HStack {
                            TextField("Model", text: $s.cloudModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if loadingModels {
                                ProgressView()
                            } else {
                                Menu {
                                    ForEach(cloudModels, id: \.self) { m in Button(m) { s.cloudModel = m } }
                                } label: { Image(systemName: "list.bullet") }
                                .disabled(cloudModels.isEmpty)
                            }
                        }
                        Text("Messages go to the provider you pick. On-device chats stay on your phone.")
                            .font(.footnote).foregroundColor(Theme.dim)
                    }
                }

                Section(Texts.shared.look(0, s.lang)) {
                    VStack(alignment: .leading) {
                        Text(Texts.shared.look(1, s.lang))
                        Slider(value: $s.size, in: 0.7...1.3)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Texts.shared.look(2, s.lang))
                        HStack(spacing: 12) {
                            ForEach(hues, id: \.self) { h in
                                Circle()
                                    .fill(Theme.pink)
                                    .hueRotation(.degrees(h))
                                    .frame(width: 28, height: 28)
                                    .overlay(Circle().stroke(Color.white, lineWidth: s.hue == h ? 2 : 0))
                                    .onTapGesture { s.hue = h }
                            }
                        }
                    }
                }

                Section {
                    NavigationLink(value: "log") {
                        Label("Crash log", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section {
                    Text("Capri for iPhone. Things Android allowed that iPhone doesn't: floating over other apps, the \"Hey Capri\" wake word in the background, controlling other apps, starting with the phone, and the Quick Settings tile.")
                        .font(.footnote).foregroundColor(Theme.dim)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(s.s("settings"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { v in
                if v == "models" { ModelsView() } else if v == "log" { LogView() } else { AddModelView() }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .onAppear { if openModels && s.brain == "local" { path = ["models"] } }
            .task(id: "\(s.provider)|\(s.apiKey)|\(s.brain)") { await loadCloudModels() }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.pink)
        .font(Theme.font(15))
    }

    private func loadCloudModels() async {
        guard s.brain == "cloud", !s.apiKey.isEmpty else { cloudModels = []; return }
        loadingModels = true
        cloudModels = await CloudBrain.models(base: Provider.byID(s.provider).base, key: s.apiKey)
        loadingModels = false
    }
}

struct ModelsView: View {
    @EnvironmentObject var s: Settings
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var engine: ChatEngine
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(models.installed) { m in
                    Button {
                        s.activeModel = m.file
                    } label: {
                        HStack {
                            Image(systemName: engine.localModel?.file == m.file ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(Theme.pink)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name).foregroundColor(.white)
                                Text("\(m.repo) · \(m.sizeText)").font(Theme.font(11)).foregroundColor(Theme.dim).lineLimit(1)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { models.delete(m) } label: { Label(s.ui("delete"), systemImage: "trash") }
                    }
                }
                if !models.isInstalled(models.defaultModel) {
                    DownloadRow(model: models.defaultModel, error: $error)
                }
                ForEach(Array(models.progress.keys.sorted()), id: \.self) { f in
                    if f != models.defaultModel.file, let p = models.progress[f] {
                        VStack(alignment: .leading) {
                            Text(f).font(Theme.font(12)).lineLimit(1)
                            ProgressView(value: p).tint(Theme.pink)
                        }
                    }
                }
            } footer: {
                if let error { Text(error).foregroundColor(Theme.pink) }
            }

            Section {
                NavigationLink(value: "add") {
                    Label(s.ui("add_model"), systemImage: "plus")
                }
            } footer: {
                Text("Models come from Hugging Face and run fully on your phone. Phones with 6 GB of memory or more work best with the default model; on older phones pick a smaller \"Light\" one.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(s.ui("models"))
    }
}

struct DownloadRow: View {
    @EnvironmentObject var s: Settings
    @EnvironmentObject var models: ModelManager
    let model: LocalModel
    @Binding var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                    Text(model.sizeText).font(Theme.font(11)).foregroundColor(Theme.dim)
                }
                Spacer()
                if models.progress[model.file] != nil {
                    Button { models.cancel(model) } label: { Image(systemName: "xmark.circle") }
                } else if models.isInstalled(model) {
                    Image(systemName: "checkmark").foregroundColor(Theme.green)
                } else {
                    Button(s.ui("install")) {
                        if let e = models.download(model) {
                            error = e == "limit" ? String(format: s.ui("limit"), ModelManager.maxModels) : s.ui(e)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if let p = models.progress[model.file] {
                ProgressView(value: p).tint(Theme.pink)
                Text("\(Int(p * 100))%").font(Theme.font(11)).foregroundColor(Theme.dim)
            }
            if let e = models.errors[model.file] {
                Text(s.ui(e)).font(Theme.font(11)).foregroundColor(Theme.pink)
            }
        }
    }
}

struct AddModelView: View {
    @EnvironmentObject var s: Settings
    @EnvironmentObject var models: ModelManager
    @State private var query = ""
    @State private var repos: [HubRepo] = []
    @State private var state: String?
    @State private var loading = false

    var body: some View {
        List {
            if let state {
                Text(state).foregroundColor(Theme.dim)
            }
            ForEach(repos) { r in
                NavigationLink {
                    RepoFilesView(repo: r)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.id.split(separator: "/").last.map(String.init) ?? r.id).lineLimit(1)
                        HStack(spacing: 10) {
                            Text(r.id.split(separator: "/").first.map(String.init) ?? "")
                            Label("\(r.downloads)", systemImage: "arrow.down.circle")
                            Label("\(r.likes)", systemImage: "heart")
                            if r.gated { Image(systemName: "lock.fill") }
                        }
                        .font(Theme.font(11)).foregroundColor(Theme.dim)
                    }
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(s.ui("add_model"))
        .searchable(text: $query, prompt: s.ui("search"))
        .onSubmit(of: .search) { Task { await run() } }
        .task { if repos.isEmpty { await run() } }
    }

    private func run() async {
        loading = true
        state = nil
        do {
            repos = try await models.search(query)
            if repos.isEmpty { state = s.ui("nothing") }
        } catch {
            state = s.ui("offline")
        }
        loading = false
    }
}

struct RepoFilesView: View {
    @EnvironmentObject var s: Settings
    @EnvironmentObject var models: ModelManager
    let repo: HubRepo
    @State private var files: [HubFile] = []
    @State private var state: String?
    @State private var error: String?

    var body: some View {
        List {
            if repo.gated { Text(s.ui("gated")).foregroundColor(Theme.pink) }
            if let state { Text(state).foregroundColor(Theme.dim) }
            ForEach(files) { f in
                let m = LocalModel(name: Self.prettyName(repo.id, f.path), repo: repo.id, file: f.path, size: f.size)
                VStack(alignment: .leading, spacing: 2) {
                    if !f.tier.isEmpty { Text(f.tier).font(Theme.font(11)).foregroundColor(Theme.green) }
                    DownloadRow(model: m, error: $error)
                    if !ModelManager.fits(f.size) {
                        Text(s.ui("too_big")).font(Theme.font(11)).foregroundColor(Theme.dim)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(repo.id.split(separator: "/").last.map(String.init) ?? repo.id)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                files = try await models.files(repo.id)
                if files.isEmpty { state = s.ui("nothing") }
            } catch { state = s.ui("offline") }
        }
        .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        }
    }

    static func prettyName(_ repo: String, _ file: String) -> String {
        var n = (file as NSString).lastPathComponent
        n = n.replacingOccurrences(of: ".gguf", with: "", options: .caseInsensitive)
        return n.replacingOccurrences(of: "[-_.]", with: " ", options: .regularExpression)
    }
}

struct LogView: View {
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Color.clear.frame(height: 1).id("end")
            }
            .onAppear {
                text = Log.device() + "\n\n" + Log.read()
                DispatchQueue.main.async { proxy.scrollTo("end") }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Crash log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy") { UIPasteboard.general.string = text; copied = true }
                ShareLink(item: Log.file) { Image(systemName: "square.and.arrow.up") }
                Button(role: .destructive) { Log.clear(); text = "(empty)" } label: { Image(systemName: "trash") }
            }
        }
    }
}
