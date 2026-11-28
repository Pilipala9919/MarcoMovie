// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Complete Functional Settings Detail View Controllers (All 10 Categories)

import MarcoIOSCore
import UIKit

// MARK: - Shared Settings Table Base

public class MarcoBaseSettingsTableController: UITableViewController {
    public init(pageTitle: String) {
        super.init(style: .insetGrouped)
        self.title = pageTitle
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = MarcoColors.canvasBackground
        navigationItem.largeTitleDisplayMode = .never
    }

    func makeValueCell(title: String, detail: String? = nil, accessory: UITableViewCell.AccessoryType = .none) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = MarcoColors.cardSurface
        cell.textLabel?.text = title
        cell.textLabel?.font = MarcoTypography.body
        cell.textLabel?.textColor = MarcoColors.primaryText
        cell.detailTextLabel?.text = detail
        cell.detailTextLabel?.font = MarcoTypography.cardSubtitle
        cell.detailTextLabel?.textColor = MarcoColors.secondaryText
        cell.accessoryType = accessory
        return cell
    }

    func makeSubtitleCell(title: String, subtitle: String, accessory: UITableViewCell.AccessoryType = .none) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = MarcoColors.cardSurface
        cell.textLabel?.text = title
        cell.textLabel?.font = MarcoTypography.cardTitle
        cell.textLabel?.textColor = MarcoColors.primaryText
        cell.detailTextLabel?.text = subtitle
        cell.detailTextLabel?.font = MarcoTypography.caption
        cell.detailTextLabel?.textColor = MarcoColors.secondaryText
        cell.detailTextLabel?.numberOfLines = 2
        cell.accessoryType = accessory
        return cell
    }

    func makeToggleCell(title: String, subtitle: String? = nil, isOn: Bool, onChange: @escaping (Bool) -> Void) -> UITableViewCell {
        let cell = subtitle == nil
            ? makeValueCell(title: title)
            : makeSubtitleCell(title: title, subtitle: subtitle!)
        cell.selectionStyle = .none
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.onTintColor = MarcoColors.accentTint
        toggle.addAction(UIAction { [weak toggle] _ in
            guard let toggle = toggle else { return }
            MarcoHaptics.selection()
            onChange(toggle.isOn)
        }, for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - 1. 片源与订阅管理

public final class SourcesSettingsViewController: MarcoBaseSettingsTableController {
    private var subscriptions: [SubscriptionEntry] = []

    public init() { super.init(pageTitle: "片源与订阅管理") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        reloadList()
    }

    private func reloadList() {
        let store = AppStateStore.shared
        subscriptions = store.storage.subscriptions().filter {
            store.isPrivacySpaceUnlocked || !$0.isEffectivelyPrivate
        }
        tableView.reloadData()
    }

    public override func numberOfSections(in tableView: UITableView) -> Int { 4 }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "导入订阅源"
        case 1: return "已配置订阅（\(subscriptions.count)）"
        case 2: return "蜘蛛网关（BYO Spider Gateway）"
        case 3: return "本机内置脚本与解码运行时状态"
        default: return nil
        }
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 2
        case 1: return max(subscriptions.count, 1)
        case 2: return 2
        case 3: return 4
        default: return 0
        }
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let store = AppStateStore.shared
        switch indexPath.section {
        case 0:
            if indexPath.row == 0 {
                return makeSubtitleCell(title: "添加远程 URL 订阅", subtitle: "支持 TVBox / CatVod JSON、多仓地址与 Base64/隐写配置", accessory: .disclosureIndicator)
            }
            return makeSubtitleCell(title: "粘贴本地 JSON 配置", subtitle: "直接导入文本格式的片源配置", accessory: .disclosureIndicator)

        case 1:
            if subscriptions.isEmpty {
                let cell = makeValueCell(title: "暂未导入任何订阅源")
                cell.selectionStyle = .none
                cell.textLabel?.textColor = MarcoColors.secondaryText
                return cell
            }
            let sub = subscriptions[indexPath.row]
            let depotNote = sub.activeDepotName.isEmpty ? "" : " · 仓：\(sub.activeDepotName)"
            let privNote = sub.isEffectivelyPrivate ? " · 隐私" : ""
            return makeSubtitleCell(
                title: sub.name,
                subtitle: "\(sub.siteCount) 站点 / \(sub.liveCount) 直播\(depotNote)\(privNote)",
                accessory: .disclosureIndicator
            )

        case 2:
            let gw = store.storage.spiderGatewayConfig()
            if indexPath.row == 0 {
                return makeToggleCell(title: "启用蜘蛛网关", subtitle: "将 Android JAR 类型源转发至您自建的网关节点", isOn: gw.enabled) { [weak self] on in
                    var next = store.storage.spiderGatewayConfig()
                    next.enabled = on
                    try? store.storage.saveSpiderGatewayConfig(next)
                    self?.tableView.reloadSections(IndexSet(integer: 2), with: .none)
                }
            }
            return makeValueCell(
                title: "网关地址与密钥",
                detail: gw.baseUrl.isEmpty ? "未配置" : gw.baseUrl,
                accessory: .disclosureIndicator
            )

        default:
            let runtimes: [(String, Bool, String)] = [
                ("QuickJS 引擎（DRPY2 / JS 源）", MarcoBuildCapabilities.hasQuickJS, "已内置"),
                ("CatPaw Node.js 运行时", MarcoBuildCapabilities.hasCatpaw, MarcoBuildCapabilities.hasCatpaw ? "完整版已嵌入" : "轻量模拟器模式"),
                ("CPython 3 原生运行时", MarcoBuildCapabilities.hasCPython, MarcoBuildCapabilities.hasCPython ? "完整版已嵌入" : "轻量模拟器模式"),
                ("libmpv 全能播放内核", MarcoBuildCapabilities.hasMpv, MarcoBuildCapabilities.hasMpv ? "完整版已嵌入" : "轻量模拟器模式"),
            ]
            let info = runtimes[indexPath.row]
            let cell = makeValueCell(title: info.0, detail: info.2)
            cell.detailTextLabel?.textColor = info.1 ? MarcoColors.success : MarcoColors.secondaryText
            cell.selectionStyle = .none
            return cell
        }
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.section {
        case 0:
            indexPath.row == 0 ? promptAddUrlSubscription() : promptAddJsonSubscription()
        case 1:
            guard indexPath.row < subscriptions.count else { return }
            presentSubscriptionActions(subscriptions[indexPath.row])
        case 2 where indexPath.row == 1:
            promptConfigureGateway()
        default:
            break
        }
    }

    public override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 1 && !subscriptions.isEmpty
    }

    public override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.section == 1, indexPath.row < subscriptions.count else { return }
        let target = subscriptions[indexPath.row]
        AppStateStore.shared.storage.removeSubscription(id: target.id)
        AppStateStore.shared.reloadConfig()
        reloadList()
    }

    private func promptAddUrlSubscription() {
        let alert = UIAlertController(title: "添加远程订阅源", message: "输入您的自有合规订阅 URL。", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "名称（选填）" }
        alert.addTextField {
            $0.placeholder = "https:// 订阅地址"
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "导入", style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text ?? ""
            let url = alert?.textFields?.last?.text ?? ""
            guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { [weak self] in
                do {
                    _ = try await AppStateStore.shared.addSubscriptionFromUrl(
                        url,
                        name: name,
                        isPrivate: AppStateStore.shared.isPrivacySpaceUnlocked
                    )
                    self?.reloadList()
                } catch {
                    self?.showMessage(title: "导入失败", message: error.localizedDescription)
                }
            }
        })
        present(alert, animated: true)
    }

    private func promptAddJsonSubscription() {
        let alert = UIAlertController(title: "导入本地 JSON 配置", message: "粘贴完整 JSON 文本内容。", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "订阅名称" }
        alert.addTextField { $0.placeholder = "粘贴 JSON 文本" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text ?? "本地订阅"
            let raw = alert?.textFields?.last?.text ?? ""
            do {
                _ = try AppStateStore.shared.addSubscriptionFromRawJson(
                    raw,
                    name: name,
                    isPrivate: AppStateStore.shared.isPrivacySpaceUnlocked
                )
                self?.reloadList()
            } catch {
                self?.showMessage(title: "解析失败", message: error.localizedDescription)
            }
        })
        present(alert, animated: true)
    }

    private func presentSubscriptionActions(_ sub: SubscriptionEntry) {
        let sheet = UIAlertController(title: sub.name, message: sub.url.isEmpty ? "本地 JSON 配置" : sub.url, preferredStyle: .actionSheet)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)

        if !sub.depots.isEmpty {
            for depot in sub.depots.prefix(8) {
                let mark = (depot.name == sub.activeDepotName) ? "✓ " : ""
                sheet.addAction(UIAlertAction(title: "\(mark)切换仓库：\(depot.name)", style: .default) { [weak self] _ in
                    Task { [weak self] in
                        do {
                            try await AppStateStore.shared.switchDepot(depot, for: sub)
                            self?.reloadList()
                        } catch {
                            self?.showMessage(title: "切仓失败", message: error.localizedDescription)
                        }
                    }
                })
            }
        }
        sheet.addAction(UIAlertAction(title: sub.enabled ? "禁用此订阅" : "启用此订阅", style: .default) { [weak self] _ in
            var all = AppStateStore.shared.storage.subscriptions()
            if let idx = all.firstIndex(where: { $0.id == sub.id }) {
                all[idx].enabled.toggle()
                AppStateStore.shared.storage.saveSubscriptions(all)
                AppStateStore.shared.reloadConfig()
                self?.reloadList()
            }
        })
        sheet.addAction(UIAlertAction(title: "删除订阅", style: .destructive) { [weak self] _ in
            AppStateStore.shared.storage.removeSubscription(id: sub.id)
            AppStateStore.shared.reloadConfig()
            self?.reloadList()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }

    private func promptConfigureGateway() {
        let gw = AppStateStore.shared.storage.spiderGatewayConfig()
        let alert = UIAlertController(title: "配置蜘蛛网关", message: "输入您自建的网关地址与鉴权 Token。", preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "网关地址（http:// 或 https://）"
            $0.text = gw.baseUrl
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
        }
        alert.addTextField {
            $0.placeholder = "网关密钥 Token（存入钥匙串）"
            $0.text = gw.token
            $0.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            var next = gw
            next.baseUrl = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            next.token = alert?.textFields?.last?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? AppStateStore.shared.storage.saveSpiderGatewayConfig(next)
            self?.tableView.reloadSections(IndexSet(integer: 2), with: .none)
        })
        present(alert, animated: true)
    }
}

