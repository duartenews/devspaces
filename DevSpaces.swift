// DevSpaces.swift — sidebar nativa de workspaces DevSync para o Ghostty.
// App macOS SwiftUI single-file, sem dependências externas.
// Compilar: swiftc -O DevSpaces.swift -o DevSpaces   (macOS 14+)
//
// Contratos consumidos (implementados em /Users/Raphael/bin/devworkspace):
//   devworkspace ws <nome>    → abre/foca o workspace no Ghostty
//   devworkspace states       → linhas `nome|ready/not-local|aberto/fundo/fechado`
//   devworkspace usage        → linhas plain `claude   5h 24%   7d 5%` / `(sem dados)`
//   devworkspace generate     → regenera o zsh a partir do JSON (exit != 0 → stderr)
//   devworkspace models <p>   → linhas `id|nome_exibicao|effort1,effort2,...`
//                               p = claude|codex|codex2; cache de 24h no CLI
// Fonte da verdade: ~/.config/dev-workspaces/workspaces.json
// Projetos DevSync: ~/.devsync/projects (formato `nome|path`, `#` comenta)

import SwiftUI
import AppKit
import Foundation
import ApplicationServices   // AX (Acessibilidade) para posicionar a janela do Ghostty

// MARK: - Constantes

private enum Paths {
    static let devworkspace = "/Users/Raphael/bin/devworkspace"
    static let open = "/usr/bin/open"
    static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/dev-workspaces/workspaces.json")
    }
    static var projectsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".devsync/projects")
    }
}

private let kDefaultColorHex = "#6c7086"
private let kKnownCommands = ["shell", "claude", "codex", "codex2"]
private let kCustomTag = "__custom__"

// MARK: - Modelos

struct PaneConfig: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var command: String
    var model: String
    var effort: String   // "" = default (sem flag de effort)

    init(name: String = "", command: String, model: String = "", effort: String = "") {
        self.name = name
        self.command = command
        self.model = model
        self.effort = effort
    }

    var isAgent: Bool { command == "claude" || command == "codex" || command == "codex2" }

    /// Nome base derivado de programa+modelo (ex.: "claude-opus", "codex", "shell").
    /// Efforts NÃO entram no nome. Sempre válido: sem ':', ',', espaço ou newline.
    var derivedBaseName: String {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        let mdl = model.trimmingCharacters(in: .whitespaces)
        if isAgent && !mdl.isEmpty {
            // evita duplicar prefixo: id "claude-fable-5" → "claude-fable-5",
            // não "claude-claude-fable-5"
            if mdl == cmd || mdl.hasPrefix(cmd + "-") {
                return sanitizePaneName(mdl)
            }
            return sanitizePaneName(cmd + "-" + mdl)
        }
        return sanitizePaneName(cmd)
    }

    func jsonDict() -> [String: Any] {
        // direction/parent ficam vazios — a posição agora é dada pela ordem
        [
            "name": name,
            "command": command,
            "model": model,
            "effort": effort,
            "direction": "",
            "parent": "",
        ]
    }
}

/// Troca caracteres inválidos para nome de sessão tmux (':', ',', espaços, newlines).
func sanitizePaneName(_ raw: String) -> String {
    var out = ""
    for ch in raw.lowercased() {
        if ch == ":" || ch == "," || ch.isWhitespace || ch.isNewline {
            out.append("-")
        } else {
            out.append(ch)
        }
    }
    while out.contains("--") {
        out = out.replacingOccurrences(of: "--", with: "-")
    }
    out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return out.isEmpty ? "split" : out
}

/// Nomes finais dos splits na ordem, com sufixo -2, -3… para duplicatas.
func derivedPaneNames(_ panes: [PaneConfig]) -> [String] {
    var produced = Set<String>()
    var result: [String] = []
    for pane in panes {
        let base = pane.derivedBaseName
        var candidate = base
        var n = 1
        while produced.contains(candidate) {
            n += 1
            candidate = "\(base)-\(n)"
        }
        produced.insert(candidate)
        result.append(candidate)
    }
    return result
}

struct WorkspaceConfig: Identifiable, Equatable {
    var name: String
    var color: String
    var panes: [PaneConfig]
    /// true quando o workspace veio só de ~/.devsync/projects (template default)
    var fromTemplate: Bool = false
    /// oculto na lista (olhinho); persistido no JSON como "hidden"
    var hidden: Bool = false

    var id: String { name }

    var summary: String {
        let count = panes.count
        let head = count == 1 ? "1 split" : "\(count) splits"
        let labels = derivedPaneNames(panes)
        return labels.isEmpty ? head : head + " · " + labels.joined(separator: " · ")
    }

    /// Regrava os nomes de todos os splits a partir de programa+modelo.
    mutating func regeneratePaneNames() {
        let names = derivedPaneNames(panes)
        for i in panes.indices {
            panes[i].name = names[i]
        }
    }

    static func defaultTemplate(name: String) -> WorkspaceConfig {
        var ws = WorkspaceConfig(
            name: name,
            color: kDefaultColorHex,
            panes: [
                PaneConfig(command: "shell"),
                PaneConfig(command: "codex"),
                PaneConfig(command: "claude", model: "opus"),
                PaneConfig(command: "claude", model: "sonnet"),
            ],
            fromTemplate: true
        )
        ws.regeneratePaneNames()
        return ws
    }

    func jsonDict() -> [String: Any] {
        [
            "name": name,
            "color": color,
            "hidden": hidden,
            "panes": panes.map { $0.jsonDict() },
        ]
    }
}

enum WSState: Equatable {
    case open        // aba Ghostty aberta
    case background  // sessão tmux viva em segundo plano
    case closed
    case notLocal    // projeto não está neste Mac
    case unknown     // ainda sem resposta do poll

    var label: String {
        switch self {
        case .open: return "aberto"
        case .background: return "fundo"
        case .closed: return "fechado"
        case .notLocal: return "não está neste Mac"
        case .unknown: return "…"
        }
    }

    var color: Color {
        switch self {
        case .open: return .green
        case .background: return .yellow
        case .closed, .notLocal, .unknown: return Color.secondary.opacity(0.6)
        }
    }
}

struct UsageWindow: Identifiable {
    let id = UUID()
    let label: String   // ex.: "5h", "7d"
    let percent: Int    // 0–100 (clampado)
}

struct UsageEntry: Identifiable {
    let id = UUID()
    let agent: String
    let windows: [UsageWindow]
    let noData: Bool
}

/// Modelo disponível para um provider (via `devworkspace models <provider>`).
struct ModelInfo: Identifiable, Equatable, Sendable {
    let id: String            // ex.: "claude-fable-5" (gravado no JSON)
    let displayName: String   // ex.: "Claude Fable 5" (mostrado na UI)
    let efforts: [String]     // ex.: ["low","medium","high","xhigh","max"]; pode ser vazio
}

/// Estado da lista de modelos de um provider no Store.
enum ModelList {
    case loading
    case ready([ModelInfo])   // vazio = indisponível → UI cai no fallback de texto
}

// MARK: - Shell (nunca na main thread)

