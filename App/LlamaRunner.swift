import Foundation
import llama

enum BrainError: LocalizedError {
    case noModel, loadFailed, decodeFailed, http(Int, String), noKey
    var errorDescription: String? {
        switch self {
        case .noModel: return "No model installed"
        case .loadFailed: return "Couldn't load the model"
        case .decodeFailed: return "The model stopped unexpectedly"
        case .http(let c, let m): return "Error \(c): \(m)"
        case .noKey: return "Add your API key in Settings"
        }
    }
}

struct ChatTurn {
    var role: String
    var content: String
}

/// Runs a GGUF model on the phone with llama.cpp (Metal GPU).
final class LlamaRunner: @unchecked Sendable {
    static let shared = LlamaRunner()

    private let queue = DispatchQueue(label: "capri.llama", qos: .userInitiated)
    private let lock = NSLock()
    private var _cancel = false
    private var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancel }
        set { lock.lock(); _cancel = newValue; lock.unlock() }
    }

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var loadedPath: String?
    private var cached: [llama_token] = []
    private let nCtx: Int32 = 4096
    private let nBatch: Int32 = 512

    private init() {
        llama_backend_init()
    }

    func cancel() { cancelled = true }

    func unload() {
        queue.async { self.freeAll() }
    }

    private func freeAll() {
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
        ctx = nil; model = nil; vocab = nil; loadedPath = nil; cached = []
    }

    private func load(_ path: String) throws {
        if loadedPath == path, ctx != nil { return }
        freeAll()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 99
        guard let m = llama_model_load_from_file(path, mp) else { throw BrainError.loadFailed }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(nCtx)
        cp.n_batch = UInt32(nBatch)
        let threads = Int32(max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw BrainError.loadFailed
        }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        loadedPath = path
        cached = []
    }

    /// Streams the reply token by token.
    func generate(path: String, turns: [ChatTurn], maxTokens: Int = 1500) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            cancelled = false
            queue.async {
                do {
                    try self.load(path)
                    try self.run(turns: turns, maxTokens: maxTokens) { cont.yield($0) }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { [weak self] _ in self?.cancel() }
        }
    }

    // MARK: - prompt

    private func render(_ turns: [ChatTurn]) -> String {
        guard let model else { return "" }
        let tmpl = llama_model_chat_template(model, nil)
        var roles: [UnsafeMutablePointer<CChar>?] = []
        var contents: [UnsafeMutablePointer<CChar>?] = []
        defer { roles.forEach { free($0) }; contents.forEach { free($0) } }
        var msgs: [llama_chat_message] = []
        for t in turns {
            let r = strdup(t.role), c = strdup(t.content)
            roles.append(r); contents.append(c)
            msgs.append(llama_chat_message(role: UnsafePointer(r), content: UnsafePointer(c)))
        }
        let total = turns.reduce(0) { $0 + $1.content.utf8.count } * 2 + 4096
        var buf = [CChar](repeating: 0, count: total)
        var n = llama_chat_apply_template(tmpl, &msgs, msgs.count, true, &buf, Int32(buf.count))
        if n > Int32(buf.count) {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(tmpl, &msgs, msgs.count, true, &buf, Int32(buf.count))
        }
        if n > 0 {
            let bytes = buf[0..<Int(n)].map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        // Unknown template: fall back to ChatML.
        var s = ""
        for t in turns { s += "<|im_start|>\(t.role)\n\(t.content)<|im_end|>\n" }
        return s + "<|im_start|>assistant\n"
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let len = Int32(text.utf8.count)
        var toks = [llama_token](repeating: 0, count: Int(len) + 16)
        var n = llama_tokenize(vocab, text, len, &toks, Int32(toks.count), true, true)
        if n < 0 {
            toks = [llama_token](repeating: 0, count: Int(-n) + 16)
            n = llama_tokenize(vocab, text, len, &toks, Int32(toks.count), true, true)
        }
        return Array(toks.prefix(Int(max(0, n))))
    }

    private func piece(_ tok: llama_token) -> [UInt8] {
        var b = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, tok, &b, Int32(b.count), 0, false)
        if n < 0 {
            b = [CChar](repeating: 0, count: Int(-n) + 8)
            n = llama_token_to_piece(vocab, tok, &b, Int32(b.count), 0, false)
        }
        return b.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
    }

    private func decode(_ toks: [llama_token], from start: Int) throws {
        guard let ctx else { throw BrainError.loadFailed }
        var toks = toks
        var i = start
        while i < toks.count {
            if cancelled { return }
            let n = min(Int(nBatch), toks.count - i)
            let rc = toks.withUnsafeMutableBufferPointer { p -> Int32 in
                llama_decode(ctx, llama_batch_get_one(p.baseAddress! + i, Int32(n)))
            }
            if rc != 0 { throw BrainError.decodeFailed }
            i += n
        }
    }

    // MARK: - generation

    private func run(turns: [ChatTurn], maxTokens: Int, emit: (String) -> Void) throws {
        guard let ctx, let vocab else { throw BrainError.loadFailed }

        var prompt = tokenize(render(turns))
        let room = Int(nCtx) - 600
        if prompt.count > room { prompt = Array(prompt.suffix(room)) }

        // Reuse what's already in memory from the previous turn.
        let mem = llama_get_memory(ctx)
        var common = 0
        while common < min(cached.count, prompt.count) - 1, cached[common] == prompt[common] { common += 1 }
        if common == 0 || !llama_memory_seq_rm(mem, 0, Int32(common), -1) {
            llama_memory_clear(mem, true)
            common = 0
        }
        cached = Array(prompt.prefix(common))
        try decode(prompt, from: common)
        cached = prompt
        if cancelled { return }

        let sparams = llama_sampler_chain_default_params()
        guard let smpl = llama_sampler_chain_init(sparams) else { throw BrainError.loadFailed }
        defer { llama_sampler_free(smpl) }
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(smpl, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.8))
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))

        var pending: [UInt8] = []
        var produced = 0
        while produced < maxTokens, !cancelled, cached.count < Int(nCtx) - 4 {
            let tok = llama_sampler_sample(smpl, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            pending += piece(tok)
            if let s = String(bytes: pending, encoding: .utf8) {
                emit(s); pending = []
            } else if pending.count > 12 {
                emit(String(decoding: pending, as: UTF8.self)); pending = []
            }
            var t = tok
            let rc = withUnsafeMutablePointer(to: &t) { llama_decode(ctx, llama_batch_get_one($0, 1)) }
            if rc != 0 { break }
            cached.append(tok)
            produced += 1
        }
        if !pending.isEmpty { emit(String(decoding: pending, as: UTF8.self)) }
    }
}
