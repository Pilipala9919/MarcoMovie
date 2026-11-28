// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Live TV (iPad Left Group Tree + Multi-Column Logo/EPG Grid + Mini PiP Bar & Width-Bounded Controls)

import MarcoIOSCore
import UIKit

// MARK: - Channel Logo / EPG Card Cell

private final class LiveChannelCardCell: UICollectionViewCell, UIPointerInteractionDelegate {
    static let reuseIdentifier = "LiveChannelCardCell"

    private let card = UIView()
    private let crestView = UIView()
    private let crestImageView = UIImageView()
    private let crestInitialLabel = UILabel()
    private let nameLabel = UILabel()
    private let epgLabel = UILabel()
    private let statusDot = UIView()
    private let latencyLabel = UILabel()
    private var imageToken: PosterImageLoadToken?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        addInteraction(UIPointerInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = MarcoColors.cardSurface
        card.applyContinuousCorners(MarcoRadii.card)
        card.applyHairlineBorder()
        contentView.addSubview(card)

        crestView.translatesAutoresizingMaskIntoConstraints = false
        crestView.backgroundColor = MarcoColors.subtleFill
        crestView.applyContinuousCorners(12)
        card.addSubview(crestView)

        crestImageView.translatesAutoresizingMaskIntoConstraints = false
        crestImageView.contentMode = .scaleAspectFit
        crestImageView.clipsToBounds = true
        crestView.addSubview(crestImageView)

        crestInitialLabel.translatesAutoresizingMaskIntoConstraints = false
        crestInitialLabel.font = MarcoTypography.sectionHeader
        crestInitialLabel.textColor = MarcoColors.accentTint
        crestInitialLabel.textAlignment = .center
        crestView.addSubview(crestInitialLabel)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = MarcoTypography.cardTitle
        nameLabel.textColor = MarcoColors.primaryText
        nameLabel.numberOfLines = 1
        card.addSubview(nameLabel)

        epgLabel.translatesAutoresizingMaskIntoConstraints = false
        epgLabel.font = MarcoTypography.caption
        epgLabel.textColor = MarcoColors.secondaryText
        epgLabel.numberOfLines = 1
        card.addSubview(epgLabel)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.applyContinuousCorners(3.5)
        card.addSubview(statusDot)

        latencyLabel.translatesAutoresizingMaskIntoConstraints = false
        latencyLabel.font = MarcoTypography.monospacedDigits(size: 11, weight: .medium, textStyle: .caption2)
        latencyLabel.textColor = MarcoColors.tertiaryText
        card.addSubview(latencyLabel)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            crestView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            crestView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            crestView.widthAnchor.constraint(equalToConstant: 48),
            crestView.heightAnchor.constraint(equalToConstant: 48),

            crestImageView.topAnchor.constraint(equalTo: crestView.topAnchor, constant: 4),
            crestImageView.leadingAnchor.constraint(equalTo: crestView.leadingAnchor, constant: 4),
            crestImageView.trailingAnchor.constraint(equalTo: crestView.trailingAnchor, constant: -4),
            crestImageView.bottomAnchor.constraint(equalTo: crestView.bottomAnchor, constant: -4),

            crestInitialLabel.centerXAnchor.constraint(equalTo: crestView.centerXAnchor),
            crestInitialLabel.centerYAnchor.constraint(equalTo: crestView.centerYAnchor),

            nameLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: crestView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            epgLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            epgLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            epgLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            statusDot.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusDot.topAnchor.constraint(equalTo: epgLabel.bottomAnchor, constant: 7),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),

            latencyLabel.centerYAnchor.constraint(equalTo: statusDot.centerYAnchor),
            latencyLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
            latencyLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageToken?.cancel()
        imageToken = nil
        crestImageView.image = nil
        crestInitialLabel.isHidden = false
    }

    func configure(channel: LiveChannel, isSelected: Bool) {
        nameLabel.text = channel.name
        nameLabel.textColor = isSelected ? MarcoColors.accentTint : MarcoColors.primaryText
        epgLabel.text = "\(channel.group) · \(max(1, channel.episodes.count)) 条线路"

        switch channel.health {
        case .reachable:
            statusDot.backgroundColor = MarcoColors.success
        case .unreachable:
            statusDot.backgroundColor = MarcoColors.destructive
        default:
            statusDot.backgroundColor = MarcoColors.accentTint
        }
        if let ms = channel.latencyMs {
            latencyLabel.text = "\(ms) ms · 在线"
        } else {
            latencyLabel.text = isSelected ? "当前预览" : "实时直播"
        }

        crestInitialLabel.text = String(channel.name.prefix(2))
        crestImageView.image = nil
        crestInitialLabel.isHidden = false

        if !channel.logo.isEmpty {
            imageToken = PosterImageLoader.shared.loadImage(urlString: channel.logo) { [weak self] img in
                guard let self = self, let img = img else { return }
                self.crestImageView.image = img
                self.crestInitialLabel.isHidden = true
            }
        }
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .lift(UITargetedPreview(view: card)))
    }
}