struct ShellResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum Shell {
    /// fila serial para `ws` (abrir/focar não pode concorrer consigo mesmo)
    private static let wsQueue = DispatchQueue(label: "com.raphael.devspaces.ws", qos: .userInitiated)
    private static let pollQueue = DispatchQueue(label: "com.raphael.devspaces.poll",
                                                 qos: .utility, attributes: .concurrent)

    static func run(_ path: String, _ args: [String], serialized: Bool = false) async -> ShellResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ShellResult, Never>) in
            let queue = serialized ? wsQueue : pollQueue
            queue.async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = args
                proc.standardInput = FileHandle.nullDevice
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                // higiene: fecha os FileHandles em TODOS os caminhos (inclusive
                // falha de spawn), senão cada erro vaza 4 FDs
                defer {
                    try? outPipe.fileHandleForReading.close()
                    try? errPipe.fileHandleForReading.close()
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                }
                do {
                    try proc.run()
                } catch {
                    cont.resume(returning: ShellResult(status: -1, stdout: "",
                                                       stderr: error.localizedDescription))
                    return
                }
                // stderr lido em paralelo para não travar se o buffer encher
                var errData = Data()
                let errSem = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    errSem.signal()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                errSem.wait()
                proc.waitUntilExit()   // reap do filho — nunca deixar zumbi
                cont.resume(returning: ShellResult(
                    status: proc.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""))
            }
        }
    }

    static func devworkspace(_ args: [String], serialized: Bool = false) async -> ShellResult {
        await run(Paths.devworkspace, args, serialized: serialized)
    }
}

// MARK: - Escrita atômica (temp + rename)

private func atomicWrite(_ data: Data, to url: URL) throws {
    let fm = FileManager.default
    let dir = url.deletingLastPathComponent()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
    try data.write(to: tmp)
    if fm.fileExists(atPath: url.path) {
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
    } else {
        try fm.moveItem(at: tmp, to: url)
    }
}

// MARK: - Cor hex