// MARK: - 2. 网盘账号（五大网盘：夸克 / UC / 百度 / 阿里 / 115）

public final class NetdiskAccountsSettingsViewController: MarcoBaseSettingsTableController {
    private var orderedDrives: [NetdiskProvider] = NetdiskProvider.defaultOrder
    private var qrPollTask: Task<Void, Never>?

    public init() { super.init(pageTitle: "网盘账号（五大网盘）") }

    deinit { qrPollTask?.cancel() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        loadDriveOrder()
    }

    private func loadDriveOrder() {
        let raw = AppStateStore.shared.storage.preferences().netdiskDriveOrder
        let mapped = raw.compactMap { NetdiskProvider.fromKey($0) }
        var result = mapped
        for p in NetdiskProvider.defaultOrder where !result.contains(p) {
            result.append(p)
        }
        orderedDrives = result
        tableView.reloadData()
    }

    public override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "五大网盘授权状态（凭证安全存储于 Apple Keychain）" : "选线策略与优先级"
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? orderedDrives.count : 2
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let store = AppStateStore.shared
        if indexPath.section == 0 {
            let provider = orderedDrives[indexPath.row]
            let loggedIn = store.storage.isNetdiskLoggedIn(provider.rawValue)
            let cell = makeValueCell(
                title: "\(indexPath.row + 1). \(provider.displayName)",
                detail: loggedIn ? "已登录" : "未登录",
                accessory: .disclosureIndicator
            )
            cell.detailTextLabel?.textColor = loggedIn ? MarcoColors.success : MarcoColors.secondaryText
            return cell
        }
        if indexPath.row == 0 {
            let prefs = store.storage.preferences()
            return makeToggleCell(
                title: "优先选择已登录网盘线路",
                subtitle: "多网盘分享线路并存时，自动优先排序已授权网盘",
                isOn: prefs.prioritizeLoggedInDrives
            ) { on in
                store.storage.updatePreferences { $0.prioritizeLoggedInDrives = on }
            }
        }
        return makeValueCell(title: "调整网盘优先级顺序", detail: orderedDrives.map(\.displayName).joined(separator: " > "), accessory: .disclosureIndicator)
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            presentDriveActionSheet(for: orderedDrives[indexPath.row])
        } else if indexPath.row == 1 {
            // Rotate first drive to end as quick priority adjustment
            if let first = orderedDrives.first {
                orderedDrives.removeFirst()
                orderedDrives.append(first)
                AppStateStore.shared.storage.updatePreferences {
                    $0.netdiskDriveOrder = orderedDrives.map(\.rawValue)
                }
                tableView.reloadData()
            }
        }
    }

    private func presentDriveActionSheet(for provider: NetdiskProvider) {
        let store = AppStateStore.shared
        let loggedIn = store.storage.isNetdiskLoggedIn(provider.rawValue)
        let sheet = UIAlertController(
            title: provider.displayName,
            message: loggedIn ? "当前已授权登录，可重新授权或退出。" : "选择授权方式以启用原画直出与个人云盘浏览。",
            preferredStyle: .actionSheet
        )
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)

        sheet.addAction(UIAlertAction(title: "原生网页登录授权", style: .default) { [weak self] _ in
            self?.launchWebAuth(for: provider)
        })
        sheet.addAction(UIAlertAction(title: "生成二维码扫码登录", style: .default) { [weak self] _ in
            self?.launchQrLogin(for: provider)
        })
        sheet.addAction(UIAlertAction(title: "手动粘贴 Cookie / Token", style: .default) { [weak self] _ in
            self?.promptManualCredential(for: provider)
        })
        if loggedIn {
            sheet.addAction(UIAlertAction(title: "退出登录并清除凭证", style: .destructive) { [weak self] _ in
                try? store.storage.removeNetdiskCredential(for: provider.rawValue)
                NotificationCenter.default.post(name: .marcoStateDidChange, object: store)
                self?.tableView.reloadData()
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }

    private func launchWebAuth(for provider: NetdiskProvider) {
        guard let kind = NetdiskDriveKind(identifier: provider.rawValue) else { return }
        NetdiskWebAuthViewController.present(from: self, drive: kind) { [weak self] result in
            guard let self = self, let result = result else { return }
            switch result {
            case .credential(let raw):
                let normalized = NetdiskSessionValidator.normalizeCredential(driveKey: provider.rawValue, rawCredential: raw)
                try? AppStateStore.shared.storage.setNetdiskCredential(normalized, for: provider.rawValue)
                NotificationCenter.default.post(name: .marcoStateDidChange, object: AppStateStore.shared)
                self.tableView.reloadData()
            case .bizExt(let biz):
                if let rt = NetdiskService.extractAliRefreshTokenFromBizExt(biz) {
                    try? AppStateStore.shared.storage.setNetdiskCredential("ali_token=\(rt)", for: provider.rawValue)
                    NotificationCenter.default.post(name: .marcoStateDidChange, object: AppStateStore.shared)
                    self.tableView.reloadData()
                }
            case .openScanApp:
                self.launchQrLogin(for: provider)
            }
        }
    }

    private func launchQrLogin(for provider: NetdiskProvider) {
        qrPollTask?.cancel()
        let alert = UIAlertController(title: "\(provider.displayName) 扫码登录", message: "正在获取登录二维码…", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.qrPollTask?.cancel()
        })
        present(alert, animated: true)

        qrPollTask = Task { [weak self, weak alert] in
            guard let self = self else { return }
            do {
                let session = try await AppStateStore.shared.netdiskService.startQrSession(driveKey: provider.rawValue)
                if let qrImg = MarcoQrCodeGenerator.image(for: session.qrUrl, size: CGSize(width: 200, height: 200)) {
                    let imgVC = UIViewController()
                    let iv = UIImageView(image: qrImg)
                    iv.contentMode = .scaleAspectFit
                    iv.translatesAutoresizingMaskIntoConstraints = false
                    imgVC.view.addSubview(iv)
                    NSLayoutConstraint.activate([
                        iv.centerXAnchor.constraint(equalTo: imgVC.view.centerXAnchor),
                        iv.topAnchor.constraint(equalTo: imgVC.view.topAnchor, constant: 8),
                        iv.bottomAnchor.constraint(equalTo: imgVC.view.bottomAnchor, constant: -8),
                        iv.widthAnchor.constraint(equalToConstant: 184),
                        iv.heightAnchor.constraint(equalToConstant: 184),
                    ])
                    alert?.setValue(imgVC, forKey: "contentViewController")
                }
                alert?.message = "请使用对应网盘 App 扫描二维码并确认登录"

                for _ in 0..<60 {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let poll = await AppStateStore.shared.netdiskService.pollQrSession(session)
                    alert?.message = poll.message
                    if poll.state == .confirmed && !poll.credential.isEmpty {
                        try? AppStateStore.shared.storage.setNetdiskCredential(poll.credential, for: provider.rawValue)
                        NotificationCenter.default.post(name: .marcoStateDidChange, object: AppStateStore.shared)
                        alert?.dismiss(animated: true)
                        self.tableView.reloadData()
                        return
                    }
                    if poll.state == .expired {
                        return
                    }
                }
            } catch {
                alert?.message = error.localizedDescription
            }
        }
    }

    private func promptManualCredential(for provider: NetdiskProvider) {
        let alert = UIAlertController(title: "手动输入 \(provider.displayName) 凭证", message: "请输入 Cookie 或 Refresh Token。", preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = provider == .ali ? "refresh_token" : "完整 Cookie 字符串"
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            let raw = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty else { return }
            let normalized = NetdiskSessionValidator.normalizeCredential(driveKey: provider.rawValue, rawCredential: raw)
            try? AppStateStore.shared.storage.setNetdiskCredential(normalized, for: provider.rawValue)
            NotificationCenter.default.post(name: .marcoStateDidChange, object: AppStateStore.shared)
            self?.tableView.reloadData()
        })
        present(alert, animated: true)
    }
}