// MARK: - Live TV View Controller

public final class LiveTvViewController: UIViewController, UICollectionViewDelegate, UISearchBarDelegate {
    private enum GroupSection: Int { case groups }
    private enum ChannelSection: Int { case channels }

    /// Strictly width-bounded (`340...420pt`) search & live source control bar on iPad.
    private let topBarWrapper = UIView()
    private let searchBar = UISearchBar()
    private let sourceSegment = UISegmentedControl(items: ["默认直播源"])

    /// Compact-only horizontal group strip; Regular-only left sidebar group tree.
    private let compactGroupScroll = UIScrollView()
    private let compactGroupStack = UIStackView()
    private var groupTreeCollectionView: UICollectionView!
    private var groupTreeDataSource: UICollectionViewDiffableDataSource<GroupSection, String>!
    private let dividerView = UIView()

    private var channelsCollectionView: UICollectionView!
    private var channelsDataSource: UICollectionViewDiffableDataSource<ChannelSection, LiveChannel>!

    /// Floating PiP-capable mini preview banner (visible on iPad / when a channel is active).
    private let miniPreviewGlass = MarcoGlassSurfaceView(style: .chrome, cornerRadius: MarcoRadii.card)
    private let miniLiveDot = UIView()
    private let miniTitleLabel = UILabel()
    private let miniSubtitleLabel = UILabel()
    private let miniFullscreenButton = MarcoPrimaryButton(title: "全屏播放", symbolName: "play.fill")
    private let miniCloseButton = UIButton(type: .system)

    private var compactLayoutConstraints: [NSLayoutConstraint] = []
    private var regularLayoutConstraints: [NSLayoutConstraint] = []
    private var isRegularLayoutActive: Bool?