extension Color {
    init?(hexRGB: String) {
        var s = hexRGB.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255.0,
                  green: Double((v >> 8) & 0xFF) / 255.0,
                  blue: Double(v & 0xFF) / 255.0,
                  opacity: 1.0)
    }

    var hexRGBString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.gray
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var workspaces: [WorkspaceConfig] = []
    @Published var states: [String: WSState] = [:]
    @Published var usage: [UsageEntry] = []
    @Published var autostart: Bool = false
    @Published var opening: Set<String> = []
    @Published var globalError: String?
    /// listas de modelos por provider ("claude"/"codex"/"codex2");
    /// ausente = nunca pedido, .loading = em busca, .ready = resultado
    @Published var modelLists: [String: ModelList] = [:]

    /// Aviso discreto no rodapé quando falta permissão de Acessibilidade p/ o tile.
    @Published var accessibilityDenied = false

    /// Aviso quando o Split View ficou aguardando o clique do usuário no seletor.
    @Published var splitViewNotice: String?

    /// true enquanto um sheet (editor ou adicionar pasta) está aberto —
    /// o WindowConfigurator eleva a janela para .floating para o sheet
    /// (520 pt, mais largo que a janela) ficar inteiro por cima do Ghostty.
    @Published var sheetOpen = false

    /// raiz crua do JSON — preserva `default_model` e quaisquer chaves extras
    private var rawRoot: [String: Any] = [:]
    private var statesTimer: Timer?
    private var usageTimer: Timer?
    private var statesInFlight = false
    private var usageInFlight = false
    private var windowVisible = true
    private var observers: [NSObjectProtocol] = []

    init() {
        loadConfig()
        // refresh de launch (único; os periódicos só existem com o app ativo)
        Task { await self.pollStates() }
        Task { await self.pollUsage() }
        installObservers()
        if NSApp.isActive { startTimers() }
        // Split View no launch se o Ghostty já estiver rodando (janela nasce → adia)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.arrangeWithGhostty()
        }
    }

    // MARK: Ciclo de vida orientado a eventos (zero wakeups em background)
    //
    // Timers criados SOMENTE em startTimers() — chamado por:
    //   • NSApplication.didBecomeActiveNotification (app frontmost)
    //   • NSWindow.didBecomeKeyNotification da janela principal (reaberta)
    // Timers invalidados SOMENTE em stopTimers() — chamado por:
    //   • NSApplication.willResignActiveNotification (app deixa de ser frontmost)
    //   • NSWindow.willCloseNotification da janela principal
    // Refreshes por evento (sem timer): launch, didBecomeActive, launch/quit do
    // Ghostty, após abrir workspace, após salvar o sheet, botão manual.

    private func installObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.appDidBecomeActive() }
            })
        observers.append(nc.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.stopTimers() }
            })
        observers.append(nc.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: .main) { [weak self] note in
                guard (note.object as? NSWindow)?.frameAutosaveName == "DevSpacesMain" else { return }
                Task { @MainActor [weak self] in
                    self?.windowVisible = false
                    self?.stopTimers()
                }
            })
        observers.append(nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main) { [weak self] note in
                guard (note.object as? NSWindow)?.frameAutosaveName == "DevSpacesMain" else { return }
                Task { @MainActor [weak self] in
                    self?.windowVisible = true
                    self?.startTimers()
                }
            })

        // launch/quit do Ghostty (event-driven, sem polling)
        let wsnc = NSWorkspace.shared.notificationCenter
        observers.append(wsnc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard Self.isGhostty(note) else { return }
                Task { @MainActor [weak self] in
                    self?.arrangeWithGhostty()
                    await self?.pollStates()
                }
            })
        observers.append(wsnc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard Self.isGhostty(note) else { return }
                Task { @MainActor [weak self] in
                    // Ghostty saiu: se estamos em fullscreen (Split View),
                    // sai para não ficar preso numa Space vazia
                    self?.exitSplitViewIfNeeded()
                    await self?.pollStates()
                }
            })
    }

    nonisolated private static func isGhostty(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == kGhosttyBundleID
    }

    private func appDidBecomeActive() {
        // usuário voltou ao app: dados frescos + volta a existir alguma permissão?
        if accessibilityDenied && AXIsProcessTrusted() {
            accessibilityDenied = false
        }
        refreshAll()
        startTimers()
    }

    /// states 30 s / usage 120 s — só com app ativo E janela visível.
    private func startTimers() {
        guard NSApp.isActive, windowVisible else { return }
        guard statesTimer == nil else { return }
        statesTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.pollStates() }
        }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.pollUsage() }
        }
    }

    private func stopTimers() {
        statesTimer?.invalidate()
        statesTimer = nil
        usageTimer?.invalidate()
        usageTimer = nil
    }

    // MARK: Tiling (DevSpaces à esquerda, Ghostty no resto)

    /// Janela principal do app (a da sidebar).
    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.frameAutosaveName == "DevSpacesMain" }
            ?? NSApp.windows.first { $0.isVisible }
    }

    /// Chamado pela ContentView quando um sheet abre/fecha. Ao abrir: ativa o
    /// app e traz a janela pra frente; o level .floating temporário é aplicado
    /// pelo WindowConfigurator (via `sheetOpen`) e restaurado ao fechar.
    func setSheetOpen(_ open: Bool) {
        guard sheetOpen != open else { return }
        sheetOpen = open
        if open {
            NSApp.activate()
            if let win = mainWindow {
                win.makeKeyAndOrderFront(nil)
                win.orderFrontRegardless()
            }
        }
    }

    // MARK: Split View nativo

    private var splitViewInProgress = false

    /// Ação principal: entra no SPLIT VIEW NATIVO do macOS (Space própria em
    /// tela cheia — DevSpaces à esquerda ~300 pt, Ghostty no resto).
    /// Gatilhos (nunca em polling): launch do app com Ghostty rodando,
    /// launch do Ghostty, clique que abre workspace.
    /// Fallback (item de menu do sistema ausente): tiling AX lado a lado.
    func arrangeWithGhostty() {
        guard let win = mainWindow else { return }
        // já em fullscreen (Split View) → nunca re-disparar
        guard !win.styleMask.contains(.fullScreen) else { return }
        guard !splitViewInProgress else { return }   // reentrância
        guard NSRunningApplication
            .runningApplications(withBundleIdentifier: kGhosttyBundleID)
            .contains(where: { !$0.isTerminated }) else { return }

        splitViewNotice = nil
        // janela .floating não entra direito em fullscreen
        win.level = .normal
        NSApp.activate()
        win.makeKeyAndOrderFront(nil)

        // 1) dispara o item de menu do sistema "Full Screen Tile → Left of
        //    Screen" / "Tela Cheia em Mosaico → Lado Esquerdo da Tela"
        guard SplitViewDriver.triggerLeftFullScreenTile() else {
            tileNow()   // fallback: tiling AX lado a lado na mesa
            return
        }
        splitViewInProgress = true

        // 2) o macOS abre o seletor do lado direito (desenhado pelo Dock);
        //    clica a miniatura do Ghostty via AX — desiste em ~3 s
        Task { [weak self] in
            let clicked = await SplitViewDriver.clickGhosttyInSelector()
            guard let self else { return }
            self.splitViewInProgress = false
            self.splitViewNotice = clicked
                ? nil
                : "Clique na janela do Ghostty para completar o Split View."
        }
    }

    /// Sai do fullscreen quando o Ghostty encerra (senão sobra uma Space vazia).
    private func exitSplitViewIfNeeded() {
        splitViewNotice = nil
        if let win = mainWindow, win.styleMask.contains(.fullScreen) {
            win.toggleFullScreen(nil)
        }
    }

    /// FALLBACK: tiling AX lado a lado na mesa. Também usado se o sistema não
    /// injetar o item de menu de Split View.
    func tileNow(allowRetry: Bool = true) {
        let win = mainWindow
        switch WindowTiler.tile(appWindow: win) {
        case .done:
            accessibilityDenied = false
        case .noPermission:
            accessibilityDenied = true
        case .ghosttyNotRunning:
            break
        case .noGhosttyWindow:
            // Ghostty acabou de subir e ainda não criou a janela — 1 retry só
            if allowRetry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.tileNow(allowRetry: false)
                }
            }
        }
    }

    // MARK: Config (JSON + projetos DevSync)

    func loadConfig() {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: Paths.configURL),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = obj
        }
        rawRoot = root

        if let b = root["autostart_agents"] as? Bool {
            autostart = b
        } else if let n = root["autostart_agents"] as? NSNumber {
            autostart = n.boolValue
        } else {
            autostart = false
        }

        var list: [WorkspaceConfig] = []
        if let arr = root["workspaces"] as? [[String: Any]] {
            for wsDict in arr {
                guard let name = (wsDict["name"] as? String)?
                    .trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
                guard !list.contains(where: { $0.name == name }) else { continue }
                let color = (wsDict["color"] as? String).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? kDefaultColorHex
                var panes: [PaneConfig] = []
                if let paneArr = wsDict["panes"] as? [[String: Any]] {
                    for p in paneArr {
                        let pName = (p["name"] as? String) ?? ""
                        let pCmd = (p["command"] as? String) ?? ""
                        // direction/parent do JSON antigo são ignorados (posição = ordem)
                        guard !pName.isEmpty || !pCmd.isEmpty else { continue }
                        panes.append(PaneConfig(
                            name: pName,
                            command: pCmd.isEmpty ? "shell" : pCmd,
                            model: (p["model"] as? String) ?? "",
                            effort: (p["effort"] as? String) ?? ""))
                    }
                }
                if panes.isEmpty {
                    panes = WorkspaceConfig.defaultTemplate(name: name).panes
                }
                var hidden = false
                if let b = wsDict["hidden"] as? Bool {
                    hidden = b
                } else if let n = wsDict["hidden"] as? NSNumber {
                    hidden = n.boolValue
                }
                list.append(WorkspaceConfig(name: name, color: color, panes: panes,
                                            hidden: hidden))
            }
        }

        // projetos registrados no DevSync que faltam no JSON → template default
        for projectName in registeredProjects() where !list.contains(where: { $0.name == projectName }) {
            list.append(.defaultTemplate(name: projectName))
        }
        workspaces = list
    }

    private func registeredProjects() -> [String] {
        guard let text = try? String(contentsOf: Paths.projectsURL, encoding: .utf8) else { return [] }
        var names: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let name = line.split(separator: "|", maxSplits: 1)
                .first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    // MARK: Persistência (JSON atômico + generate)

    /// Grava o JSON completo (todos os workspaces, inclusive templates) e roda
    /// `devworkspace generate`. Retorna mensagem de erro ou nil em sucesso.
    func persist() async -> String? {
        // Relê o JSON do disco como base: edições externas em chaves que o app
        // não gerencia (default_model, chaves futuras) sobrevivem ao save.
        var root = rawRoot
        if let diskData = try? Data(contentsOf: Paths.configURL),
           let diskRoot = (try? JSONSerialization.jsonObject(with: diskData)) as? [String: Any] {
            root = diskRoot
        }
        root["autostart_agents"] = autostart
        if root["default_model"] == nil { root["default_model"] = "" }
        root["workspaces"] = workspaces.map { $0.jsonDict() }

        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            return "Falha ao serializar o JSON de configuração."
        }

        let url = Paths.configURL
        let writeError: String? = await Task.detached(priority: .userInitiated) {
            do {
                try atomicWrite(data, to: url)
                return nil
            } catch {
                return "Falha ao gravar \(url.path): \(error.localizedDescription)"
            }
        }.value
        if let writeError { return writeError }
        // Só avança o estado em memória depois que o disco confirmou.
        rawRoot = root

        let gen = await Shell.devworkspace(["generate"])
        if gen.status != 0 {
            let msg = gen.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return msg.isEmpty
                ? "devworkspace generate falhou (exit \(gen.status))."
                : msg
        }
        return nil
    }

    /// Salva a edição de um workspace (match por nome). Retorna erro ou nil.
    func saveWorkspace(_ edited: WorkspaceConfig) async -> String? {
        var ws = edited
        ws.fromTemplate = false
        if let idx = workspaces.firstIndex(where: { $0.name == ws.name }) {
            workspaces[idx] = ws
        } else {
            workspaces.append(ws)
        }
        // ao salvar qualquer edição, os templates pendentes também entram no JSON
        for i in workspaces.indices { workspaces[i].fromTemplate = false }
        let err = await persist()
        if err == nil {
            loadConfig()
            // refresh por evento após salvar o sheet
            Task { await self.pollStates() }
        }
        return err
    }

    func setAutostart(_ value: Bool) {
        let previous = autostart
        autostart = value
        Task {
            if let err = await persist() {
                autostart = previous
                globalError = err
            }
        }
    }

    /// Oculta/mostra um workspace (olhinho). Persiste "hidden" no JSON pelo
    /// fluxo normal (persist + generate); reverte em caso de erro.
    func setHidden(_ name: String, hidden: Bool) {
        guard let idx = workspaces.firstIndex(where: { $0.name == name }),
              workspaces[idx].hidden != hidden else { return }
        let previous = workspaces[idx].hidden
        workspaces[idx].hidden = hidden
        workspaces[idx].fromTemplate = false
        Task {
            if let err = await persist() {
                if let i = workspaces.firstIndex(where: { $0.name == name }) {
                    workspaces[i].hidden = previous
                }
                globalError = err
            }
        }
    }

    // MARK: Adicionar pasta como workspace

    /// `devworkspace add-project <path> <nome>` (registra no DevSync, git init
    /// se preciso; stdout = nome final) + template default no JSON.
    /// Retorna mensagem de erro ou nil em sucesso.
    private var addingProject = false

    func addProject(path: String, name: String) async -> String? {
        // guarda contra clique duplo antes do disabled(adding) re-renderizar
        guard !addingProject else { return nil }
        addingProject = true
        defer { addingProject = false }
        let res = await Shell.devworkspace(["add-project", path, name], serialized: true)
        guard res.status == 0 else {
            let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return msg.isEmpty
                ? "devworkspace add-project falhou (exit \(res.status))."
                : msg
        }
        // stdout = nome final (tolerante: última linha não vazia)
        let stdoutName = res.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        let finalName = stdoutName.isEmpty ? name : stdoutName

        // snapshot para reverter se o persist falhar (senão fica um workspace
        // fantasma na lista que ainda bloqueia nova tentativa por "duplicado")
        let before = workspaces
        if !workspaces.contains(where: { $0.name == finalName }) {
            var ws = WorkspaceConfig.defaultTemplate(name: finalName)
            ws.fromTemplate = false
            workspaces.append(ws)
        }
        for i in workspaces.indices { workspaces[i].fromTemplate = false }
        let err = await persist()   // JSON atômico + generate
        if err == nil {
            loadConfig()
            Task { await self.pollStates() }   // refresh por evento
        } else {
            workspaces = before
        }
        return err
    }

    // MARK: Abrir workspace

    func openWorkspace(_ name: String) {
        guard !opening.contains(name) else { return }
        guard states[name] != .notLocal else { return }
        opening.insert(name)
        Task {
            let res = await Shell.devworkspace(["ws", name], serialized: true)
            _ = await Shell.run(Paths.open, ["-a", "Ghostty"])
            opening.remove(name)
            if res.status != 0 {
                let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                globalError = msg.isEmpty
                    ? "Falha ao abrir o workspace “\(name)” (exit \(res.status))."
                    : msg
            }
            arrangeWithGhostty()   // gatilho: abriu workspace via clique
            await pollStates()     // refresh por evento
        }
    }

    // MARK: Polls

    func pollStates() async {
        guard !statesInFlight else { return }
        statesInFlight = true
        defer { statesInFlight = false }
        let res = await Shell.devworkspace(["states"])
        guard res.status == 0 else { return }
        var fresh: [String: WSState] = [:]
        for rawLine in res.stdout.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: "|").map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard parts.count >= 3, !parts[0].isEmpty else { continue }
            let name = parts[0]
            if parts[1] == "not-local" {
                fresh[name] = .notLocal
                continue
            }
            switch parts[2] {
            case "aberto": fresh[name] = .open
            case "fundo": fresh[name] = .background
            default: fresh[name] = .closed
            }
        }
        if !fresh.isEmpty { states = fresh }
    }

    func pollUsage() async {
        guard !usageInFlight else { return }
        usageInFlight = true
        defer { usageInFlight = false }
        let res = await Shell.devworkspace(["usage"])
        guard res.status == 0 else { return }
        usage = Self.parseUsage(res.stdout)
    }

    func refreshAll() {
        loadConfig()
        Task { await self.pollStates() }
        Task { await self.pollUsage() }
    }

    // MARK: Modelos por provider (`devworkspace models <p>`, cache 24h no CLI)

    /// Dispara o carregamento da lista de modelos de um provider (uma vez;
    /// re-tenta em aberturas futuras se a última resposta veio vazia/falhou).
    func loadModels(for provider: String) {
        guard kKnownCommands.contains(provider), provider != "shell" else { return }
        switch modelLists[provider] {
        case .loading:
            return
        case .ready(let list) where !list.isEmpty:
            return
        default:
            break
        }
        modelLists[provider] = .loading
        Task {
            let res = await Shell.devworkspace(["models", provider])
            let list = res.status == 0 ? Self.parseModels(res.stdout) : []
            modelLists[provider] = .ready(list)
        }
    }

    /// Parse tolerante de `id|nome_exibicao|effort1,effort2,...`.
    nonisolated static func parseModels(_ text: String) -> [ModelInfo] {
        var models: [ModelInfo] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.components(separatedBy: "|")
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !models.contains(where: { $0.id == id }) else { continue }
            let display = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces)
                : ""
            let efforts: [String] = parts.count > 2
                ? parts[2].split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                : []
            models.append(ModelInfo(
                id: id,
                displayName: display.isEmpty ? id : display,
                efforts: efforts))
        }
        return models
    }

    // MARK: Parse de uso (tolerante)

    nonisolated static func parseUsage(_ text: String) -> [UsageEntry] {
        var entries: [UsageEntry] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let agent = tokens.first, !agent.hasPrefix("(") else { continue }

            if tokens.count >= 2, tokens[1].hasPrefix("(") {
                entries.append(UsageEntry(agent: agent, windows: [], noData: true))
                continue
            }

            var windows: [UsageWindow] = []
            var i = 1
            while i + 1 < tokens.count + 1 && i < tokens.count {
                if i + 1 < tokens.count, tokens[i + 1].hasSuffix("%") {
                    let numText = String(tokens[i + 1].dropLast())
                    if let value = Double(numText) {
                        let pct = max(0, min(100, Int(value.rounded())))
                        windows.append(UsageWindow(label: tokens[i], percent: pct))
                        i += 2
                        continue
                    }
                }
                i += 1
            }
            guard !windows.isEmpty else { continue }
            entries.append(UsageEntry(agent: agent, windows: windows, noData: false))
        }
        return entries
    }
}