// MARK: - 3. 媒体库与局域网（Emby / Jellyfin / Plex / WebDAV / AList / SMB2）

public final class MediaLibrarySettingsViewController: MarcoBaseSettingsTableController {
    private var embyAccounts: [EmbyAccount] = []
    private var otherAccounts: [MediaLibraryAccount] = []

    public init() { super.init(pageTitle: "媒体库与局域网") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        reloadAccounts()
    }

    private func reloadAccounts() {
        embyAccounts = AppStateStore.shared.storage.embyAccounts()
        otherAccounts = AppStateStore.shared.storage.mediaLibraryAccounts()
        tableView.reloadData()
    }

    public override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "添加媒体服务器或 NAS"
        case 1: return "Emby 服务器（\(embyAccounts.count)）"
        case 2: return "Jellyfin / Plex / WebDAV / AList / SMB2（\(otherAccounts.count)）"
        default: return nil
        }
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 1
        case 1: return max(embyAccounts.count, 1)
        case 2: return max(otherAccounts.count, 1)
        default: return 0
        }
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            return makeSubtitleCell(
                title: "添加媒体库 / 局域网共享",
                subtitle: "支持 Emby、Jellyfin、Plex、WebDAV、AList、SMB2",
                accessory: .disclosureIndicator
            )
        }
        if indexPath.section == 1 {
            if embyAccounts.isEmpty {
                let c = makeValueCell(title: "未添加 Emby 账号")
                c.selectionStyle = .none
                c.textLabel?.textColor = MarcoColors.secondaryText
                return c
            }
            let acc = embyAccounts[indexPath.row]
            return makeSubtitleCell(title: acc.label.isEmpty ? "Emby" : acc.label, subtitle: "\(acc.baseUrl) · 点击测试连通性", accessory: .disclosureIndicator)
        }
        if otherAccounts.isEmpty {
            let c = makeValueCell(title: "未添加其他媒体库或 SMB 共享")
            c.selectionStyle = .none
            c.textLabel?.textColor = MarcoColors.secondaryText
            return c
        }
        let acc = otherAccounts[indexPath.row]
        let addr = acc.baseUrl.isEmpty ? "\(acc.host)/\(acc.shareName)" : acc.baseUrl
        return makeSubtitleCell(title: "[\(acc.kind.displayName)] \(acc.label)", subtitle: "\(addr) · 点击测试连通性", accessory: .disclosureIndicator)
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            presentAddKindPicker()
        } else if indexPath.section == 1, indexPath.row < embyAccounts.count {
            let acc = embyAccounts[indexPath.row]
            testConnection(site: CmsSite(key: "emby_\(acc.key)", name: acc.label, type: 3, api: "\(ExternalMediaLibraryDispatcher.embyPrefix)\(acc.key)"))
        } else if indexPath.section == 2, indexPath.row < otherAccounts.count {
            let acc = otherAccounts[indexPath.row]
            let prefix: String
            switch acc.kind {
            case .emby: prefix = ExternalMediaLibraryDispatcher.embyPrefix
            case .jellyfin: prefix = ExternalMediaLibraryDispatcher.jellyfinPrefix
            case .plex: prefix = ExternalMediaLibraryDispatcher.plexPrefix
            case .webdav: prefix = ExternalMediaLibraryDispatcher.webdavPrefix
            case .alist: prefix = ExternalMediaLibraryDispatcher.alistPrefix
            case .smb2: prefix = ExternalMediaLibraryDispatcher.smbPrefix
            case .local, .personalCloud: prefix = ExternalMediaLibraryDispatcher.localPrefix
            }
            testConnection(site: CmsSite(key: "\(acc.kind.rawValue)_\(acc.key)", name: acc.label, type: 3, api: "\(prefix)\(acc.key)"))
        }
    }

    public override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        (indexPath.section == 1 && !embyAccounts.isEmpty) || (indexPath.section == 2 && !otherAccounts.isEmpty)
    }

    public override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        if indexPath.section == 1 && indexPath.row < embyAccounts.count {
            embyAccounts.remove(at: indexPath.row)
            AppStateStore.shared.storage.saveEmbyAccounts(embyAccounts)
        } else if indexPath.section == 2 && indexPath.row < otherAccounts.count {
            otherAccounts.remove(at: indexPath.row)
            AppStateStore.shared.storage.saveMediaLibraryAccounts(otherAccounts)
        }
        NotificationCenter.default.post(name: .marcoStateDidChange, object: AppStateStore.shared)
        reloadAccounts()
    }

    private func presentAddKindPicker() {
        let kinds: [MediaLibraryKind] = [.emby, .jellyfin, .plex, .webdav, .alist, .smb2]
        let sheet = UIAlertController(title: "选择协议类型", message: nil, preferredStyle: .actionSheet)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        for kind in kinds {
            sheet.addAction(UIAlertAction(title: kind.displayName, style: .default) { [weak self] _ in
                self?.promptAddAccount(kind: kind)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }

    private func promptAddAccount(kind: MediaLibraryKind) {
        let alert = UIAlertController(title: "添加 \(kind.displayName)", message: "密码与 Token 将存入系统钥匙串。", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "名称（例如：家庭 NAS）" }
        alert.addTextField {
            $0.placeholder = kind == .smb2 ? "主机名或局域网 IP" : "服务器地址（http:// 或 https://）"
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
        }
        alert.addTextField {
            $0.placeholder = kind == .smb2 ? "共享名（例如：Media）" : "用户名 / UserId（选填）"
            $0.autocapitalizationType = .none
        }
        alert.addTextField {
            $0.placeholder = "密码或 API Token"
            $0.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let fields = alert?.textFields, fields.count == 4 else { return }
            let label = fields[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let endpoint = fields[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let userOrShare = fields[2].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let secret = fields[3].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !endpoint.isEmpty else { return }
            let key = UUID().uuidString.prefix(8).lowercased()

            if kind == .emby {
                var list = AppStateStore.shared.storage.embyAccounts()
                list.append(EmbyAccount(
                    key: String(key),
                    label: label.isEmpty ? "Emby" : label,
                    baseUrl: endpoint,
                    username: userOrShare,
                    userId: userOrShare,
                    accessToken: secret,
                    updatedAt: Int64(Date().timeIntervalSince1970 * 1000)
                ))
                AppStateStore.shared.storage.saveEmbyAccounts(list)
            } else {
                var list = AppStateStore.shared.storage.mediaLibraryAccounts()
                let account = MediaLibraryAccount(
                    kind: kind,
                    key: String(key),
                    label: label.isEmpty ? kind.displayName : label,
                    baseUrl: kind == .smb2 ? "" : endpoint,
                    host: kind == .smb2 ? endpoint : "",
                    shareName: kind == .smb2 ? userOrShare : "",
                    username: kind == .smb2 ? "" : userOrShare,
                    userId: userOrShare,
                    updatedAt: Int64(Date().timeIntervalSince1970 * 1000)
                )
                list.append(account)
                AppStateStore.shared.storage.saveMediaLibraryAccounts(list)
                if !secret.isEmpty {
                    try? AppStateStore.shared.storage.setMediaLibrarySecret(secret, for: account)
                }
            }
            NotificationCenter.default.post(name: .marcoStateDidChange, object: AppStateStore.shared)
            self?.reloadAccounts()
        })
        present(alert, animated: true)
    }

    private func testConnection(site: CmsSite) {
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let home = try await AppStateStore.shared.cmsClient.fetchHome(site: site, storage: AppStateStore.shared.storage)
                self.showMessage(
                    title: "连接成功",
                    message: "检测到 \(home.categories.count) 个分区，\(home.listing.videos.count) 项媒体条目。"
                )
            } catch {
                self.showMessage(title: "连接失败", message: error.localizedDescription)
            }
        }
    }
}

// MARK: - 4. 播放与双内核

public final class PlaybackSettingsViewController: MarcoBaseSettingsTableController {
    public init() { super.init(pageTitle: "播放与双内核") }

    public override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "双解码内核与画质音效"
        case 1: return "播放行为与片头片尾"
        case 2: return "网络代理与广告过滤"
        default: return nil
        }
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 4
        case 1: return 4
        case 2: return 2
        default: return 0
        }
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let store = AppStateStore.shared
        let prefs = store.storage.preferences()

        switch indexPath.section {
        case 0:
            switch indexPath.row {
            case 0:
                let mpvHint = MarcoBuildCapabilities.hasMpv ? "" : "（仅 AVPlayer 可用）"
                return makeValueCell(title: "默认播放内核", detail: "\(prefs.iosEngineMode.shortLabel)\(mpvHint)", accessory: .disclosureIndicator)
            case 1:
                return makeValueCell(title: "HDR 色调映射", detail: prefs.hdrToneMapping.labelZh, accessory: .disclosureIndicator)
            case 2:
                return makeToggleCell(title: "Anime4K 轻量化超分", subtitle: "在 libmpv 模式下启用低功耗动漫锐化着色器", isOn: prefs.anime4kLightweight) { on in
                    store.storage.updatePreferences { $0.anime4kLightweight = on }
                }
            default:
                return makeValueCell(title: "人声增强预设", detail: prefs.vocalLoudness.labelZh, accessory: .disclosureIndicator)
            }

        case 1:
            switch indexPath.row {
            case 0:
                return makeToggleCell(title: "自动连播下一集", isOn: prefs.autoNext) { on in
                    store.storage.updatePreferences { $0.autoNext = on }
                }
            case 1:
                return makeValueCell(title: "默认播放倍速", detail: String(format: "%.2gx", prefs.playSpeed), accessory: .disclosureIndicator)
            case 2:
                return makeStepperCell(title: "默认跳过片头", valueSec: prefs.skipIntroSec) { [weak self] sec in
                    store.storage.updatePreferences { $0.skipIntroSec = sec }
                    self?.tableView.reloadData()
                }
            default:
                return makeStepperCell(title: "默认跳过片尾", valueSec: prefs.skipOutroSec) { [weak self] sec in
                    store.storage.updatePreferences { $0.skipOutroSec = sec }
                    self?.tableView.reloadData()
                }
            }

        default:
            if indexPath.row == 0 {
                return makeToggleCell(
                    title: "网盘 4K 并发分片缓冲代理",
                    subtitle: "启用本地 Range Proxy 以提升高码率网盘拖动与起播速度",
                    isOn: prefs.playerKernel == "range_proxy"
                ) { on in
                    store.storage.updatePreferences { $0.playerKernel = on ? "range_proxy" : "direct" }
                }
            }
            return makeToggleCell(
                title: "HLS 切片去广告过滤",
                subtitle: "自动剥离 M3U8 中混入的第三方插播广告切片",
                isOn: prefs.hlsAdStripEnabled
            ) { on in
                store.storage.updatePreferences { $0.hlsAdStripEnabled = on }
            }
        }
    }

    private func makeStepperCell(title: String, valueSec: Int, onChange: @escaping (Int) -> Void) -> UITableViewCell {
        let cell = makeValueCell(title: title, detail: "\(valueSec) 秒")
        cell.selectionStyle = .none
        let stepper = UIStepper()
        stepper.minimumValue = 0
        stepper.maximumValue = 300
        stepper.stepValue = 5
        stepper.value = Double(valueSec)
        stepper.addAction(UIAction { [weak stepper] _ in
            guard let stepper = stepper else { return }
            MarcoHaptics.light()
            onChange(Int(stepper.value))
        }, for: .valueChanged)
        cell.accessoryView = stepper
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let store = AppStateStore.shared
        if indexPath.section == 0 && indexPath.row == 0 {
            let sheet = UIAlertController(title: "选择默认播放内核", message: nil, preferredStyle: .actionSheet)
            sheet.popoverPresentationController?.sourceView = view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            for mode in IosPlaybackEngineMode.allCases {
                sheet.addAction(UIAlertAction(title: mode.labelZh, style: .default) { [weak self] _ in
                    store.storage.updatePreferences { $0.iosEngineMode = mode }
                    self?.tableView.reloadData()
                })
            }
            sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
            present(sheet, animated: true)
        } else if indexPath.section == 0 && indexPath.row == 1 {
            let sheet = UIAlertController(title: "HDR 色调映射算法", message: nil, preferredStyle: .actionSheet)
            sheet.popoverPresentationController?.sourceView = view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            for mode in IosHdrToneMappingMode.allCases {
                sheet.addAction(UIAlertAction(title: mode.labelZh, style: .default) { [weak self] _ in
                    store.storage.updatePreferences { $0.hdrToneMapping = mode }
                    self?.tableView.reloadData()
                })
            }
            sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
            present(sheet, animated: true)
        } else if indexPath.section == 0 && indexPath.row == 3 {
            let sheet = UIAlertController(title: "人声增强预设", message: nil, preferredStyle: .actionSheet)
            sheet.popoverPresentationController?.sourceView = view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            for preset in VocalLoudnessPreset.allCases {
                sheet.addAction(UIAlertAction(title: preset.labelZh, style: .default) { [weak self] _ in
                    store.storage.updatePreferences { $0.vocalLoudness = preset }
                    self?.tableView.reloadData()
                })
            }
            sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
            present(sheet, animated: true)
        } else if indexPath.section == 1 && indexPath.row == 1 {
            let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]
            let sheet = UIAlertController(title: "默认播放倍速", message: nil, preferredStyle: .actionSheet)
            sheet.popoverPresentationController?.sourceView = view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            for sp in speeds {
                sheet.addAction(UIAlertAction(title: String(format: "%.2gx", sp), style: .default) { [weak self] _ in
                    store.storage.updatePreferences { $0.playSpeed = sp }
                    self?.tableView.reloadData()
                })
            }
            sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
            present(sheet, animated: true)
        }
    }
}

