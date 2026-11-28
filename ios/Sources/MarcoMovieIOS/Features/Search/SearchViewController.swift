// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Multi-Site Concurrent Search & AI Natural-Language Search (iPad Width-Bounded Controls)

import MarcoIOSCore
import UIKit

// MARK: - Search Result Wrapper

private struct AggregatedSearchHit: Hashable {
    let siteKey: String
    let siteName: String
    let isPrivate: Bool
    let video: CmsVideo
}

// MARK: - Site Filter Sheet Controller

private final class SearchFilterSheetViewController: UITableViewController {
    private let sites: [CmsSite]
    private var selectedKeys: Set<String>
    private let onApply: (Set<String>) -> Void

    init(sites: [CmsSite], selectedKeys: Set<String>, onApply: @escaping (Set<String>) -> Void) {
        self.sites = sites
        self.selectedKeys = selectedKeys
        self.onApply = onApply
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "搜索片源筛选"
        tableView.backgroundColor = MarcoColors.canvasBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "全选", style: .plain, target: self, action: #selector(selectAllSites))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(applyAndClose))
    }

    @objc private func selectAllSites() {
        selectedKeys = Set(sites.map(\.key))
        tableView.reloadData()
    }

    @objc private func applyAndClose() {
        onApply(selectedKeys)
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sites.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "site")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "site")
        let site = sites[indexPath.row]
        cell.textLabel?.text = site.name
        cell.detailTextLabel?.text = site.group
        cell.detailTextLabel?.textColor = MarcoColors.secondaryText
        cell.accessoryType = selectedKeys.contains(site.key) ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let key = sites[indexPath.row].key
        if selectedKeys.contains(key) {
            selectedKeys.remove(key)
        } else {
            selectedKeys.insert(key)
        }
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}

// MARK: - Search View Controller

public final class SearchViewController: UIViewController, UISearchBarDelegate, UICollectionViewDelegate {
    private enum Section: Int {
        case results
    }

    private let initialQuery: String?

    /// Bounded control wrapper strictly constrained to 360...420pt on iPad (never stretched across 1300pt).
    private let boundedControlsWrapper = UIView()
    private let searchBar = UISearchBar()
    private let modeSegment = UISegmentedControl(items: ["全站聚合", "AI 语义找片"])
    private let historyScrollView = UIScrollView()
    private let historyStack = UIStackView()
    private let aiStatusBanner = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, AggregatedSearchHit>!

    private var results: [AggregatedSearchHit] = []
    private var aiSuggestions: [AiSearchSuggestion] = []
    private var selectedSiteKeys: Set<String> = []
    private var searchTask: Task<Void, Never>?