// MARK: - Tiling via Acessibilidade
// O AppleScript do Ghostty não expõe bounds — usamos a API AX.
// Coordenadas AX são globais com origem no TOPO-esquerda; Cocoa usa
// embaixo-esquerda, então convertemos via altura da tela primária.

let kGhosttyBundleID = "com.mitchellh.ghostty"

enum TileResult {
    case done
    case noPermission      // Acessibilidade não concedida
    case ghosttyNotRunning
    case noGhosttyWindow   // Ghostty rodando mas sem janela ainda
}

enum WindowTiler {
    /// faixa esquerda reservada ao DevSpaces
    static let sidebarWidth: CGFloat = 300
    /// o prompt do sistema só é disparado UMA vez por execução
    private static var promptedOnce = false

    private static func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !promptedOnce {
            promptedOnce = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        return AXIsProcessTrusted()
    }

    /// DevSpaces em faixa de 300 pt à esquerda (NSWindow nativo, ganha do
    /// frameAutosaveName); Ghostty em todo o resto (AX). Tudo-ou-nada:
    /// sem Ghostty ou sem permissão, nenhuma janela é movida.
    static func tile(appWindow: NSWindow?) -> TileResult {
        guard let ghostty = NSRunningApplication
            .runningApplications(withBundleIdentifier: kGhosttyBundleID).first,
            !ghostty.isTerminated
        else { return .ghosttyNotRunning }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return .ghosttyNotRunning
        }
        let visible = screen.visibleFrame   // Cocoa: origem embaixo-esquerda