// MARK: - 5. 弹幕设置

public final class DanmuSettingsViewController: MarcoBaseSettingsTableController {
    public init() { super.init(pageTitle: "弹幕设置") }

    public override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "弹弹服务器（不内置任何默认地址，请自行添加）"
        case 1: return "屏蔽关键词与正则（\(AppStateStore.shared.storage.danmuSettings().blockRules.count) 条）"
        case 2: return "弹幕显示参数"
        default: return nil
        }
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 3
        case 1: return 2
        case 2: return 5
        default: return 0
        }
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let store = AppStateStore.shared
        let ds = store.storage.danmuSettings()
        switch indexPath.section {
        case 0:
            if indexPath.row == 0 {
                return makeToggleCell(title: "启用弹幕渲染", isOn: ds.enabled) { on in
                    var next = store.storage.danmuSettings()
                    next.enabled = on
                    store.storage.saveDanmuSettings(next)
                }
            }
            if indexPath.row == 1 {
                let count = DanmuService.parseConfiguredOrigins(ds.serverUrls).count
                return makeValueCell(title: "自定义弹幕服务器", detail: count == 0 ? "未配置" : "\(count) 个来源", accessory: .disclosureIndicator)
            }
            return makeValueCell(title: "AppId / AppSecret（选填）", detail: ds.appId.isEmpty ? "未填写" : ds.appId, accessory: .disclosureIndicator)

        case 1:
            if indexPath.row == 0 {
                return makeValueCell(title: "添加关键词或 /正则/ 屏蔽规则", accessory: .disclosureIndicator)
            }
            let preview = ds.blockRules.isEmpty ? "暂无屏蔽规则" : ds.blockRules.prefix(4).joined(separator: "、")
            return makeSubtitleCell(title: "清空全部屏蔽规则", subtitle: preview)

        default:
            switch indexPath.row {
            case 0:
                return makeSliderCell(title: "不透明度", value: Float(ds.opacity), min: 0.2, max: 1.0, format: { "\(Int($0 * 100))%" }) { v in
                    var next = store.storage.danmuSettings()
                    next.opacity = Double(v)
                    store.storage.saveDanmuSettings(next)
                }
            case 1:
                return makeSliderCell(title: "字体大小", value: Float(ds.fontSize), min: 14, max: 30, format: { "\(Int($0)) pt" }) { v in
                    var next = store.storage.danmuSettings()
                    next.fontSize = Double(Int(v))
                    store.storage.saveDanmuSettings(next)
                }
            case 2:
                return makeSliderCell(title: "滚动速度", value: Float(ds.speedMultiplier), min: 0.6, max: 1.8, format: { String(format: "%.1fx", $0) }) { v in
                    var next = store.storage.danmuSettings()
                    next.speedMultiplier = Double(v)
                    store.storage.saveDanmuSettings(next)
                }
            case 3:
                return makeSliderCell(title: "显示区域", value: Float(ds.displayArea), min: 0.25, max: 1.0, format: { "\(Int($0 * 100))%" }) { v in
                    var next = store.storage.danmuSettings()
                    next.displayArea = Double(v)
                    store.storage.saveDanmuSettings(next)
                }
            default:
                return makeSliderCell(title: "最大同屏行数", value: Float(ds.maxRows), min: 4, max: 20, format: { "\(Int($0)) 行" }) { v in
                    var next = store.storage.danmuSettings()
                    next.maxRows = Int(v)
                    store.storage.saveDanmuSettings(next)
                }
            }
        }
    }

    private func makeSliderCell(
        title: String,
        value: Float,
        min: Float,
        max: Float,
        format: @escaping (Float) -> String,
        onChange: @escaping (Float) -> Void
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = MarcoColors.cardSurface
        cell.selectionStyle = .none

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = title
        label.font = MarcoTypography.cardTitle
        label.textColor = MarcoColors.primaryText

        let valLabel = UILabel()
        valLabel.translatesAutoresizingMaskIntoConstraints = false
        valLabel.text = format(value)
        valLabel.font = MarcoTypography.monospacedDigits(size: 13, weight: .medium)
        valLabel.textColor = MarcoColors.secondaryText

        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumValue = min
        slider.maximumValue = max
        slider.value = value
        slider.minimumTrackTintColor = MarcoColors.accentTint
        slider.addAction(UIAction { [weak slider, weak valLabel] _ in
            guard let slider = slider else { return }
            valLabel?.text = format(slider.value)
            onChange(slider.value)
        }, for: .valueChanged)

        cell.contentView.addSubview(label)
        cell.contentView.addSubview(valLabel)
        cell.contentView.addSubview(slider)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            valLabel.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            valLabel.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
            slider.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            slider.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            slider.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
            slider.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
        ])
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let store = AppStateStore.shared
        if indexPath.section == 0 && indexPath.row == 1 {
            let current = store.storage.danmuSettings().serverUrls
            let alert = UIAlertController(title: "配置弹幕服务器", message: "输入兼容 DandanPlay 协议的自有服务器地址（多个可用逗号或换行分隔）。", preferredStyle: .alert)
            alert.addTextField {
                $0.placeholder = "https:// 您的弹幕服务器地址"
                $0.text = current
                $0.keyboardType = .URL
                $0.autocapitalizationType = .none
            }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
                let raw = (alert?.textFields?.first?.text ?? "").replacingOccurrences(of: ",", with: "\n")
                var next = store.storage.danmuSettings()
                next.serverUrls = raw
                store.storage.saveDanmuSettings(next)
                let origins = DanmuService.parseConfiguredOrigins(raw).map { DanmuSourceEntry(url: $0) }
                let doc = DanmuSourceSyncDocument(
                    updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
                    revision: store.storage.danmuSyncDocument().revision + 1,
                    initialized: true,
                    sources: origins
                )
                store.storage.saveDanmuSyncDocuments(current: doc)
                self?.tableView.reloadData()
            })
            present(alert, animated: true)
        } else if indexPath.section == 0 && indexPath.row == 2 {
            let ds = store.storage.danmuSettings()
            let alert = UIAlertController(title: "弹幕鉴权信息（选填）", message: "仅当您的私有弹幕服务器需要签名鉴权时填写。", preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "AppId"; $0.text = ds.appId }
            alert.addTextField { $0.placeholder = "AppSecret（存入钥匙串）"; $0.text = ds.appSecret; $0.isSecureTextEntry = true }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
                var next = store.storage.danmuSettings()
                next.appId = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                next.appSecret = alert?.textFields?.last?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                store.storage.saveDanmuSettings(next)
                self?.tableView.reloadData()
            })
            present(alert, animated: true)
        } else if indexPath.section == 1 && indexPath.row == 0 {
            let alert = UIAlertController(title: "添加屏蔽规则", message: "输入关键词，或用 /正则/ 格式进行正则匹配。", preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "例如：剧透 或 /广告\\d+/" }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "添加", style: .default) { [weak self, weak alert] _ in
                let rule = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !rule.isEmpty else { return }
                var next = store.storage.danmuSettings()
                if !next.blockRules.contains(rule) { next.blockRules.append(rule) }
                store.storage.saveDanmuSettings(next)
                self?.tableView.reloadData()
            })
            present(alert, animated: true)
        } else if indexPath.section == 1 && indexPath.row == 1 {
            var next = store.storage.danmuSettings()
            next.blockRules.removeAll()
            store.storage.saveDanmuSettings(next)
            tableView.reloadData()
        }
    }
}