    public init(initialQuery: String? = nil) {
        self.initialQuery = initialQuery
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        searchTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "搜索"
        view.backgroundColor = MarcoColors.canvasBackground

        selectedSiteKeys = Set(AppStateStore.shared.visibleAvailableSites().filter(\.searchable).map(\.key))
        setupNavigationItems()
        setupControls()
        setupResultsGrid()
        configureDataSource()
        rebuildHistoryChips()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePrivacyChanged),
            name: .marcoPrivacyDidChange,
            object: nil
        )

        if let query = initialQuery, !query.isEmpty {
            executeExternalQuery(query)
        } else if AppStateStore.shared.isSimulatorDemoMode {
            executeExternalQuery("星际")
        }
    }

    public func executeExternalQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchBar.text = trimmed
        performSearch(query: trimmed)
    }

    // MARK: - UI Setup

    private func setupNavigationItems() {
        let filterButton = UIBarButtonItem(
            image: MarcoSymbols.image("line.3.horizontal.decrease.circle", pointSize: 17, weight: .medium),
            style: .plain,
            target: self,
            action: #selector(openFilterSheet(_:))
        )
        navigationItem.rightBarButtonItem = filterButton
    }

    private func setupControls() {
        boundedControlsWrapper.translatesAutoresizingMaskIntoConstraints = false
        boundedControlsWrapper.backgroundColor = .clear
        view.addSubview(boundedControlsWrapper)

        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.searchBarStyle = .minimal
        searchBar.placeholder = "搜索片名、演员、导演或描述想看的类型"
        searchBar.delegate = self
        searchBar.returnKeyType = .search
        boundedControlsWrapper.addSubview(searchBar)

        modeSegment.translatesAutoresizingMaskIntoConstraints = false
        modeSegment.selectedSegmentIndex = 0
        modeSegment.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        boundedControlsWrapper.addSubview(modeSegment)

        aiStatusBanner.translatesAutoresizingMaskIntoConstraints = false
        aiStatusBanner.font = MarcoTypography.caption
        aiStatusBanner.textColor = MarcoColors.secondaryText
        aiStatusBanner.textAlignment = .center
        aiStatusBanner.numberOfLines = 2
        aiStatusBanner.isHidden = true
        boundedControlsWrapper.addSubview(aiStatusBanner)

        historyScrollView.translatesAutoresizingMaskIntoConstraints = false
        historyScrollView.showsHorizontalScrollIndicator = false
        view.addSubview(historyScrollView)

        historyStack.translatesAutoresizingMaskIntoConstraints = false
        historyStack.axis = .horizontal
        historyStack.spacing = 8
        historyStack.alignment = .center
        historyScrollView.addSubview(historyStack)

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)

        let guide = view.safeAreaLayoutGuide
        let preferredWidth = boundedControlsWrapper.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -32)
        preferredWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            boundedControlsWrapper.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            boundedControlsWrapper.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            preferredWidth,
            boundedControlsWrapper.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 16),
            boundedControlsWrapper.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -16),
            boundedControlsWrapper.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            searchBar.topAnchor.constraint(equalTo: boundedControlsWrapper.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: boundedControlsWrapper.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: boundedControlsWrapper.trailingAnchor),

            modeSegment.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 6),
            modeSegment.leadingAnchor.constraint(equalTo: boundedControlsWrapper.leadingAnchor, constant: 8),
            modeSegment.trailingAnchor.constraint(equalTo: boundedControlsWrapper.trailingAnchor, constant: -8),
            modeSegment.heightAnchor.constraint(equalToConstant: 32),

            aiStatusBanner.topAnchor.constraint(equalTo: modeSegment.bottomAnchor, constant: 6),
            aiStatusBanner.leadingAnchor.constraint(equalTo: boundedControlsWrapper.leadingAnchor, constant: 8),
            aiStatusBanner.trailingAnchor.constraint(equalTo: boundedControlsWrapper.trailingAnchor, constant: -8),
            aiStatusBanner.bottomAnchor.constraint(equalTo: boundedControlsWrapper.bottomAnchor),

            historyScrollView.topAnchor.constraint(equalTo: boundedControlsWrapper.bottomAnchor, constant: 10),
            historyScrollView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            historyScrollView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            historyScrollView.heightAnchor.constraint(equalToConstant: 34),

            historyStack.topAnchor.constraint(equalTo: historyScrollView.topAnchor),
            historyStack.bottomAnchor.constraint(equalTo: historyScrollView.bottomAnchor),
            historyStack.leadingAnchor.constraint(equalTo: historyScrollView.leadingAnchor, constant: 16),
            historyStack.trailingAnchor.constraint(equalTo: historyScrollView.trailingAnchor, constant: -16),
            historyStack.heightAnchor.constraint(equalTo: historyScrollView.heightAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.topAnchor.constraint(equalTo: historyScrollView.bottomAnchor, constant: 18),
        ])
    }

    private func setupResultsGrid() {
        let layout = UICollectionViewCompositionalLayout { _, env in
            let isRegular = env.traitCollection.horizontalSizeClass == .regular
            let margin = MarcoSpacing.horizontalMargin(for: env.traitCollection)
            let availW = max(env.container.effectiveContentSize.width - margin * 2, 300)
            let cols = isRegular ? max(4, min(6, Int(availW / 168))) : 3
            let spacing: CGFloat = isRegular ? 16 : 12
            let itemW = (availW - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let itemH = itemW * 1.5 + 58

            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(cols)), heightDimension: .absolute(itemH))
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(itemH)),
                subitem: item,
                count: cols
            )
            group.interItemSpacing = .fixed(spacing)

            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 18
            section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: margin, bottom: 28, trailing: margin)
            return section
        }

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.register(PosterCardCell.self, forCellWithReuseIdentifier: PosterCardCell.reuseIdentifier)
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: historyScrollView.bottomAnchor, constant: 8),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, AggregatedSearchHit>(
            collectionView: collectionView
        ) { collectionView, indexPath, hit in
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PosterCardCell.reuseIdentifier,
                for: indexPath
            ) as! PosterCardCell
            let rating = hit.video.doubanScore.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil }
            let badge = hit.siteName.isEmpty ? hit.video.remarks : hit.siteName
            cell.configure(with: PosterCardModel(
                id: "\(hit.siteKey)|\(hit.video.id)",
                title: hit.video.title,
                subtitle: hit.video.remarks.isEmpty ? hit.video.year : hit.video.remarks,
                badge: badge,
                rating: rating,
                posterURL: hit.video.poster,
                isPrivate: hit.isPrivate
            ))
            return cell
        }
    }

    // MARK: - Search History & AI Chips

    private func rebuildHistoryChips() {
        for sub in historyStack.arrangedSubviews {
            historyStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        let store = AppStateStore.shared
        if !aiSuggestions.isEmpty {
            for sug in aiSuggestions {
                let title = sug.year.isEmpty ? "✦ \(sug.title)" : "✦ \(sug.title) (\(sug.year))"
                let btn = makeChipButton(title: title, highlighted: true)
                btn.addAction(UIAction { [weak self] _ in
                    self?.modeSegment.selectedSegmentIndex = 0
                    self?.executeExternalQuery(sug.title)
                }, for: .touchUpInside)
                historyStack.addArrangedSubview(btn)
            }
            return
        }

        let history = store.storage.searchHistory(isPrivateSpace: store.isPrivacySpaceUnlocked)
        let chips = history.isEmpty && store.isSimulatorDemoMode
            ? ["星际地平线", "4K HDR", "纪录片", "午夜港湾"]
            : history

        for word in chips.prefix(12) {
            let btn = makeChipButton(title: word, highlighted: false)
            btn.addAction(UIAction { [weak self] _ in
                self?.executeExternalQuery(word)
            }, for: .touchUpInside)
            historyStack.addArrangedSubview(btn)
        }

        if !history.isEmpty {
            let clearBtn = makeChipButton(title: "清空历史", highlighted: false)
            clearBtn.setTitleColor(MarcoColors.destructive, for: .normal)
            clearBtn.addAction(UIAction { [weak self] _ in
                AppStateStore.shared.storage.clearSearchHistory(
                    isPrivateSpace: AppStateStore.shared.isPrivacySpaceUnlocked
                )
                self?.rebuildHistoryChips()
            }, for: .touchUpInside)
            historyStack.addArrangedSubview(clearBtn)
        }
    }

    private func makeChipButton(title: String, highlighted: Bool) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = MarcoTypography.caption
        btn.setTitleColor(highlighted ? MarcoColors.primaryActionForeground : MarcoColors.primaryText, for: .normal)
        btn.backgroundColor = highlighted ? MarcoColors.accentTint : MarcoColors.subtleFill
        btn.applyContinuousCorners(14)
        btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        return btn
    }

    // MARK: - Search Execution

    @objc private func modeChanged() {
        MarcoHaptics.selection()
        updateAiBannerState()
        if let q = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            performSearch(query: q)
        }
    }

    @objc private func handlePrivacyChanged() {
        selectedSiteKeys = Set(AppStateStore.shared.visibleAvailableSites().filter(\.searchable).map(\.key))
        updateAiBannerState()
        rebuildHistoryChips()
    }

    private func updateAiBannerState() {
        let isAiMode = modeSegment.selectedSegmentIndex == 1
        if !isAiMode {
            aiStatusBanner.isHidden = true
            return
        }
        let store = AppStateStore.shared
        aiStatusBanner.isHidden = false
        if store.isPrivacySpaceUnlocked {
            aiStatusBanner.text = "隐私空间安全熔断已触发：已自动禁用外部 AI 网络请求"
            aiStatusBanner.textColor = MarcoColors.ratingGold
        } else if !store.storage.aiConfig().enabled {
            aiStatusBanner.text = "前往「设置 → AI 观影实验室」配置接口后即可启用语义找片"
            aiStatusBanner.textColor = MarcoColors.secondaryText
        } else {
            aiStatusBanner.text = "输入剧情、氛围或关键词，AI 将自动生成多组候选片名"
            aiStatusBanner.textColor = MarcoColors.secondaryText
        }
    }

    public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        guard let q = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else { return }
        performSearch(query: q)
    }

    private func performSearch(query: String) {
        searchTask?.cancel()
        aiSuggestions.removeAll()
        let store = AppStateStore.shared
        if !store.isSimulatorDemoMode {
            store.storage.addSearchKeyword(query, isPrivateSpace: store.isPrivacySpaceUnlocked)
        }
        rebuildHistoryChips()

        if store.isSimulatorDemoMode {
            let lower = query.lowercased()
            let matched = SimulatorDemoFixtures.videos.filter {
                $0.title.lowercased().contains(lower)
                    || $0.tag.lowercased().contains(lower)
                    || $0.remarks.lowercased().contains(lower)
                    || $0.description.lowercased().contains(lower)
            }
            let pool = matched.isEmpty ? SimulatorDemoFixtures.videos : matched
            results = pool.map {
                AggregatedSearchHit(
                    siteKey: SimulatorDemoFixtures.demoSite.key,
                    siteName: SimulatorDemoFixtures.demoSite.name,
                    isPrivate: false,
                    video: $0
                )
            }
            applyResults()
            return
        }

        if modeSegment.selectedSegmentIndex == 1 {
            performAiSearch(naturalQuery: query)
            return
        }

        let searchableSites = store.visibleAvailableSites().filter {
            $0.searchable && (selectedSiteKeys.isEmpty || selectedSiteKeys.contains($0.key))
        }
        guard !searchableSites.isEmpty else {
            results = []
            applyResults()
            return
        }

        activityIndicator.startAnimating()
        results = []
        applyResults()

        let cmsClient = store.cmsClient
        let storage = store.storage
        searchTask = Task { [weak self] in
            guard let self = self else { return }
            var aggregated: [AggregatedSearchHit] = []
            await withTaskGroup(of: [AggregatedSearchHit].self) { group in
                for site in searchableSites.prefix(12) {
                    group.addTask {
                        do {
                            let found = try await cmsClient.search(
                                site: site,
                                keyword: query,
                                page: 1,
                                storage: storage
                            )
                            return found.map {
                                AggregatedSearchHit(
                                    siteKey: site.key,
                                    siteName: site.name,
                                    isPrivate: site.isEffectivelyPrivate,
                                    video: $0
                                )
                            }
                        } catch {
                            return []
                        }
                    }
                }
                for await batch in group {
                    if Task.isCancelled { break }
                    aggregated.append(contentsOf: batch)
                }
            }
            guard !Task.isCancelled else { return }
            self.activityIndicator.stopAnimating()
            self.results = aggregated
            self.applyResults()
        }
    }

    private func performAiSearch(naturalQuery: String) {
        let store = AppStateStore.shared
        updateAiBannerState()
        guard !store.isPrivacySpaceUnlocked else { return }
        activityIndicator.startAnimating()
        searchTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let suggestions = try await store.aiService.suggestSearchQueries(
                    naturalLanguageQuery: naturalQuery,
                    isPrivateSpace: store.isPrivacySpaceUnlocked
                )
                guard !Task.isCancelled else { return }
                self.activityIndicator.stopAnimating()
                self.aiSuggestions = suggestions
                self.aiStatusBanner.isHidden = false
                self.aiStatusBanner.text = suggestions.isEmpty
                    ? "未生成候选片名，请尝试更具体的描述"
                    : "AI 推荐了 \(suggestions.count) 部相关片单，轻点下方芯片即可全站搜索"
                self.rebuildHistoryChips()
                if let first = suggestions.first {
                    self.modeSegment.selectedSegmentIndex = 0
                    self.performSearch(query: first.title)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.activityIndicator.stopAnimating()
                self.aiStatusBanner.isHidden = false
                self.aiStatusBanner.text = error.localizedDescription
            }
        }
    }

    private func applyResults() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, AggregatedSearchHit>()
        snapshot.appendSections([.results])
        snapshot.appendItems(results, toSection: .results)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    @objc private func openFilterSheet(_ sender: UIBarButtonItem) {
        let sites = AppStateStore.shared.visibleAvailableSites().filter(\.searchable)
        let vc = SearchFilterSheetViewController(
            sites: sites,
            selectedKeys: selectedSiteKeys.isEmpty ? Set(sites.map(\.key)) : selectedSiteKeys
        ) { [weak self] nextKeys in
            self?.selectedSiteKeys = nextKeys
        }
        let options = MarcoModalOptions(
            detents: [.medium, .large],
            preferredFormSheetSize: CGSize(width: 420, height: 520),
            barButtonItem: sender,
            wrapInNavigationController: true
        )
        MarcoModalPresenter.present(vc, from: self, options: options)
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let hit = dataSource.itemIdentifier(for: indexPath) else { return }
        MarcoHaptics.selection()
        let store = AppStateStore.shared
        let site = store.visibleAvailableSites().first(where: { $0.key == hit.siteKey })
            ?? AppStateStore.makeSyntheticPlaybackSite(key: hit.siteKey, name: hit.siteName, isPrivate: hit.isPrivate)
        let detail = VideoDetailViewController(video: hit.video, site: site)
        let cell = collectionView.cellForItem(at: indexPath) as? PosterCardCell
        MarcoZoomTransitionHelper.push(
            detail,
            on: navigationController,
            from: { [weak cell] in cell?.zoomSourceView }
        )
    }
}