        guard ensureTrusted() else { return .noPermission }

        // janela principal do Ghostty = primeira de kAXWindowsAttribute
        let appElement = AXUIElementCreateApplication(ghostty.processIdentifier)
        var windowsRef: CFTypeRef?
        let axErr = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard axErr == .success,
              let windows = windowsRef as? [AXUIElement],
              let target = windows.first
        else { return .noGhosttyWindow }

        // 1) DevSpaces: nativo, sem AX
        if let win = appWindow {
            let frame = NSRect(x: visible.minX, y: visible.minY,
                               width: sidebarWidth, height: visible.height)
            win.setFrame(frame, display: true)
        }

        // 2) Ghostty: todo o resto da área visível
        let rect = NSRect(x: visible.minX + sidebarWidth, y: visible.minY,
                          width: visible.width - sidebarWidth, height: visible.height)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? visible.maxY
        if !axSetFrame(target, rect, primaryHeight: primaryHeight) {
            // divergiu >20 pt na verificação → tenta mais 1 vez
            _ = axSetFrame(target, rect, primaryHeight: primaryHeight)
        }
        return .done
    }

    /// Aplica frame via AX com o quirk conhecido — size → position → size DE
    /// NOVO — e verifica lendo o size de volta (tolerância de 20 pt).
    /// (Bug corrigido: antes só a posição era aplicada de forma confiável e a
    /// janela ficava no tamanho original.)
    private static func axSetFrame(_ element: AXUIElement, _ rect: NSRect,
                                   primaryHeight: CGFloat) -> Bool {
        var position = CGPoint(x: rect.minX, y: primaryHeight - rect.maxY)
        var size = CGSize(width: rect.width, height: rect.height)
        guard let posValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }

        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)

        // verificação: lê o size de volta
        var readRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXSizeAttribute as CFString, &readRef) == .success,
              let readValue = readRef,
              CFGetTypeID(readValue) == AXValueGetTypeID()
        else { return false }
        var applied = CGSize.zero
        guard AXValueGetValue(readValue as! AXValue, .cgSize, &applied) else { return false }
        return abs(applied.width - size.width) <= 20
            && abs(applied.height - size.height) <= 20
    }
}

// MARK: - Split View nativo (menu do sistema + seletor do Dock via AX)
// Não há API pública para Split View. Estratégia (Sequoia 15.x):
//   1. Disparar o item que o sistema injeta no menu Window do PRÓPRIO app —
//      "Full Screen Tile → Left of Screen" (EN) / "Tela Cheia em Mosaico →
//      Lado Esquerdo da Tela" (PT). Matching flexível por `contains`, EN e PT
//      (apps não localizados ficam com menus em inglês mesmo em sistema pt-BR).
//   2. O macOS põe o DevSpaces em fullscreen-esquerda e abre o SELETOR de
//      janelas do lado direito — desenhado pelo processo Dock. Clicamos a
//      miniatura do Ghostty via AX (AXPress). Se não achar em ~3 s, desiste
//      em silêncio: o seletor fica aberto e o usuário completa com 1 clique.

enum SplitViewDriver {
    // MARK: 1) item de menu (sem AX — é o nosso próprio menu)

    /// Procura recursivamente em NSApp.mainMenu o item de tiling fullscreen
    /// esquerdo e dispara via sendAction. false = sistema não injetou o item.
    @MainActor
    static func triggerLeftFullScreenTile() -> Bool {
        guard let mainMenu = NSApp.mainMenu else { return false }

        // 1º: pelo submenu "Full Screen Tile" / "Tela Cheia em Mosaico"
        if let tileMenu = findSubmenu(in: mainMenu, where: { title in
            (title.contains("full screen") && title.contains("tile"))
                || title.contains("mosaico")
        }), let left = tileMenu.items.first(where: { isLeftTileTitle($0.title) }) {
            return fire(left)
        }
        // 2º: busca global pelo próprio item esquerdo
        if let left = findItem(in: mainMenu, where: { isLeftTileTitle($0.title) }) {
            return fire(left)
        }
        return false
    }

    private static func isLeftTileTitle(_ title: String) -> Bool {
        let t = title.lowercased()
        return t.contains("left of screen") || t.contains("lado esquerdo")
    }

    @MainActor
    private static func fire(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        // target nil → responder chain (aplica na janela key)
        return NSApp.sendAction(action, to: item.target, from: nil)
    }

    private static func findSubmenu(in menu: NSMenu,
                                    where predicate: (String) -> Bool) -> NSMenu? {
        for item in menu.items {
            guard let sub = item.submenu else { continue }
            if predicate(item.title.lowercased()) || predicate(sub.title.lowercased()) {
                return sub
            }
            if let found = findSubmenu(in: sub, where: predicate) { return found }
        }
        return nil
    }

    private static func findItem(in menu: NSMenu,
                                 where predicate: (NSMenuItem) -> Bool) -> NSMenuItem? {
        for item in menu.items {
            if predicate(item) { return item }
            if let sub = item.submenu,
               let found = findItem(in: sub, where: predicate) {
                return found
            }
        }
        return nil
    }

    // MARK: 2) seletor do Split View (processo Dock, via AX)

    /// Espera o seletor abrir (~1 s) e tenta AXPress na miniatura do Ghostty
    /// por até ~3 s. Roda inteiro em background — nunca bloqueia a main thread.
    static func clickGhosttyInSelector() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                Thread.sleep(forTimeInterval: 1.0)   // seletor abrindo
                let deadline = Date().addingTimeInterval(3.0)
                var pressed = false
                while Date() < deadline {
                    if pressGhosttyThumbnail() {
                        pressed = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.7)
                }
                cont.resume(returning: pressed)
            }
        }
    }

    /// Varre só as JANELAS do Dock (o seletor é uma janela dele; assim não
    /// encostamos nos ícones do Dock em si) atrás de um elemento clicável cujo
    /// título/descrição contenha "Ghostty", e dá AXPress nele (ou no pai).
    private static func pressGhosttyThumbnail() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return false }

        let dockApp = AXUIElementCreateApplication(dock.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  dockApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty
        else { return false }

        var stack: [AXUIElement] = windows
        var visited = 0
        while let element = stack.popLast() {
            visited += 1
            if visited > 4000 { break }   // teto de segurança na árvore AX
            let role = axString(element, kAXRoleAttribute) ?? ""
            if !role.contains("DockItem"), mentionsGhostty(element) {
                if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                    return true
                }
                // alguns seletores só aceitam o press no contêiner (AXGroup)
                if let parent = axElement(element, kAXParentAttribute),
                   AXUIElementPerformAction(parent, kAXPressAction as CFString) == .success {
                    return true
                }
            }
            stack.append(contentsOf: axChildren(element))
        }
        return false
    }

    private static func mentionsGhostty(_ element: AXUIElement) -> Bool {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let text = axString(element, attribute),
               text.lowercased().contains("ghostty") {
                return true
            }
        }
        return false
    }

    // MARK: helpers AX

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AXUIElement] else { return [] }
        return children
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element, attribute as CFString, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}