// MARK: - 6. 云同步与扫码快传（WebDAV + LanConfigServer + QR Bind）

public final class CloudSyncAndLanSettingsViewController: MarcoBaseSettingsTableController {
    private var activeLanBindUrl: String?
    private var activeLanWebUrl: String?
    private var syncStatusNote: String = ""

    public init() { super.init(pageTitle: "云同步与扫码快传") }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            AppStateStore.shared.lanServer.stop()
        }
    }

    public override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "WebDAV 跨端双向云同步"
        case 1: return "局域网扫码快传与接收码"
        case 2: return "本地备份与恢复"
        default: return nil
        }
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 4
        case 1: return activeLanBindUrl == nil ? 2 : 3
        case 2: return 2
        default: return 0
        }
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let store = AppStateStore.shared
        let cfg = store.storage.loadWebDavConfig()

        switch indexPath.section {
        case 0:
            switch indexPath.row {
            case 0:
                return makeValueCell(title: "WebDAV 地址与账号", detail: cfg.isConfigured ? cfg.url : "未配置", accessory: .disclosureIndicator)
            case 1:
                return makeToggleCell(title: "自动同步", isOn: cfg.autoSync) { on in
                    var next = store.storage.loadWebDavConfig()
                    next.autoSync = on
                    try? store.storage.saveWebDavConfig(next)
                }
            case 2:
                return makeToggleCell(title: "同步弹幕源清单（.danmu.json）", isOn: cfg.syncDanmu) { on in
                    var next = store.storage.loadWebDavConfig()
                    next.syncDanmu = on
                    try? store.storage.saveWebDavConfig(next)
                }
            default:
                let status = !syncStatusNote.isEmpty ? syncStatusNote : (cfg.lastSyncStatus.isEmpty ? "就绪" : cfg.lastSyncStatus)
                return makeSubtitleCell(title: "立即同步到 WebDAV", subtitle: status, accessory: .disclosureIndicator)
            }

        case 1:
            if indexPath.row == 0 {
                return makeSubtitleCell(
                    title: activeLanBindUrl == nil ? "启动局域网快传与接收码" : "刷新局域网接收码",
                    subtitle: activeLanWebUrl ?? "开启本机临时 HTTP 服务，支持电视/电脑扫码互传配置",
                    accessory: .disclosureIndicator
                )
            }
            if indexPath.row == 1 && activeLanBindUrl != nil, let qrPayload = activeLanBindUrl {
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                cell.backgroundColor = MarcoColors.cardSurface
                cell.selectionStyle = .none

                let qrImg = MarcoQrCodeGenerator.image(for: qrPayload, size: CGSize(width: 180, height: 180))
                let iv = UIImageView(image: qrImg)
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.contentMode = .scaleAspectFit
                iv.applyContinuousCorners(12)

                let hint = UILabel()
                hint.translatesAutoresizingMaskIntoConstraints = false
                hint.text = "使用另一台 Marco Movie 扫描此加密绑定码\n浏览器访问：\(activeLanWebUrl ?? "")"
                hint.font = MarcoTypography.caption
                hint.textColor = MarcoColors.secondaryText
                hint.textAlignment = .center
                hint.numberOfLines = 0

                cell.contentView.addSubview(iv)
                cell.contentView.addSubview(hint)
                NSLayoutConstraint.activate([
                    iv.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 16),
                    iv.centerXAnchor.constraint(equalTo: cell.contentView.centerXAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 176),
                    iv.heightAnchor.constraint(equalToConstant: 176),

                    hint.topAnchor.constraint(equalTo: iv.bottomAnchor, constant: 10),
                    hint.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
                    hint.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                    hint.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -14),
                ])
                return cell
            }
            return makeSubtitleCell(
                title: "扫描电视 / 电脑端绑定二维码",
                subtitle: "调用原生相机扫码绑定 WebDAV 或接收配置",
                accessory: .disclosureIndicator
            )

        default:
            if indexPath.row == 0 {
                return makeValueCell(title: "导出公开备份 JSON 到剪贴板", accessory: .disclosureIndicator)
            }
            return makeValueCell(title: "从剪贴板恢复备份 JSON", accessory: .disclosureIndicator)
        }
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.section {
        case 0 where indexPath.row == 0:
            promptWebDavConfig()
        case 0 where indexPath.row == 3:
            runSyncNow()
        case 1 where indexPath.row == 0:
            startLanTransferServer()
        case 1:
            if (activeLanBindUrl == nil && indexPath.row == 1) || (activeLanBindUrl != nil && indexPath.row == 2) {
                openQrBinder()
            }
        case 2 where indexPath.row == 0:
            do {
                let json = try AppStateStore.shared.storage.exportBackupJson()
                UIPasteboard.general.string = json
                showMessage(title: "已导出", message: "公开备份（自动剥离隐私数据）已复制到剪贴板。")
            } catch {
                showMessage(title: "导出失败", message: error.localizedDescription)
            }
        case 2 where indexPath.row == 1:
            let raw = UIPasteboard.general.string ?? ""
            do {
                _ = try AppStateStore.shared.storage.importBackupJson(raw)
                AppStateStore.shared.reloadConfig()
                showMessage(title: "恢复成功", message: "已从剪贴板恢复订阅、收藏与历史记录。")
            } catch {
                showMessage(title: "恢复失败", message: error.localizedDescription)
            }
        default:
            break
        }
    }

    private func promptWebDavConfig() {
        let cfg = AppStateStore.shared.storage.loadWebDavConfig()
        let alert = UIAlertController(title: "WebDAV 配置", message: "密码存入 Apple Keychain，不以明文落盘。", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "https:// WebDAV 地址"; $0.text = cfg.url; $0.keyboardType = .URL; $0.autocapitalizationType = .none }
        alert.addTextField { $0.placeholder = "用户名"; $0.text = cfg.username; $0.autocapitalizationType = .none }
        alert.addTextField { $0.placeholder = "应用密码"; $0.text = cfg.password; $0.isSecureTextEntry = true }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let fields = alert?.textFields, fields.count == 3 else { return }
            var next = cfg
            next.url = fields[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            next.username = fields[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            next.password = fields[2].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? AppStateStore.shared.storage.saveWebDavConfig(next)
            self?.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func runSyncNow() {
        syncStatusNote = "正在与 WebDAV 双向合并同步…"
        tableView.reloadData()
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let summary = try await AppStateStore.shared.webDavSync.syncNow()
                AppStateStore.shared.reloadConfig()
                self.syncStatusNote = "同步完成：\(summary.subscriptionCount) 订阅 / \(summary.favoriteCount) 收藏 / \(summary.historyCount) 历史"
                self.tableView.reloadData()
            } catch {
                self.syncStatusNote = "同步失败：\(error.localizedDescription)"
                self.tableView.reloadData()
            }
        }
    }

    private func startLanTransferServer() {
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let server = AppStateStore.shared.freshLanServer()
                _ = try await server.start(loopbackOnly: false)
                let host = LanConfigServer.discoverLanAddresses().first ?? "127.0.0.1"
                self.activeLanWebUrl = server.configureUrl(forHost: host)
                self.activeLanBindUrl = server.bindQrUrl(forHost: host)
                self.tableView.reloadData()
            } catch {
                self.showMessage(title: "启动失败", message: error.localizedDescription)
            }
        }
    }

    private func openQrBinder() {
        QrScannerViewController.present(
            from: self,
            title: "扫码绑定 WebDAV",
            subtitle: "对准电视或电脑端接收码二维码自动绑定"
        ) { [weak self] raw in
            guard let self = self, let raw = raw, !raw.isEmpty else { return }
            if let parsed = WebdavBindCrypto.parseBindQrInput(raw) {
                self.showMessage(title: "已识别加密绑定目标", message: "对端接收地址：\(parsed.baseEndpointUrl)")
            } else if let url = URL(string: raw), let msg = AppStateStore.shared.handleDeepLink(url) {
                self.showMessage(title: "绑定完成", message: msg)
                self.tableView.reloadData()
            } else {
                self.showMessage(title: "已读取二维码", message: raw)
            }
        }
    }
}

