// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — True iPadOS Master-Detail Two-Column Settings & Adaptive iPhone Settings List

import MarcoIOSCore
import UIKit

// MARK: - Settings Categories

public enum SettingsCategory: Int, CaseIterable, Hashable, Sendable {
    case sources = 0
    case netdisk = 1
    case mediaLibrary = 2
    case playback = 3
    case danmu = 4
    case cloudSync = 5
    case aiLab = 6
    case appearance = 7
    case privacy = 8
    case about = 9

    public var title: String {
        switch self {
        case .sources: return "片源与订阅管理"
        case .netdisk: return "网盘账号（五大网盘）"
        case .mediaLibrary: return "媒体库与局域网"
        case .playback: return "播放与双内核"
        case .danmu: return "弹幕设置"
        case .cloudSync: return "云同步与扫码快传"
        case .aiLab: return "AI 观影实验室"
        case .appearance: return "外观与主题"
        case .privacy: return "隐私空间"
        case .about: return "检查更新与关于"
        }
    }

    public var subtitle: String {
        switch self {
        case .sources: return "订阅源、多仓切换、蜘蛛网关与运行时"
        case .netdisk: return "夸克 / UC / 百度 / 阿里 / 115"
        case .mediaLibrary: return "Emby / Jellyfin / Plex / WebDAV / SMB"
        case .playback: return "AVPlayer / libmpv、HDR、人声与跳过片头"
        case .danmu: return "自定义弹弹服务器、屏蔽词与排版"
        case .cloudSync: return "WebDAV 双向同步与局域网二维码快传"
        case .aiLab: return "Ed25519 口令解锁、13 家模型预设"
        case .appearance: return "深浅外观、环境光晕与缓存管理"
        case .privacy: return "PBKDF2 PIN、面容 ID 与五连击入口"
        case .about: return "版本 0.8.0 (107)、更新与数据迁移"
        }
    }

    public var symbolName: String {
        switch self {
        case .sources: return "globe"
        case .netdisk: return "externaldrive.fill.badge.icloud"
        case .mediaLibrary: return "server.rack"
        case .playback: return "play.tv.fill"
        case .danmu: return "captions.bubble.fill"
        case .cloudSync: return "arrow.triangle.2.circlepath.icloud.fill"
        case .aiLab: return "sparkles"
        case .appearance: return "paintbrush.fill"
        case .privacy: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }

    public var badgeColor: UIColor {
        switch self {
        case .sources: return UIColor(red: 0.04, green: 0.48, blue: 0.92, alpha: 1.0)
        case .netdisk: return UIColor(red: 0.14, green: 0.56, blue: 0.86, alpha: 1.0)
        case .mediaLibrary: return UIColor(red: 0.34, green: 0.38, blue: 0.82, alpha: 1.0)
        case .playback: return UIColor(red: 0.84, green: 0.28, blue: 0.36, alpha: 1.0)
        case .danmu: return UIColor(red: 0.90, green: 0.52, blue: 0.14, alpha: 1.0)
        case .cloudSync: return UIColor(red: 0.15, green: 0.64, blue: 0.46, alpha: 1.0)
        case .aiLab: return UIColor(red: 0.54, green: 0.34, blue: 0.86, alpha: 1.0)
        case .appearance: return UIColor(red: 0.22, green: 0.50, blue: 0.88, alpha: 1.0)
        case .privacy: return UIColor(red: 0.28, green: 0.32, blue: 0.40, alpha: 1.0)
        case .about: return UIColor(red: 0.44, green: 0.48, blue: 0.54, alpha: 1.0)
        }
    }

    public static let groupedSections: [(title: String, items: [SettingsCategory])] = [
        ("内容与媒体源", [.sources, .netdisk, .mediaLibrary]),
        ("播放、同步与实验室", [.playback, .danmu, .cloudSync, .aiLab]),
        ("外观、隐私与关于", [.appearance, .privacy, .about]),
    ]
}

// MARK: - Apple Settings Category Row Cell

private final class SettingsCategoryCell: UITableViewCell {
    static let reuseIdentifier = "SettingsCategoryCell"

    private let iconBadge = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = MarcoColors.cardSurface

        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.applyContinuousCorners(8)
        contentView.addSubview(iconBadge)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconBadge.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MarcoTypography.cardTitle
        titleLabel.textColor = MarcoColors.primaryText
        contentView.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = MarcoTypography.caption
        subtitleLabel.textColor = MarcoColors.secondaryText
        subtitleLabel.numberOfLines = 1
        contentView.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconBadge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            iconBadge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: 30),
            iconBadge.heightAnchor.constraint(equalToConstant: 30),