// MARK: - App
// Nota: sem `@main` — compilado como arquivo único em modo script
// (`swiftc DevSpaces.swift`), o entry point é a chamada explícita
// `DevSpacesApp.main()` no fim do arquivo. `@main` exigiria -parse-as-library.

struct DevSpacesApp: App {
    @StateObject private var store = Store()
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    var body: some Scene {
        Window("DevSpaces", id: "main") {
            ContentView()
                .environmentObject(store)
                // sheet aberto → level .floating temporário (restaura ao fechar)
                .background(WindowConfigurator(floatOnTop: alwaysOnTop || store.sheetOpen))
        }
        .defaultSize(width: 330, height: 680)
        .windowResizability(.contentMinSize)
    }
}

/// Aplica frameAutosaveName + nível flutuante na NSWindow hospedeira.
struct WindowConfigurator: NSViewRepresentable {
    var floatOnTop: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [floatOnTop] in
            Self.configure(view.window, floatOnTop: floatOnTop)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let float = floatOnTop
        DispatchQueue.main.async {
            Self.configure(nsView.window, floatOnTop: float)
        }
    }

    static func configure(_ window: NSWindow?, floatOnTop: Bool) {
        guard let window else { return }
        if window.frameAutosaveName != "DevSpacesMain" {
            window.setFrameAutosaveName("DevSpacesMain")
        }
        // Split View nativo: permite tiling fullscreen e trava a largura em
        // 300–340 pt (altura livre) — assim o divisor do Split View dá ~300 pt
        // pro DevSpaces e todo o resto pro Ghostty. Os sheets (520 pt) são
        // janelas próprias e não são afetados pelo contentMaxSize.
        window.collectionBehavior.insert(.fullScreenAllowsTiling)
        window.contentMinSize = NSSize(width: 300, height: 400)
        window.contentMaxSize = NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude)
        // .floating não combina com fullscreen: dentro do Split View não há
        // Ghostty por cima, então o level fica .normal lá.
        let isFullScreen = window.styleMask.contains(.fullScreen)
        window.level = (floatOnTop && !isFullScreen) ? .floating : .normal
        window.titlebarAppearsTransparent = true
    }
}

// MARK: - ContentView

/// Sheet ativo (um só de cada vez): editor de workspace ou adicionar pasta.
enum ActiveSheet: Identifiable, Equatable {
    case edit(WorkspaceConfig)
    case add(path: String, suggestedName: String)