// MARK: - 7. AI 观影实验室

public final class AiLabSettingsViewController: MarcoBaseSettingsTableController {
    public init() { super.init(pageTitle: "AI 观影实验室") }

    public override func numberOfSections(in tableView: UITableView) -> Int { 4 }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "实验室通行证（Ed25519 离线签名校验）与隐私熔断"
        case 1: return "模型服务商与密钥（共 \(AiService.presets.count) 组预设）"
        case 2: return "AI 观影能力开关"
        case 3: return "本月用量统计"
        default: return nil
        }
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 2
        case 1: return 4
        case 2: return 4
        case 3: return 1
        default: return 0
        }
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let store = AppStateStore.shared
        let cfg = store.storage.aiConfig()

        switch indexPath.section {
        case 0:
            if indexPath.row == 0 {
                let unlocked = store.isAiLabUnlocked
                let sub = unlocked
                    ? "已解锁（\(store.cachedAiLabClaims?.subject ?? "AI Lab")）· 点击清除或更换"
                    : "输入 MMAILAB1 离线 Ed25519 口令以解锁全部实验特性"
                return makeSubtitleCell(
                    title: unlocked ? "AI 实验室已解锁" : "输入 Ed25519 口令解锁",
                    subtitle: sub,
                    accessory: .disclosureIndicator
                )
            }
            let cell = makeSubtitleCell(
                title: "隐私空间安全硬熔断",
                subtitle: store.isPrivacySpaceUnlocked
                    ? "当前处于隐私空间：所有外部 AI 请求已被强制拦截"
                    : "已启用：进入隐私空间后自动切断全部 AI 联网请求"
            )
            cell.selectionStyle = .none
            return cell

        case 1:
            switch indexPath.row {
            case 0:
                let currentName = AiService.presets.first(where: { $0.defaultBaseUrl == cfg.baseUrl && !$0.defaultBaseUrl.isEmpty })?.name ?? "自定义 / 选择预设"
                return makeValueCell(title: "服务商预设（13 家）", detail: currentName, accessory: .disclosureIndicator)
            case 1:
                let hasKey = !store.storage.aiSecret().isEmpty
                return makeValueCell(title: "API Key（Keychain）", detail: hasKey ? "已配置" : "未填写", accessory: .disclosureIndicator)
            case 2:
                return makeValueCell(title: "主模型 / 接口地址", detail: cfg.model.isEmpty ? "未配置" : cfg.model, accessory: .disclosureIndicator)
            default:
                return makeValueCell(title: "轻量快模型（fastModel）", detail: cfg.fastModel.isEmpty ? "跟随主模型" : cfg.fastModel, accessory: .disclosureIndicator)
            }

        case 2:
            switch indexPath.row {
            case 0:
                return makeToggleCell(title: "启用 AI 观影能力", isOn: cfg.enabled) { on in
                    var next = store.storage.aiConfig()
                    next.enabled = on
                    store.storage.saveAiConfig(next)
                }
            case 1:
                return makeToggleCell(title: "AI 自然语言语义找片", isOn: cfg.nlSearchEnabled) { on in
                    var next = store.storage.aiConfig()
                    next.nlSearchEnabled = on
                    store.storage.saveAiConfig(next)
                }
            case 2:
                return makeToggleCell(title: "智能弹幕剧集匹配", isOn: cfg.danmuMatchEnabled) { on in
                    var next = store.storage.aiConfig()
                    next.danmuMatchEnabled = on
                    store.storage.saveAiConfig(next)
                }
            default:
                return makeToggleCell(title: "无剧透观影导览", isOn: cfg.spoilerFreeRecapEnabled) { on in
                    var next = store.storage.aiConfig()
                    next.spoilerFreeRecapEnabled = on
                    store.storage.saveAiConfig(next)
                }
            }

        default:
            let usage = store.storage.aiUsage()
            let c = makeValueCell(
                title: "累计消耗 Tokens",
                detail: "\(usage.totalTokens)（\(usage.requestCount) 次请求）"
            )
            c.selectionStyle = .none
            return c
        }
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let store = AppStateStore.shared
        if indexPath.section == 0 && indexPath.row == 0 {
            promptPasscodeUnlock()
        } else if indexPath.section == 1 && indexPath.row == 0 {
            presentPresetPicker()
        } else if indexPath.section == 1 && indexPath.row == 1 {
            promptApiKey()
        } else if indexPath.section == 1 && (indexPath.row == 2 || indexPath.row == 3) {
            promptModelEndpoints(store: store)
        }
    }

    private func promptPasscodeUnlock() {
        let store = AppStateStore.shared
        let alert = UIAlertController(
            title: "Ed25519 AI 实验室口令",
            message: "粘贴 MMAILAB1.<payload>.<signature> 口令进行离线验签。",
            preferredStyle: .alert
        )
        alert.addTextField { $0.placeholder = "MMAILAB1..." }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if store.isAiLabUnlocked {
            alert.addAction(UIAlertAction(title: "清除口令", style: .destructive) { [weak self] _ in
                store.clearAiLabPasscode()
                self?.tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: "验签解锁", style: .default) { [weak self, weak alert] _ in
            let token = alert?.textFields?.first?.text ?? ""
            switch store.unlockAiLab(passcode: token) {
            case .success(let claims):
                self?.tableView.reloadData()
                self?.showMessage(title: "解锁成功", message: "欢迎使用 AI 观影实验室（\(claims.subject)）。")
            case .failure(let err):
                self?.showMessage(title: "验签失败", message: err.localizedDescription)
            }
        })
        present(alert, animated: true)
    }

    private func presentPresetPicker() {
        let sheet = UIAlertController(title: "选择 AI 模型预设", message: nil, preferredStyle: .actionSheet)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        for preset in AiService.presets {
            sheet.addAction(UIAlertAction(title: preset.name, style: .default) { [weak self] _ in
                var cfg = AppStateStore.shared.storage.aiConfig()
                cfg.protocolType = preset.protocolType
                cfg.authMode = preset.authMode
                if !preset.defaultBaseUrl.isEmpty { cfg.baseUrl = preset.defaultBaseUrl }
                if !preset.defaultModel.isEmpty { cfg.model = preset.defaultModel }
                cfg.fastModel = preset.defaultFastModel
                AppStateStore.shared.storage.saveAiConfig(cfg)
                self?.tableView.reloadData()
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }

    private func promptApiKey() {
        let alert = UIAlertController(title: "配置 API Key", message: "密钥加密存储于系统 Keychain，不随 WebDAV 导出。", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "输入 API Key"; $0.isSecureTextEntry = true }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            let key = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? AppStateStore.shared.storage.setAiSecret(key)
            self?.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func promptModelEndpoints(store: AppStateStore) {
        let cfg = store.storage.aiConfig()
        let alert = UIAlertController(title: "接口与模型配置", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Base URL"; $0.text = cfg.baseUrl; $0.keyboardType = .URL; $0.autocapitalizationType = .none }
        alert.addTextField { $0.placeholder = "主模型名称"; $0.text = cfg.model; $0.autocapitalizationType = .none }
        alert.addTextField { $0.placeholder = "快速模型（选填）"; $0.text = cfg.fastModel; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let f = alert?.textFields, f.count == 3 else { return }
            var next = cfg
            next.baseUrl = f[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            next.model = f[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            next.fastModel = f[2].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            store.storage.saveAiConfig(next)
            self?.tableView.reloadData()
        })
        present(alert, animated: true)
    }
}

// MARK: - 8. 外观与主题

public final class AppearanceSettingsViewController: MarcoBaseSettingsTableController {
    private var cacheSizeText = "计算中…"

    public init() { super.init(pageTitle: "外观与主题") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        refreshCacheSize()
    }

    private func refreshCacheSize() {
        PosterImageLoader.shared.diskCacheByteCount { [weak self] bytes in
            self?.cacheSizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            self?.tableView.reloadData()
        }
    }

    public override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "深浅外观模式"
        case 1: return "首页视觉与环境光效"
        case 2: return "缓存清理"
        default: return nil
        }
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 3
        case 1: return 4
        case 2: return 1
        default: return 0
        }
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let store = AppStateStore.shared
        let prefs = store.storage.preferences()

        if indexPath.section == 0 {
            let modes: [(AppThemeMode, String)] = [
                (.system, "跟随系统"),
                (.light, "浅色外观（纯白卡片）"),
                (.dark, "深色影院（曜石黑）"),
            ]
            let entry = modes[indexPath.row]
            return makeValueCell(title: entry.1, accessory: prefs.appThemeMode == entry.0 ? .checkmark : .none)
        }
        if indexPath.section == 1 {
            switch indexPath.row {
            case 0:
                return makeToggleCell(title: "封面环境光晕（Ambient Mesh Glow）", isOn: prefs.ambientGlowEnabled) { on in
                    store.storage.updatePreferences { $0.ambientGlowEnabled = on }
                    NotificationCenter.default.post(name: .marcoStateDidChange, object: store)
                }
            case 1:
                return makeToggleCell(title: "首页影院大焦点海报", isOn: prefs.showHeroBanner) { on in
                    store.storage.updatePreferences { $0.showHeroBanner = on }
                    NotificationCenter.default.post(name: .marcoStateDidChange, object: store)
                }
            case 2:
                return makeToggleCell(title: "首页继续观看货架", isOn: prefs.showContinueWatching) { on in
                    store.storage.updatePreferences { $0.showContinueWatching = on }
                    NotificationCenter.default.post(name: .marcoStateDidChange, object: store)
                }
            default:
                return makeToggleCell(title: "首页精选发现货架", isOn: prefs.showCuratedDiscovery) { on in
                    store.storage.updatePreferences { $0.showCuratedDiscovery = on }
                    NotificationCenter.default.post(name: .marcoStateDidChange, object: store)
                }
            }
        }
        return makeValueCell(title: "清理海报与广告拦截缓存", detail: cacheSizeText, accessory: .disclosureIndicator)
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let modes: [AppThemeMode] = [.system, .light, .dark]
            AppStateStore.shared.applyThemeMode(modes[indexPath.row], animated: true)
            tableView.reloadData()
        } else if indexPath.section == 2 {
            PosterImageLoader.shared.clearAllCaches { [weak self] in
                HeadlessMediaWebSniffer.clearAdBlockCache {
                    self?.refreshCacheSize()
                    self?.showMessage(title: "已清理", message: "海报磁盘缓存与广告拦截规则缓存已清空。")
                }
            }
        }
    }
}

// MARK: - 9. 隐私空间

public final class PrivacySpaceSettingsViewController: MarcoBaseSettingsTableController {
    public init() { super.init(pageTitle: "隐私空间") }

    public override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "身份锁与生物识别" : "隐私空间隔离机制说明"
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 3 : 1
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let store = AppStateStore.shared
        if indexPath.section == 0 {
            switch indexPath.row {
            case 0:
                let title = store.isPrivacySpaceUnlocked ? "立即锁定隐私空间" : "解锁进入隐私空间"
                let detail = store.isPrivacySpaceUnlocked ? "当前已解锁" : "当前已锁定"
                let cell = makeValueCell(title: title, detail: detail, accessory: .disclosureIndicator)
                cell.detailTextLabel?.textColor = store.isPrivacySpaceUnlocked ? MarcoColors.ratingGold : MarcoColors.secondaryText
                return cell
            case 1:
                let hasPin = store.storage.hasPrivacyPin()
                return makeValueCell(
                    title: hasPin ? "修改 PBKDF2 PIN 密码" : "设置 PBKDF2 PIN 密码",
                    detail: hasPin ? "已设置" : "未设置",
                    accessory: .disclosureIndicator
                )
            default:
                let bio = BiometricPrivacyAuth.availableBiometry()
                return makeToggleCell(
                    title: "使用 \(bio.displayName) 快速解锁",
                    subtitle: bio == .none ? "当前设备未启用生物识别" : "验证 PIN 时自动触发 \(bio.displayName)",
                    isOn: store.isBiometricUnlockEnabled && bio != .none
                ) { on in
                    store.isBiometricUnlockEnabled = on
                }
            }
        }
        let cell = makeSubtitleCell(
            title: "五连击品牌 Logo 隐蔽切换",
            subtitle: "在首页左上角连续点击 5 次 Marco Movie 标志（2.5 秒内）即可唤起隐私空间验证；锁定后立即清空内存海报缓存并自动与 WebDAV 云端隔离。"
        )
        cell.selectionStyle = .none
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0 else { return }
        let store = AppStateStore.shared
        if indexPath.row == 0 {
            if store.isPrivacySpaceUnlocked {
                store.lockPrivacySpace()
                tableView.reloadData()
            } else {
                store.promptUnlockPrivacySpace(from: self) { [weak self] _ in
                    self?.tableView.reloadData()
                }
            }
        } else if indexPath.row == 1 {
            PrivacyPinViewController.present(
                from: self,
                mode: .setup,
                pinLength: 4,
                allowsBiometrics: false,
                autoPromptBiometrics: false
            ) { [weak self] result in
                if case .created(let pin) = result {
                    try? store.storage.setPrivacyPin(pin)
                    self?.tableView.reloadData()
                    self?.showMessage(title: "PIN 已更新", message: "隐私密码已采用 PBKDF2-SHA256 加密存入 Keychain。")
                }
            }
        }
    }
}

// MARK: - 10. 检查更新与关于

public final class AboutAndUpdateSettingsViewController: MarcoBaseSettingsTableController {
    private var updateStatusText = "点击检查 GitHub Releases 最新版本"

    public init() { super.init(pageTitle: "检查更新与关于") }

    private var currentVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.8.0"
    }

    private var currentBuildNumber: Int {
        if let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String, let n = Int(raw) {
            return n
        }
        return 107
    }

    public override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "应用版本与更新通道"
        case 1: return "旧版 Flutter 数据无损迁移摘要"
        case 2: return "工具声明与开源许可"
        default: return nil
        }
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 2
        case 1: return 1
        case 2: return 1
        default: return 0
        }
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0:
            if indexPath.row == 0 {
                let c = makeValueCell(
                    title: "Marco Movie iOS / iPadOS 原生版",
                    detail: "v\(currentVersionString) (\(currentBuildNumber))"
                )
                c.selectionStyle = .none
                return c
            }
            return makeSubtitleCell(title: "检查版本更新", subtitle: updateStatusText, accessory: .disclosureIndicator)

        case 1:
            let report = AppStateStore.shared.lastMigrationReport
            let summary: String
            if let r = report, r.performed {
                summary = "已自动迁移：\(r.subscriptionsMigrated) 订阅 · \(r.watchHistoryMigrated) 历史 · \(r.favoritesMigrated) 收藏 · \(r.credentialsMigrated) 密钥凭证 · \(r.downloadsMigrated) 离线记录"
            } else {
                summary = "已完成首次启动检测，老版本订阅、收藏、网盘及 WebDAV 凭证均无缝保留。"
            }
            let c = makeSubtitleCell(title: "覆盖升级无损迁移引擎", subtitle: summary)
            c.selectionStyle = .none
            return c

        default:
            let c = makeSubtitleCell(
                title: "免责与合规工具声明（GPL-3.0）",
                subtitle: "本应用为纯原生 UIKit 本地播放器与媒体库客户端，不内置、不提供、不托管任何影视内容或片源。"
            )
            c.selectionStyle = .none
            return c
        }
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0 && indexPath.row == 1 else { return }
        checkUpdatesNow()
    }

    private func checkUpdatesNow() {
        updateStatusText = "正在查询 updates/ios.json…"
        tableView.reloadData()
        let ver = currentVersionString
        let build = currentBuildNumber
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let outcome = try await AppStateStore.shared.appUpdateService.checkForUpdate(
                    currentVersion: ver,
                    currentBuild: build
                )
                switch outcome.relation {
                case .updateAvailable:
                    self.updateStatusText = "发现新版本 v\(outcome.release.version) (\(outcome.release.buildNumber))"
                    self.tableView.reloadData()
                    self.presentUpdatePrompt(outcome.release)
                case .upToDate, .aheadOfChannel:
                    self.updateStatusText = "当前已是最新版本 v\(ver) (\(build))"
                    self.tableView.reloadData()
                }
            } catch {
                self.updateStatusText = "检查失败：\(error.localizedDescription)"
                self.tableView.reloadData()
            }
        }
    }

    private func presentUpdatePrompt(_ release: AppUpdateRelease) {
        let alert = UIAlertController(
            title: "发现新版本 v\(release.version)",
            message: release.releaseNotes.isEmpty ? "包含最新性能优化与功能修复。" : release.releaseNotes,
            preferredStyle: .alert
        )
        if !release.downloadUrl.isEmpty,
           let encoded = release.downloadUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let trollUrl = URL(string: "apple-magnifier://install?url=\(encoded)"),
           UIApplication.shared.canOpenURL(trollUrl)
        {
            alert.addAction(UIAlertAction(title: "通过 TrollStore 安装", style: .default) { _ in
                UIApplication.shared.open(trollUrl)
            })
        }
        if let directUrl = URL(string: release.downloadUrl) {
            alert.addAction(UIAlertAction(title: "浏览器下载 IPA", style: .default) { _ in
                UIApplication.shared.open(directUrl)
            })
        }
        alert.addAction(UIAlertAction(title: "稍后", style: .cancel))
        present(alert, animated: true)
    }
}