            iconView.centerXAnchor.constraint(equalTo: iconBadge.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBadge.centerYAnchor),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 9),
            titleLabel.leadingAnchor.constraint(equalTo: iconBadge.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -9),
        ])
    }

    func configure(category: SettingsCategory, isRegularMaster: Bool, isSelectedCategory: Bool) {
        iconBadge.backgroundColor = category.badgeColor
        iconView.image = MarcoSymbols.image(
            category.symbolName,
            pointSize: 15,
            weight: .semibold,
            hierarchicalColor: .white
        )
        titleLabel.text = category.title
        subtitleLabel.text = category.subtitle
        accessoryType = isRegularMaster ? .none : .disclosureIndicator

        if isRegularMaster && isSelectedCategory {
            backgroundColor = MarcoColors.accentTint.withAlphaComponent(0.14)
            titleLabel.textColor = MarcoColors.accentTint
        } else {
            backgroundColor = MarcoColors.cardSurface
            titleLabel.textColor = MarcoColors.primaryText
        }
    }
}

// MARK: - True iPadOS Master-Detail Split Settings View Controller

/// Authentic iPadOS System Settings experience:
/// - **iPad (`horizontalSizeClass == .regular`)**: Permanent left category list (`310pt`) + hairline divider
///   + right detail pane switching **in-place immediately** (never full-screen push).
/// - **iPhone (`horizontalSizeClass == .compact`)**: Clean `.insetGrouped` list pushing each detail controller.
public final class SettingsSplitViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let masterTableView = UITableView(frame: .zero, style: .insetGrouped)
    private let masterHeaderLabel = UILabel()
    private let verticalDivider = UIView()
    private let detailContainerView = UIView()
    private let detailNavController = UINavigationController()

    private var selectedCategory: SettingsCategory = .sources
    private var compactConstraints: [NSLayoutConstraint] = []
    private var regularConstraints: [NSLayoutConstraint] = []
    private var masterWidthConstraint: NSLayoutConstraint?
    private var isRegularSplitActive: Bool?

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        navigationItem.largeTitleDisplayMode = .automatic
        view.backgroundColor = MarcoColors.canvasBackground

        setupViews()
        applyLayoutMode(for: traitCollection)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isRegularSplitActive == true else { return }
        let w = view.bounds.width
        guard w > 0 else { return }
        let targetMaster: CGFloat = w >= 760 ? 292 : max(200, min(228, floor(w * 0.36)))
        if masterWidthConstraint?.constant != targetMaster {
            masterWidthConstraint?.constant = targetMaster
        }
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass {
            applyLayoutMode(for: traitCollection)
        }
    }

    public override func willTransition(
        to newCollection: UITraitCollection,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.willTransition(to: newCollection, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.applyLayoutMode(for: newCollection)
        }
    }

    private func setupViews() {
        masterHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        masterHeaderLabel.text = "设置"
        masterHeaderLabel.font = MarcoTypography.largeTitle
        masterHeaderLabel.textColor = MarcoColors.primaryText
        view.addSubview(masterHeaderLabel)

        masterTableView.translatesAutoresizingMaskIntoConstraints = false
        masterTableView.backgroundColor = MarcoColors.canvasBackground
        masterTableView.dataSource = self
        masterTableView.delegate = self
        masterTableView.register(SettingsCategoryCell.self, forCellReuseIdentifier: SettingsCategoryCell.reuseIdentifier)
        view.addSubview(masterTableView)

        verticalDivider.translatesAutoresizingMaskIntoConstraints = false
        verticalDivider.backgroundColor = MarcoColors.separator
        view.addSubview(verticalDivider)

        detailContainerView.translatesAutoresizingMaskIntoConstraints = false
        detailContainerView.backgroundColor = MarcoColors.canvasBackground
        view.addSubview(detailContainerView)

        addChild(detailNavController)
        detailNavController.view.translatesAutoresizingMaskIntoConstraints = false
        detailNavController.navigationBar.prefersLargeTitles = false
        detailNavController.navigationBar.tintColor = MarcoColors.accentTint
        detailContainerView.addSubview(detailNavController.view)
        NSLayoutConstraint.activate([
            detailNavController.view.topAnchor.constraint(equalTo: detailContainerView.topAnchor),
            detailNavController.view.leadingAnchor.constraint(equalTo: detailContainerView.leadingAnchor),
            detailNavController.view.trailingAnchor.constraint(equalTo: detailContainerView.trailingAnchor),
            detailNavController.view.bottomAnchor.constraint(equalTo: detailContainerView.bottomAnchor),
        ])
        detailNavController.didMove(toParent: self)

        let guide = view.safeAreaLayoutGuide
        let pixelW = 1.0 / max(UIScreen.main.scale, 1.0)

        compactConstraints = [
            masterTableView.topAnchor.constraint(equalTo: view.topAnchor),
            masterTableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            masterTableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            masterTableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]

        let masterWidth = masterTableView.widthAnchor.constraint(equalToConstant: 292)
        masterWidthConstraint = masterWidth

        regularConstraints = [
            masterHeaderLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            masterHeaderLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            masterHeaderLabel.trailingAnchor.constraint(equalTo: masterTableView.trailingAnchor, constant: -16),

            masterTableView.topAnchor.constraint(equalTo: guide.topAnchor),
            masterTableView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            masterWidth,
            masterTableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            verticalDivider.topAnchor.constraint(equalTo: guide.topAnchor),
            verticalDivider.leadingAnchor.constraint(equalTo: masterTableView.trailingAnchor),
            verticalDivider.widthAnchor.constraint(equalToConstant: pixelW),
            verticalDivider.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            detailContainerView.topAnchor.constraint(equalTo: guide.topAnchor),
            detailContainerView.leadingAnchor.constraint(equalTo: verticalDivider.trailingAnchor),
            detailContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detailContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
    }

    private func applyLayoutMode(for traits: UITraitCollection) {
        let isRegular = traits.horizontalSizeClass == .regular
        guard isRegular != isRegularSplitActive else { return }
        isRegularSplitActive = isRegular

        NSLayoutConstraint.deactivate(isRegular ? compactConstraints : regularConstraints)
        NSLayoutConstraint.activate(isRegular ? regularConstraints : compactConstraints)

        // When hosted inside secondaryNavController, the nav bar already displays "设置" + sidebar toggle.
        masterHeaderLabel.isHidden = true
        verticalDivider.isHidden = !isRegular
        detailContainerView.isHidden = !isRegular

        if isRegular {
            showDetailInPlace(for: selectedCategory)
            view.setNeedsLayout()
        }
        masterTableView.reloadData()
    }

    public func selectCategory(_ category: SettingsCategory) {
        selectedCategory = category
        if isRegularSplitActive == true {
            showDetailInPlace(for: category)
            masterTableView.reloadData()
        } else {
            let detail = makeDetailController(for: category)
            navigationController?.pushViewController(detail, animated: true)
        }
    }

    private func showDetailInPlace(for category: SettingsCategory) {
        let detail = makeDetailController(for: category)
        detailNavController.setViewControllers([detail], animated: false)
    }

    private func makeDetailController(for category: SettingsCategory) -> UIViewController {
        switch category {
        case .sources: return SourcesSettingsViewController()
        case .netdisk: return NetdiskAccountsSettingsViewController()
        case .mediaLibrary: return MediaLibrarySettingsViewController()
        case .playback: return PlaybackSettingsViewController()
        case .danmu: return DanmuSettingsViewController()
        case .cloudSync: return CloudSyncAndLanSettingsViewController()
        case .aiLab: return AiLabSettingsViewController()
        case .appearance: return AppearanceSettingsViewController()
        case .privacy: return PrivacySpaceSettingsViewController()
        case .about: return AboutAndUpdateSettingsViewController()
        }
    }

    // MARK: - UITableViewDataSource & Delegate

    public func numberOfSections(in tableView: UITableView) -> Int {
        SettingsCategory.groupedSections.count
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        SettingsCategory.groupedSections[section].title
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        SettingsCategory.groupedSections[section].items.count
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: SettingsCategoryCell.reuseIdentifier,
            for: indexPath
        ) as! SettingsCategoryCell
        let category = SettingsCategory.groupedSections[indexPath.section].items[indexPath.row]
        cell.configure(
            category: category,
            isRegularMaster: isRegularSplitActive == true,
            isSelectedCategory: category == selectedCategory
        )
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        MarcoHaptics.selection()
        let category = SettingsCategory.groupedSections[indexPath.section].items[indexPath.row]
        selectCategory(category)
    }
}