    private var sources: [LiveSource] = []
    private var selectedSourceIndex = 0
    private var groups: [LiveGroup] = []
    private var selectedGroupName: String = ""
    private var filterText: String = ""
    private var activePreviewChannel: LiveChannel?
    private var loadTask: Task<Void, Never>?

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "电视直播"
        view.backgroundColor = MarcoColors.canvasBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: MarcoSymbols.image("plus.circle", pointSize: 17, weight: .medium),
            style: .plain,
            target: self,
            action: #selector(addStandaloneLiveSourceTapped)
        )

        setupBoundedTopControls()
        setupGroupViews()
        setupChannelsGrid()
        setupMiniPreviewBanner()
        applyAdaptiveLayout(for: traitCollection)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStateChanged),
            name: .marcoStateDidChange,
            object: nil
        )
        reloadSourcesAndChannels()
    }

    deinit {
        loadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass {
            applyAdaptiveLayout(for: traitCollection)
            channelsCollectionView.collectionViewLayout.invalidateLayout()
        }
    }

    // MARK: - View Construction

    private func setupBoundedTopControls() {
        topBarWrapper.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBarWrapper)

        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.searchBarStyle = .minimal
        searchBar.placeholder = "筛选频道名称或分组"
        searchBar.delegate = self
        topBarWrapper.addSubview(searchBar)

        sourceSegment.translatesAutoresizingMaskIntoConstraints = false
        sourceSegment.selectedSegmentIndex = 0
        sourceSegment.addTarget(self, action: #selector(sourceSegmentChanged), for: .valueChanged)
        topBarWrapper.addSubview(sourceSegment)

        let guide = view.safeAreaLayoutGuide
        let prefWidth = topBarWrapper.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -32)
        prefWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            topBarWrapper.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            topBarWrapper.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            prefWidth,
            topBarWrapper.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 16),
            topBarWrapper.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -16),
            topBarWrapper.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            searchBar.topAnchor.constraint(equalTo: topBarWrapper.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: topBarWrapper.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: topBarWrapper.trailingAnchor),

            sourceSegment.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 4),
            sourceSegment.leadingAnchor.constraint(equalTo: topBarWrapper.leadingAnchor, constant: 8),
            sourceSegment.trailingAnchor.constraint(equalTo: topBarWrapper.trailingAnchor, constant: -8),
            sourceSegment.heightAnchor.constraint(equalToConstant: 32),
            sourceSegment.bottomAnchor.constraint(equalTo: topBarWrapper.bottomAnchor),
        ])
    }

    private func setupGroupViews() {
        compactGroupScroll.translatesAutoresizingMaskIntoConstraints = false
        compactGroupScroll.showsHorizontalScrollIndicator = false
        view.addSubview(compactGroupScroll)

        compactGroupStack.translatesAutoresizingMaskIntoConstraints = false
        compactGroupStack.axis = .horizontal
        compactGroupStack.spacing = 8
        compactGroupStack.alignment = .center
        compactGroupScroll.addSubview(compactGroupStack)

        NSLayoutConstraint.activate([
            compactGroupStack.topAnchor.constraint(equalTo: compactGroupScroll.topAnchor),
            compactGroupStack.bottomAnchor.constraint(equalTo: compactGroupScroll.bottomAnchor),
            compactGroupStack.leadingAnchor.constraint(equalTo: compactGroupScroll.leadingAnchor, constant: 16),
            compactGroupStack.trailingAnchor.constraint(equalTo: compactGroupScroll.trailingAnchor, constant: -16),
            compactGroupStack.heightAnchor.constraint(equalTo: compactGroupScroll.heightAnchor),
        ])

        var listCfg = UICollectionLayoutListConfiguration(appearance: .sidebar)
        listCfg.backgroundColor = .clear
        let groupLayout = UICollectionViewCompositionalLayout.list(using: listCfg)
        groupTreeCollectionView = UICollectionView(frame: .zero, collectionViewLayout: groupLayout)
        groupTreeCollectionView.translatesAutoresizingMaskIntoConstraints = false
        groupTreeCollectionView.backgroundColor = .clear
        groupTreeCollectionView.delegate = self
        view.addSubview(groupTreeCollectionView)

        let groupReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, name in
            var content = cell.defaultContentConfiguration()
            content.text = name
            let count = self?.groups.first(where: { $0.name == name })?.channels.count ?? 0
            content.secondaryText = "\(count) 个频道"
            content.textProperties.font = MarcoTypography.cardTitle
            content.secondaryTextProperties.font = MarcoTypography.caption
            content.secondaryTextProperties.color = MarcoColors.secondaryText
            content.image = MarcoSymbols.image("tv", pointSize: 14, weight: .medium, hierarchicalColor: MarcoColors.accentTint)
            cell.contentConfiguration = content
        }
        groupTreeDataSource = UICollectionViewDiffableDataSource<GroupSection, String>(
            collectionView: groupTreeCollectionView
        ) { cv, ip, item in
            cv.dequeueConfiguredReusableCell(using: groupReg, for: ip, item: item)
        }

        dividerView.translatesAutoresizingMaskIntoConstraints = false
        dividerView.backgroundColor = MarcoColors.separator
        view.addSubview(dividerView)
    }

    private func setupChannelsGrid() {
        let layout = UICollectionViewCompositionalLayout { _, env in
            let isRegular = env.traitCollection.horizontalSizeClass == .regular
            let availW = max(env.container.effectiveContentSize.width - 32, 280)
            let cols: Int = isRegular ? max(2, min(3, Int(availW / 240))) : 1
            let spacing: CGFloat = 12

            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(cols)), heightDimension: .absolute(82))
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(82)),
                subitem: item,
                count: cols
            )
            group.interItemSpacing = .fixed(spacing)

            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 12
            section.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 100, trailing: 16)
            return section
        }

        channelsCollectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        channelsCollectionView.translatesAutoresizingMaskIntoConstraints = false
        channelsCollectionView.backgroundColor = .clear
        channelsCollectionView.delegate = self
        channelsCollectionView.register(LiveChannelCardCell.self, forCellWithReuseIdentifier: LiveChannelCardCell.reuseIdentifier)
        view.addSubview(channelsCollectionView)

        channelsDataSource = UICollectionViewDiffableDataSource<ChannelSection, LiveChannel>(
            collectionView: channelsCollectionView
        ) { [weak self] cv, ip, channel in
            let cell = cv.dequeueReusableCell(
                withReuseIdentifier: LiveChannelCardCell.reuseIdentifier,
                for: ip
            ) as! LiveChannelCardCell
            cell.configure(channel: channel, isSelected: self?.activePreviewChannel?.id == channel.id)
            return cell
        }
    }

    private func setupMiniPreviewBanner() {
        miniPreviewGlass.translatesAutoresizingMaskIntoConstraints = false
        miniPreviewGlass.isHidden = true
        view.addSubview(miniPreviewGlass)

        miniLiveDot.translatesAutoresizingMaskIntoConstraints = false
        miniLiveDot.backgroundColor = MarcoColors.success
        miniLiveDot.applyContinuousCorners(4)
        miniPreviewGlass.contentView.addSubview(miniLiveDot)

        miniTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        miniTitleLabel.font = MarcoTypography.cardTitle
        miniTitleLabel.textColor = MarcoColors.primaryText

        miniSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        miniSubtitleLabel.font = MarcoTypography.caption
        miniSubtitleLabel.textColor = MarcoColors.secondaryText

        let textStack = UIStackView(arrangedSubviews: [miniTitleLabel, miniSubtitleLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2
        miniPreviewGlass.contentView.addSubview(textStack)

        miniFullscreenButton.addTarget(self, action: #selector(openActivePreviewFullscreen), for: .touchUpInside)
        miniPreviewGlass.contentView.addSubview(miniFullscreenButton)

        miniCloseButton.translatesAutoresizingMaskIntoConstraints = false
        miniCloseButton.setImage(
            MarcoSymbols.image("xmark.circle.fill", pointSize: 20, weight: .medium, hierarchicalColor: MarcoColors.secondaryText),
            for: .normal
        )
        miniCloseButton.addTarget(self, action: #selector(dismissMiniPreview), for: .touchUpInside)
        miniPreviewGlass.contentView.addSubview(miniCloseButton)

        let guide = view.safeAreaLayoutGuide
        let widthPref = miniPreviewGlass.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -32)
        widthPref.priority = .defaultHigh

        NSLayoutConstraint.activate([
            miniPreviewGlass.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -14),
            miniPreviewGlass.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            widthPref,
            miniPreviewGlass.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            miniPreviewGlass.heightAnchor.constraint(equalToConstant: 66),

            miniLiveDot.leadingAnchor.constraint(equalTo: miniPreviewGlass.contentView.leadingAnchor, constant: 14),
            miniLiveDot.centerYAnchor.constraint(equalTo: miniPreviewGlass.contentView.centerYAnchor),
            miniLiveDot.widthAnchor.constraint(equalToConstant: 8),
            miniLiveDot.heightAnchor.constraint(equalToConstant: 8),

            textStack.leadingAnchor.constraint(equalTo: miniLiveDot.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: miniPreviewGlass.contentView.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: miniFullscreenButton.leadingAnchor, constant: -10),

            miniCloseButton.trailingAnchor.constraint(equalTo: miniPreviewGlass.contentView.trailingAnchor, constant: -10),
            miniCloseButton.centerYAnchor.constraint(equalTo: miniPreviewGlass.contentView.centerYAnchor),

            miniFullscreenButton.trailingAnchor.constraint(equalTo: miniCloseButton.leadingAnchor, constant: -8),
            miniFullscreenButton.centerYAnchor.constraint(equalTo: miniPreviewGlass.contentView.centerYAnchor),
            miniFullscreenButton.heightAnchor.constraint(equalToConstant: 36),
        ])

        let pixelW = 1.0 / max(UIScreen.main.scale, 1.0)
        compactLayoutConstraints = [
            compactGroupScroll.topAnchor.constraint(equalTo: topBarWrapper.bottomAnchor, constant: 10),
            compactGroupScroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            compactGroupScroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            compactGroupScroll.heightAnchor.constraint(equalToConstant: 34),

            channelsCollectionView.topAnchor.constraint(equalTo: compactGroupScroll.bottomAnchor, constant: 6),
            channelsCollectionView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            channelsCollectionView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            channelsCollectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]

        regularLayoutConstraints = [
            groupTreeCollectionView.topAnchor.constraint(equalTo: topBarWrapper.bottomAnchor, constant: 10),
            groupTreeCollectionView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            groupTreeCollectionView.widthAnchor.constraint(equalToConstant: 224),
            groupTreeCollectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            dividerView.topAnchor.constraint(equalTo: topBarWrapper.bottomAnchor, constant: 10),
            dividerView.leadingAnchor.constraint(equalTo: groupTreeCollectionView.trailingAnchor),
            dividerView.widthAnchor.constraint(equalToConstant: pixelW),
            dividerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            channelsCollectionView.topAnchor.constraint(equalTo: topBarWrapper.bottomAnchor, constant: 10),
            channelsCollectionView.leadingAnchor.constraint(equalTo: dividerView.trailingAnchor),
            channelsCollectionView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            channelsCollectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
    }

    private func applyAdaptiveLayout(for traits: UITraitCollection) {
        let isRegular = traits.horizontalSizeClass == .regular
        guard isRegular != isRegularLayoutActive else { return }
        isRegularLayoutActive = isRegular

        NSLayoutConstraint.deactivate(isRegular ? compactLayoutConstraints : regularLayoutConstraints)
        NSLayoutConstraint.activate(isRegular ? regularLayoutConstraints : compactLayoutConstraints)

        compactGroupScroll.isHidden = isRegular
        groupTreeCollectionView.isHidden = !isRegular
        dividerView.isHidden = !isRegular
    }

    // MARK: - Data Loading

    @objc private func handleStateChanged() {
        reloadSourcesAndChannels()
    }

    @objc private func sourceSegmentChanged() {
        MarcoHaptics.selection()
        selectedSourceIndex = max(0, sourceSegment.selectedSegmentIndex)
        loadChannelsForActiveSource()
    }

    private func reloadSourcesAndChannels() {
        sources = AppStateStore.shared.visibleLiveSources()
        sourceSegment.removeAllSegments()
        if sources.isEmpty {
            sourceSegment.insertSegment(withTitle: "暂无直播源", at: 0, animated: false)
            sourceSegment.selectedSegmentIndex = 0
            sourceSegment.isEnabled = false
            groups = []
            applyGroupsAndChannels()
            return
        }
        sourceSegment.isEnabled = true
        for (idx, src) in sources.prefix(4).enumerated() {
            sourceSegment.insertSegment(withTitle: src.name, at: idx, animated: false)
        }
        selectedSourceIndex = min(selectedSourceIndex, max(0, sourceSegment.numberOfSegments - 1))
        sourceSegment.selectedSegmentIndex = selectedSourceIndex
        loadChannelsForActiveSource()
    }

    private func loadChannelsForActiveSource() {
        loadTask?.cancel()
        let store = AppStateStore.shared
        if store.isSimulatorDemoMode {
            groups = SimulatorDemoFixtures.liveGroups
            if selectedGroupName.isEmpty || !groups.contains(where: { $0.name == selectedGroupName }) {
                selectedGroupName = groups.first?.name ?? ""
            }
            if activePreviewChannel == nil {
                activePreviewChannel = groups.first?.channels.first
                updateMiniPreviewBanner()
            }
            applyGroupsAndChannels()
            return
        }

        guard selectedSourceIndex < sources.count else {
            groups = []
            applyGroupsAndChannels()
            return
        }
        let source = sources[selectedSourceIndex]
        loadTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let loaded = try await store.cmsClient.fetchLiveGroups(source: source)
                guard !Task.isCancelled else { return }
                self.groups = loaded
                if self.selectedGroupName.isEmpty || !loaded.contains(where: { $0.name == self.selectedGroupName }) {
                    self.selectedGroupName = loaded.first?.name ?? ""
                }
                self.applyGroupsAndChannels()
            } catch {
                self.groups = []
                self.applyGroupsAndChannels()
            }
        }
    }

    private func applyGroupsAndChannels() {
        // Update sidebar tree
        var gSnap = NSDiffableDataSourceSnapshot<GroupSection, String>()
        gSnap.appendSections([.groups])
        gSnap.appendItems(groups.map(\.name), toSection: .groups)
        groupTreeDataSource.apply(gSnap, animatingDifferences: false) { [weak self] in
            guard let self = self,
                  let ip = self.groupTreeDataSource.indexPath(for: self.selectedGroupName)
            else { return }
            self.groupTreeCollectionView.selectItem(at: ip, animated: false, scrollPosition: [])
        }

        // Update compact group chips
        for v in compactGroupStack.arrangedSubviews {
            compactGroupStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for grp in groups {
            let selected = grp.name == selectedGroupName
            let btn = UIButton(type: .system)
            btn.setTitle("\(grp.name) (\(grp.channels.count))", for: .normal)
            btn.titleLabel?.font = MarcoTypography.caption
            btn.setTitleColor(selected ? MarcoColors.primaryActionForeground : MarcoColors.primaryText, for: .normal)
            btn.backgroundColor = selected ? MarcoColors.primaryActionFill : MarcoColors.subtleFill
            btn.applyContinuousCorners(14)
            btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
            btn.addAction(UIAction { [weak self] _ in
                self?.selectedGroupName = grp.name
                self?.applyGroupsAndChannels()
            }, for: .touchUpInside)
            compactGroupStack.addArrangedSubview(btn)
        }

        // Filter channels
        let baseChannels: [LiveChannel]
        if !filterText.isEmpty {
            let lower = filterText.lowercased()
            baseChannels = groups.flatMap(\.channels).filter {
                $0.name.lowercased().contains(lower) || $0.group.lowercased().contains(lower)
            }
        } else {
            baseChannels = groups.first(where: { $0.name == selectedGroupName })?.channels ?? []
        }

        var cSnap = NSDiffableDataSourceSnapshot<ChannelSection, LiveChannel>()
        cSnap.appendSections([.channels])
        cSnap.appendItems(baseChannels, toSection: .channels)
        channelsDataSource.apply(cSnap, animatingDifferences: false)

        if baseChannels.isEmpty && groups.isEmpty {
            let empty = UILabel()
            empty.text = "暂无直播源。点击右上角「+」添加您自有的 M3U / TXT 直播源地址，或导入包含直播的订阅源。"
            empty.font = MarcoTypography.body
            empty.textColor = MarcoColors.secondaryText
            empty.textAlignment = .center
            empty.numberOfLines = 0
            channelsCollectionView.backgroundView = empty
        } else {
            channelsCollectionView.backgroundView = nil
        }
    }

    private func updateMiniPreviewBanner() {
        guard let ch = activePreviewChannel else {
            miniPreviewGlass.isHidden = true
            return
        }
        miniPreviewGlass.isHidden = false
        miniTitleLabel.text = ch.name
        miniSubtitleLabel.text = "\(ch.group) · 支持画中画 (PiP) 与多线切换"
    }

    // MARK: - Search & Selection

    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        filterText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        applyGroupsAndChannels()
    }

    public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        MarcoHaptics.selection()
        if collectionView === groupTreeCollectionView {
            guard let name = groupTreeDataSource.itemIdentifier(for: indexPath) else { return }
            selectedGroupName = name
            applyGroupsAndChannels()
            return
        }
        guard let channel = channelsDataSource.itemIdentifier(for: indexPath) else { return }
        activePreviewChannel = channel
        updateMiniPreviewBanner()
        applyGroupsAndChannels()
        playLiveChannel(channel)
    }

    @objc private func openActivePreviewFullscreen() {
        guard let ch = activePreviewChannel else { return }
        playLiveChannel(ch)
    }

    @objc private func dismissMiniPreview() {
        activePreviewChannel = nil
        updateMiniPreviewBanner()
        applyGroupsAndChannels()
    }

    private func playLiveChannel(_ channel: LiveChannel) {
        let line = CmsLine(id: channel.id, name: channel.name, episodes: channel.episodes)
        let video = CmsVideo(
            id: channel.id,
            title: channel.name,
            poster: channel.logo,
            remarks: channel.group,
            lines: [line]
        )
        let site = AppStateStore.makeSyntheticPlaybackSite(key: "live_tv", name: "电视直播")
        AppStateStore.shared.presentPlayer(
            from: self,
            video: video,
            site: site,
            lines: [line],
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            startPositionMs: 0,
            isLive: true,
            liveChannelName: channel.name
        )
    }

    @objc private func addStandaloneLiveSourceTapped() {
        let alert = UIAlertController(
            title: "添加独立直播源",
            message: "支持您自有的 M3U / M3U8 / TXT 直播频道列表地址。",
            preferredStyle: .alert
        )
        alert.addTextField { $0.placeholder = "直播源名称（例如：客厅电视源）" }
        alert.addTextField {
            $0.placeholder = "https:// 直播源地址"
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = alert?.textFields?.last?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !url.isEmpty else { return }
            var list = AppStateStore.shared.storage.standaloneLiveSources()
            list.append(StandaloneLiveSource(
                id: UUID().uuidString,
                name: name.isEmpty ? "自建直播源" : name,
                url: url,
                updatedAt: Int64(Date().timeIntervalSince1970 * 1000)
            ))
            AppStateStore.shared.storage.saveStandaloneLiveSources(list)
            self?.reloadSourcesAndChannels()
        })
        present(alert, animated: true)
    }
}
