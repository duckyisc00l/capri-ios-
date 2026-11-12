import SwiftUI
import UIKit

struct ChatView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var s: Settings
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var engine: ChatEngine
    @EnvironmentObject var voice: Voice
    @StateObject private var anim = CapriAnimator()

    @State private var input = ""
    @State private var showChats = false
    @State private var showSettings = false
    @State private var openModels = false
    @State private var toast: String?
    @State private var bubble: String?
    @State private var bursts: [Burst] = []
    @FocusState private var focused: Bool

    private var chat: Chat? { store.current }
    private var empty: Bool { chat?.messages.isEmpty ?? true }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if empty {
                    Spacer(minLength: 0)
                    character(height: 300 * s.size, bubble: bubble ?? engine.status ?? Texts.shared.greeting(s.lang))
                    Text(s.s("empty")).font(Theme.font(13)).foregroundColor(Theme.dim).padding(.top, 10)
                    Spacer(minLength: 0)
                } else {
                    HStack(alignment: .top) {
                        character(height: 130 * s.size, bubble: bubble ?? engine.status)
                        Spacer()
                    }
                    .padding(.leading, 18)
                    .frame(height: 130 * s.size)
                    messages
                }
                if !engine.ready { setupBanner }
                inputBar
            }
            ForEach(bursts) { b in ClickBurst(point: b.point) }
            if let toast {
                VStack {
                    Spacer()
                    Text(toast).font(Theme.font(13)).foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Capsule().fill(Theme.panel))
                        .overlay(Capsule().stroke(Theme.pink.opacity(0.6)))
                        .padding(.bottom, 90)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "root")
        .sheet(isPresented: $showChats) { ChatsSheet().environmentObject(store).environmentObject(s) }
        .sheet(isPresented: $showSettings) {
            SettingsView(openModels: openModels)
                .environmentObject(s).environmentObject(models).environmentObject(engine)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            if empty { anim.lying = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            anim.lying = false
        }
        .onChange(of: voice.speaking) { _ in updateTalking() }
        .onChange(of: engine.busy) { _ in updateTalking() }
        .onChange(of: store.currentID) { _ in if !empty { anim.lying = false } }
    }

    private func updateTalking() {
        anim.talking = voice.speaking || (engine.busy && engine.thinkingSince == nil && engine.status == nil)
    }

    private func character(height: CGFloat, bubble: String?) -> some View {
        GeometryReader { g in
            CharacterView(anim: anim, height: height, hue: s.hue, bubble: bubble) {
                anim.poke()
                let f = g.frame(in: .named("root"))
                let id = UUID()
                bursts.append(Burst(id: id, point: CGPoint(x: f.midX, y: f.midY)))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { bursts.removeAll { $0.id == id } }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation { self.bubble = Texts.shared.liveLines.randomElement() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { self.bubble = nil } }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .frame(height: height)
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button { showChats = true } label: { Image(systemName: "line.3.horizontal") }
            Spacer()
            Text(chat?.title.isEmpty == false ? chat!.title : "Capri")
                .font(Theme.font(15)).foregroundColor(.white).lineLimit(1)
            Spacer()
            Button { engine.stop(); store.newChat() } label: { Image(systemName: "square.and.pencil") }
            Button { openModels = false; showSettings = true } label: { Image(systemName: "gearshape") }
        }
        .font(.system(size: 19, weight: .medium))
        .foregroundColor(.white.opacity(0.85))
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(chat?.messages ?? []) { m in
                        MessageView(msg: m,
                                    streaming: engine.streamingID == m.id,
                                    thinkingLive: engine.streamingID == m.id && engine.thinkingSince != nil,
                                    s: s,
                                    onRetry: retry(for: m))
                            .id(m.id)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat?.messages.last?.text) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chat?.messages.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func retry(for m: Msg) -> (() -> Void)? {
        guard m.role == "assistant", m.id == chat?.messages.last?.id, !engine.busy else { return nil }
        let e = engine
        return { e.regenerate() }
    }

    private var setupBanner: some View {
        Button {
            if s.brain == "local", models.installed.isEmpty, models.progress[models.defaultModel.file] == nil {
                if let e = models.download(models.defaultModel) { show(s.ui(e)) }
            }
            openModels = true
            showSettings = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: s.brain == "cloud" ? "key.fill" : "cpu").foregroundColor(Theme.green)
                VStack(alignment: .leading, spacing: 3) {
                    if s.brain == "cloud" {
                        Text("Cloud: add your API key and model").font(Theme.font(13))
                    } else if let p = models.progress[models.defaultModel.file] {
                        Text("\(models.defaultModel.name) · \(Int(p * 100))%").font(Theme.font(13))
                        ProgressView(value: p).tint(Theme.pink)
                    } else {
                        Text("\(s.ui("install")) \(models.defaultModel.name) · \(models.defaultModel.sizeText)").font(Theme.font(13))
                    }
                }
                .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(Theme.dim)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(s.s("placeholder"), text: voice.listening ? .constant(voice.partial) : $input, axis: .vertical)
                .font(Theme.font(15))
                .foregroundColor(.white)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 22).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(voice.listening ? Theme.green : Color.white.opacity(0.08), lineWidth: 1))

            Group {
                if engine.busy {
                    roundButton("stop.fill", Theme.pink) { engine.stop() }
                } else if voice.listening {
                    roundButton("waveform", Theme.green) { voice.stopListening() }
                        .scaleEffect(1 + CGFloat(min(voice.level * 8, 0.25)))
                } else if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    roundButton("mic.fill", Theme.purple) { startListening() }
                } else {
                    roundButton("arrow.up", Theme.pink) { sendInput() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func roundButton(_ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(color))
        }
    }

    private func sendInput() {
        guard engine.ready else {
            openModels = true; showSettings = true; return
        }
        let t = input
        input = ""
        anim.lying = false
        engine.send(t)
    }

    private func startListening() {
        focused = false
        voice.listen(locale: s.language.locale) { text, err in
            if let text {
                if engine.ready { engine.send(text) } else { input = text }
            } else if let err {
                show(s.ui(err))
            }
        }
    }

    private func show(_ msg: String) {
        withAnimation { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { withAnimation { toast = nil } }
    }
}

struct Burst: Identifiable {
    let id: UUID
    let point: CGPoint
}

struct ChatsSheet: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var s: Settings
    @Environment(\.dismiss) var dismiss
    @State private var pendingDelete: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if store.chats.filter({ !$0.messages.isEmpty }).isEmpty {
                    Text(s.s("no_chats")).font(Theme.font(14)).foregroundColor(Theme.dim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.chats.filter { !$0.messages.isEmpty }) { c in
                            Button {
                                store.currentID = c.id
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(c.title.isEmpty ? s.s("new_chat") : c.title)
                                        .font(Theme.font(15)).foregroundColor(c.id == store.currentID ? Theme.pink : .white)
                                        .lineLimit(1)
                                    Text(c.updated, style: .relative).font(Theme.font(11)).foregroundColor(Theme.dim)
                                }
                            }
                            .listRowBackground(Theme.panel)
                            .swipeActions {
                                Button(role: .destructive) { pendingDelete = c.id } label: { Label(s.s("delete"), systemImage: "trash") }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(s.s("chats"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { store.newChat(); dismiss() } label: { Label(s.s("new_chat"), systemImage: "square.and.pencil") }
                }
            }
            .alert(s.s("delete_title"), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button(s.s("cancel"), role: .cancel) { pendingDelete = nil }
                Button(s.s("delete"), role: .destructive) {
                    if let id = pendingDelete { store.delete(id) }
                    pendingDelete = nil
                }
            } message: {
                Text(s.s("delete_body"))
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.pink)
    }
}