    var id: String {
        switch self {
        case .edit(let ws): return "edit-\(ws.name)"
        case .add(let path, _): return "add-\(path)"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @State private var activeSheet: ActiveSheet?
    @State private var showHidden = false

    private var visibleWorkspaces: [WorkspaceConfig] {
        store.workspaces.filter { !$0.hidden }
    }
    private var hiddenWorkspaces: [WorkspaceConfig] {
        store.workspaces.filter { $0.hidden }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(visibleWorkspaces) { ws in
                        workspaceRow(ws, isHiddenRow: false)
                    }
                    if store.workspaces.isEmpty {
                        Text("Nenhum workspace registrado.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 24)
                    } else if visibleWorkspaces.isEmpty && !showHidden {
                        Text("Todos os workspaces estão ocultos.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 24)
                    }
                    if showHidden && !hiddenWorkspaces.isEmpty {
                        Text("OCULTOS")
                            .font(.system(size: 9.5, weight: .semibold))
                            .kerning(0.8)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 10)
                            .padding(.horizontal, 6)
                        ForEach(hiddenWorkspaces) { ws in
                            workspaceRow(ws, isHiddenRow: true)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            Divider()
            UsageSection(entries: store.usage)
            Divider()
            footer
        }
        .frame(minWidth: 300, idealWidth: 330, maxWidth: 420, minHeight: 440)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .edit(let ws):
                WorkspaceEditor(workspace: ws)
                    .environmentObject(store)
            case .add(let path, let suggestedName):
                AddProjectSheet(path: path, suggestedName: suggestedName)
                    .environmentObject(store)
            }
        }
        .onChange(of: activeSheet) { _, newValue in
            // sheet (520 pt) estoura pra direita sobre o Ghostty →
            // ativa o app, traz a janela pra frente e flutua enquanto aberto
            store.setSheetOpen(newValue != nil)
        }
        .alert("DevSpaces", isPresented: Binding(
            get: { store.globalError != nil },
            set: { if !$0 { store.globalError = nil } })
        ) {
            Button("OK", role: .cancel) { store.globalError = nil }
        } message: {
            Text(store.globalError ?? "")
        }
    }

    private func workspaceRow(_ ws: WorkspaceConfig, isHiddenRow: Bool) -> some View {
        WorkspaceRow(
            workspace: ws,
            state: store.states[ws.name] ?? .unknown,
            isOpening: store.opening.contains(ws.name),
            isHidden: isHiddenRow,
            onOpen: { store.openWorkspace(ws.name) },
            onEdit: { activeSheet = .edit(ws) },
            onToggleHidden: { store.setHidden(ws.name, hidden: !isHiddenRow) })
    }

    /// NSOpenPanel (só pastas) → mini-sheet com caminho + nome editável.
    private func pickFolderToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Escolher"
        panel.message = "Escolha a pasta do projeto que vira workspace"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        activeSheet = .add(path: url.path,
                           suggestedName: sanitizePaneName(url.lastPathComponent))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Workspaces")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                pickFolderToAdd()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Adicionar pasta como workspace")
            Button {
                store.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Recarregar configuração e estados")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !hiddenWorkspaces.isEmpty {
                Button {
                    showHidden.toggle()
                } label: {
                    Label(hiddenWorkspaces.count == 1
                            ? "1 oculto"
                            : "\(hiddenWorkspaces.count) ocultos",
                          systemImage: showHidden ? "eye" : "eye.slash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(showHidden
                      ? "Esconder os workspaces ocultos da lista"
                      : "Mostrar os workspaces ocultos na lista")
            }

            if store.accessibilityDenied {
                Label("Conceda Acessibilidade em Ajustes → Privacidade para organizar as janelas",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = store.splitViewNotice {
                Label(notice, systemImage: "rectangle.split.2x1")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: Binding(
                get: { store.autostart },
                set: { store.setAutostart($0) })
            ) {
                Text("Auto-iniciar agentes")
                    .font(.system(size: 12))
            }
            .help("Grava autostart_agents no workspaces.json e regenera o zsh")

            Toggle(isOn: $alwaysOnTop) {
                Text("Manter por cima")
                    .font(.system(size: 12))
            }
            .help("Mantém a janela do DevSpaces acima das outras")
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Linha de workspace

struct WorkspaceRow: View {
    let workspace: WorkspaceConfig
    let state: WSState
    let isOpening: Bool
    /// true quando a linha está na seção de ocultos (esmaecida + olho de restaurar)
    let isHidden: Bool
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onToggleHidden: () -> Void

    @State private var hovering = false

    private var accent: Color { Color(hexRGB: workspace.color) ?? .gray }
    private var clickable: Bool { state != .notLocal && !isOpening }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 4, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(workspace.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 6)

            if isOpening {
                ProgressView()
                    .controlSize(.small)
            } else {
                stateBadge
            }

            Button(action: onToggleHidden) {
                Image(systemName: isHidden ? "eye" : "eye.slash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // aparece no hover; nos ocultos fica sempre visível (é o restaurar)
            .opacity(hovering || isHidden ? 1 : 0)
            .help(isHidden
                  ? "Mostrar “\(workspace.name)” na lista"
                  : "Ocultar “\(workspace.name)” da lista")

            Button(action: onEdit) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .help("Configurar “\(workspace.name)”")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering && clickable ? Color.primary.opacity(0.07) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(isHidden ? 0.5 : (state == .notLocal ? 0.45 : 1))
        .onHover { hovering = $0 }
        .onTapGesture {
            if clickable { onOpen() }
        }
        .help(state == .notLocal
              ? "“\(workspace.name)” não está neste Mac"
              : "Abrir/focar “\(workspace.name)” no Ghostty")
    }

    private var stateBadge: some View {
        HStack(spacing: 4) {
            if state != .notLocal {
                Circle()
                    .fill(state.color)
                    .frame(width: 7, height: 7)
            }
            Text(state.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Seção de uso

struct UsageSection: View {
    let entries: [UsageEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("USO DOS AGENTES")
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.tertiary)

            if entries.isEmpty {
                Text("sem dados de uso")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .center, spacing: 8) {
                        Text(entry.agent)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .frame(width: 66, alignment: .leading)
                        if entry.noData {
                            Text("sem dados")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(entry.windows) { window in
                                UsageBar(window: window)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct UsageBar: View {
    let window: UsageWindow

    private var barColor: Color {
        if window.percent < 50 { return .green }
        if window.percent < 80 { return .yellow }
        return .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(window.label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(window.percent)%")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(3, geo.size.width * CGFloat(window.percent) / 100.0))
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: 90)
        .help("\(window.label): \(window.percent)%")
    }
}

// MARK: - Editor de workspace (sheet)

struct WorkspaceEditor: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var ws: WorkspaceConfig
    @State private var saving = false
    @State private var errorMessage: String?

    init(workspace: WorkspaceConfig) {
        _ws = State(initialValue: workspace)
    }

    private var accent: Color { Color(hexRGB: ws.color) ?? .gray }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    previewSection
                    colorRow
                    panesSection
                    if !problems.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(problems, id: \.self) { p in
                                Label(p, systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            bottomBar
        }
        .frame(width: 520, height: 560)
        .onAppear {
            // pré-carrega as listas de modelos (CLI tem cache de 24h)
            for provider in ["claude", "codex", "codex2"] {
                store.loadModels(for: provider)
            }
        }
        .alert("Erro ao salvar", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 10, height: 10)
            Text("Editar “\(ws.name)”")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var colorRow: some View {
        HStack(spacing: 10) {
            Text("Cor")
                .font(.system(size: 12, weight: .medium))
            ColorPicker("", selection: Binding(
                get: { Color(hexRGB: ws.color) ?? .gray },
                set: { ws.color = $0.hexRGBString }),
                supportsOpacity: false)
                .labelsHidden()
            Text(ws.color)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PREVIEW")
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.tertiary)
            LayoutPreview(panes: ws.panes, accent: accent)
        }
    }

    private var panesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SPLITS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    addPane()
                } label: {
                    Label("Adicionar split", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }

            ForEach($ws.panes) { $pane in
                let idx = ws.panes.firstIndex(where: { $0.id == pane.id }) ?? 0
                PaneEditorRow(
                    pane: $pane,
                    index: idx,
                    count: ws.panes.count,
                    accent: accent,
                    models: modelsFor(pane.command),
                    onMoveUp: { movePane(at: idx, offset: -1) },
                    onMoveDown: { movePane(at: idx, offset: 1) },
                    onDelete: { removePane(id: pane.id) })
            }

            Label("Abas já abertas só aplicam o novo layout depois de fechadas e reabertas.",
                  systemImage: "info.circle")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    private var bottomBar: some View {
        HStack {
            if saving {
                ProgressView()
                    .controlSize(.small)
                Text("Salvando…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancelar") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(saving)
            Button("Salvar") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(saving || !problems.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: ações

    /// nil = carregando; [] = indisponível (fallback texto); senão lista pronta
    private func modelsFor(_ command: String) -> [ModelInfo]? {
        guard command == "claude" || command == "codex" || command == "codex2" else {
            return nil
        }
        switch store.modelLists[command] {
        case .ready(let list): return list
        default: return nil
        }
    }

    private func addPane() {
        ws.panes.append(PaneConfig(command: "claude"))
    }

    private func removePane(id: UUID) {
        guard ws.panes.count > 1,
              let idx = ws.panes.firstIndex(where: { $0.id == id }) else { return }
        ws.panes.remove(at: idx)
    }

    private func movePane(at idx: Int, offset: Int) {
        let target = idx + offset
        guard ws.panes.indices.contains(idx), ws.panes.indices.contains(target) else { return }
        ws.panes.swapAt(idx, target)
    }

    private func save() {
        saving = true
        Task {
            var cleaned = ws
            // nomes são sempre derivados de programa+modelo (com -2, -3 p/ duplicatas)
            cleaned.regeneratePaneNames()
            let err = await store.saveWorkspace(cleaned)
            saving = false
            if let err {
                errorMessage = err   // não fecha o sheet
            } else {
                dismiss()
            }
        }
    }

    // MARK: validação leve

    private var problems: [String] {
        var out: [String] = []
        if ws.panes.isEmpty {
            return ["O workspace precisa de pelo menos 1 split."]
        }
        for (idx, pane) in ws.panes.enumerated() {
            if pane.command.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("Split \(idx + 1): comando vazio.")
            }
        }
        return out
    }
}

// MARK: - Preview do layout (mesma regra de posição do backend)
// n=1 → tela inteira; n≥2 → duas fileiras: em cima floor(n/2) splits,
// embaixo o resto (ímpar deixa a fileira de cima com menos splits).

struct LayoutPreview: View {
    let panes: [PaneConfig]
    let accent: Color

    var body: some View {
        let labels = derivedPaneNames(panes)
        let topCount = panes.count / 2
        VStack(spacing: 4) {
            if panes.isEmpty {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.3),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .overlay(
                        Text("nenhum split")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    )
            } else if panes.count == 1 {
                cell(number: 1, label: labels[0])
            } else {
                HStack(spacing: 4) {
                    ForEach(0..<topCount, id: \.self) { i in
                        cell(number: i + 1, label: labels[i])
                    }
                }
                HStack(spacing: 4) {
                    ForEach(topCount..<panes.count, id: \.self) { i in
                        cell(number: i + 1, label: labels[i])
                    }
                }
            }
        }
        .frame(height: 96)
        .animation(.easeInOut(duration: 0.15), value: panes.map(\.id))
    }

    private func cell(number: Int, label: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(accent.opacity(0.18))
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(accent.opacity(0.5), lineWidth: 1)
            VStack(spacing: 1) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
                Text(label)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Linha do editor de pane

struct PaneEditorRow: View {
    @Binding var pane: PaneConfig
    let index: Int
    let count: Int
    let accent: Color
    /// nil = carregando; [] = lista indisponível (fallback de texto)
    let models: [ModelInfo]?
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    /// Fallback por provider quando a lista dinâmica não traz efforts.
    private static func fallbackEfforts(for command: String) -> [String] {
        switch command {
        case "codex", "codex2": return ["low", "medium", "high", "xhigh", "max", "ultra"]
        default: return ["low", "medium", "high", "xhigh", "max"]
        }
    }

    private var isCustomCommand: Bool { !kKnownCommands.contains(pane.command) }

    private var commandSelection: Binding<String> {
        Binding(
            get: { kKnownCommands.contains(pane.command) ? pane.command : kCustomTag },
            set: { newValue in
                if newValue == kCustomTag {
                    if kKnownCommands.contains(pane.command) { pane.command = "" }
                } else if pane.command != newValue {
                    pane.command = newValue
                    // trocar de provider invalida modelo e effort
                    pane.model = ""
                    pane.effort = ""
                }
            })
    }

    /// Efforts válidos para o modelo atual: os do modelo, ou (modelo = default)
    /// a união dos efforts do provider, ou a lista padrão.
    private static func effortOptions(for model: String, in models: [ModelInfo], command: String) -> [String] {
        if !model.isEmpty, let m = models.first(where: { $0.id == model }) {
            return m.efforts
        }
        var union: [String] = []
        for m in models {
            for e in m.efforts where !union.contains(e) {
                union.append(e)
            }
        }
        return union.isEmpty ? fallbackEfforts(for: command) : union
    }

    private func modelSelection(_ models: [ModelInfo]) -> Binding<String> {
        Binding(
            get: { pane.model },
            set: { newModel in
                pane.model = newModel
                // effort que não existe no novo modelo volta pra default
                let opts = Self.effortOptions(for: newModel, in: models, command: pane.command)
                if !pane.effort.isEmpty, !opts.contains(pane.effort) {
                    pane.effort = ""
                }
            })
    }

    var body: some View {
        HStack(spacing: 8) {
            // número da posição
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(accent.opacity(0.15)))

            // programa
            Picker("", selection: commandSelection) {
                ForEach(kKnownCommands, id: \.self) { cmd in
                    Text(cmd).tag(cmd)
                }
                Text("custom…").tag(kCustomTag)
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 88)

            if isCustomCommand {
                TextField("comando", text: $pane.command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            } else if pane.isAgent {
                agentControls
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }

            // reordenar
            HStack(spacing: 2) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == 0 ? Color.secondary.opacity(0.3) : Color.secondary)
                .disabled(index == 0)
                .help("Mover para cima")

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == count - 1 ? Color.secondary.opacity(0.3) : Color.secondary)
                .disabled(index == count - 1)
                .help("Mover para baixo")
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(count <= 1 ? Color.secondary.opacity(0.3) : Color.secondary)
            .disabled(count <= 1)
            .help(count <= 1 ? "Precisa sobrar pelo menos 1 split" : "Remover split")
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    // MARK: modelo + effort (só para claude/codex/codex2)

    @ViewBuilder
    private var agentControls: some View {
        if let models {
            if models.isEmpty {
                // lista indisponível → fallback de texto livre
                TextField("modelo", text: $pane.model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 96)
                    .help("Modelo do agente (vazio = default)")
                TextField("effort", text: $pane.effort)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 64)
                    .help("Effort de raciocínio (vazio = default)")
            } else {
                modelPicker(models)
                effortPicker(models)
            }
        } else {
            // ainda buscando a lista
            Picker("", selection: .constant("")) {
                Text("carregando…").tag("")
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 120)
            .disabled(true)
        }
    }

    private func modelPicker(_ models: [ModelInfo]) -> some View {
        Picker("", selection: modelSelection(models)) {
            Text("default").tag("")
            ForEach(models) { m in
                Text(m.displayName).tag(m.id)
            }
            // id gravado no JSON que não está (mais) na lista → opção extra
            if !pane.model.isEmpty, !models.contains(where: { $0.id == pane.model }) {
                Text(pane.model).tag(pane.model)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(minWidth: 104, maxWidth: 148)
        .help("Modelo do agente (default = sem flag)")
    }

    private func effortPicker(_ models: [ModelInfo]) -> some View {
        let opts = Self.effortOptions(for: pane.model, in: models, command: pane.command)
        return Picker("", selection: $pane.effort) {
            Text("default").tag("")
            ForEach(opts, id: \.self) { e in
                Text(e).tag(e)
            }
            if !pane.effort.isEmpty, !opts.contains(pane.effort) {
                Text(pane.effort).tag(pane.effort)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 84)
        .help("Effort de raciocínio (default = sem flag)")
    }
}

// MARK: - Mini-sheet: adicionar pasta como workspace

struct AddProjectSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    let path: String
    @State private var name: String
    @State private var adding = false
    @State private var errorMessage: String?

    init(path: String, suggestedName: String) {
        self.path = path
        _name = State(initialValue: suggestedName)
    }

    private var problems: [String] {
        if name.isEmpty {
            return ["O nome não pode ser vazio."]
        }
        var out: [String] = []
        // '|' separa nome|path no registro do DevSync
        let invalid = CharacterSet(charactersIn: ":,|").union(.whitespacesAndNewlines)
        if name.rangeOfCharacter(from: invalid) != nil {
            out.append("O nome não pode ter espaço, “:”, “,” ou “|”.")
        }
        if store.workspaces.contains(where: { $0.name == name }) {
            out.append("Já existe um workspace chamado “\(name)”.")
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Adicionar workspace")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PASTA")
                        .font(.system(size: 9.5, weight: .semibold))
                        .kerning(0.8)
                        .foregroundStyle(.tertiary)
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("NOME")
                        .font(.system(size: 9.5, weight: .semibold))
                        .kerning(0.8)
                        .foregroundStyle(.tertiary)
                    TextField("nome", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Text("É o alias que você usa em “devworkspace ws <nome>”.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                if !problems.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(problems, id: \.self) { p in
                            Label(p, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(16)

            Divider()

            HStack {
                if adding {
                    ProgressView()
                        .controlSize(.small)
                    Text("Adicionando…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(adding)
                Button("Adicionar") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(adding || !problems.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .frame(width: 420)
        .alert("Erro ao adicionar", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func add() {
        adding = true
        Task {
            let err = await store.addProject(path: path, name: name)
            adding = false
            if let err {
                errorMessage = err   // não fecha o mini-sheet
            } else {
                dismiss()
            }
        }
    }
}

// MARK: - Entry point (modo script; ver nota na declaração do App)

DevSpacesApp.main()
