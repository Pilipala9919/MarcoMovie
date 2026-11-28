// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Personal Netdisk (Quark/UC/Baidu/Ali/115) & Media Library (Emby/Jellyfin/Plex/WebDAV/AList/SMB2/ISO) Browser

import MarcoIOSCore
import UIKit

public final class NetdiskAndMediaBrowserViewController: UITableViewController {
    public enum Mode {
        case personalNetdisk(provider: NetdiskProvider, folderId: String, driveId: String, title: String)
        case mediaLibrary(site: CmsSite, categoryId: String?, title: String)
    }

    private let mode: Mode
    private var cloudFiles: [PersonalCloudFile] = []
    private var libraryCategories: [CmsCategory] = []
    private var libraryVideos: [CmsVideo] = []
    private var loadTask: Task<Void, Never>?
    private let spinner = UIActivityIndicatorView(style: .medium)

    public init(mode: Mode) {
        self.mode = mode
        super.init(style: .insetGrouped)
        switch mode {
        case .personalNetdisk(_, _, _, let title):
            self.title = title
        case .mediaLibrary(_, _, let title):
            self.title = title
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = MarcoColors.canvasBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(loadContents), for: .valueChanged)
        refreshControl = refresh

        loadContents()
    }

    @objc private func loadContents() {
        loadTask?.cancel()
        spinner.startAnimating()
        let store = AppStateStore.shared

        loadTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                self.spinner.stopAnimating()
                self.refreshControl?.endRefreshing()
            }
            do {
                switch self.mode {
                case .personalNetdisk(let provider, let folderId, let driveId, _):
                    let page = try await store.personalNetdiskLibrary.listFolder(
                        provider: provider,
                        folderId: folderId,
                        page: 1,
                        driveId: driveId
                    )
                    guard !Task.isCancelled else { return }
                    self.cloudFiles = page.items
                    self.tableView.reloadData()

                case .mediaLibrary(let site, let categoryId, _):
                    if let catId = categoryId {
                        let listing = try await store.cmsClient.fetchCategory(
                            site: site,
                            categoryId: catId,
                            page: 1,
                            storage: store.storage
                        )
                        guard !Task.isCancelled else { return }
                        self.libraryCategories = []
                        self.libraryVideos = listing.videos
                    } else {
                        let home = try await store.cmsClient.fetchHome(site: site, storage: store.storage)
                        guard !Task.isCancelled else { return }
                        self.libraryCategories = home.categories
                        self.libraryVideos = home.listing.videos
                    }
                    self.tableView.reloadData()
                }
            } catch {
                guard !Task.isCancelled else { return }
                let label = UILabel()
                label.text = error.localizedDescription
                label.font = MarcoTypography.body
                label.textColor = MarcoColors.secondaryText
                label.textAlignment = .center
                label.numberOfLines = 0
                self.tableView.backgroundView = label
            }
        }
    }

    // MARK: - TableView DataSource

    public override func numberOfSections(in tableView: UITableView) -> Int {
        switch mode {
        case .personalNetdisk:
            return 1
        case .mediaLibrary:
            return libraryCategories.isEmpty ? 1 : 2
        }
    }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch mode {
        case .personalNetdisk:
            return cloudFiles.isEmpty ? nil : "目录与视频文件"
        case .mediaLibrary:
            if !libraryCategories.isEmpty && section == 0 {
                return "媒体库分区 / 目录"
            }
            return libraryVideos.isEmpty ? nil : "影片与文件"
        }
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch mode {
        case .personalNetdisk:
            return cloudFiles.count
        case .mediaLibrary:
            if !libraryCategories.isEmpty && section == 0 {
                return libraryCategories.count
            }
            return libraryVideos.count
        }
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "browserRow")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "browserRow")
        cell.backgroundColor = MarcoColors.cardSurface
        cell.textLabel?.font = MarcoTypography.cardTitle
        cell.textLabel?.textColor = MarcoColors.primaryText
        cell.detailTextLabel?.font = MarcoTypography.caption
        cell.detailTextLabel?.textColor = MarcoColors.secondaryText

        switch mode {
        case .personalNetdisk:
            let file = cloudFiles[indexPath.row]
            cell.textLabel?.text = file.name
            cell.detailTextLabel?.text = file.isDir ? "文件夹" : formatBytes(file.size)
            cell.imageView?.image = MarcoSymbols.image(
                file.isDir ? "folder.fill" : "film.fill",
                pointSize: 18,
                weight: .medium,
                hierarchicalColor: file.isDir ? MarcoColors.accentTint : MarcoColors.secondaryText
            )
            cell.accessoryType = file.isDir ? .disclosureIndicator : .none

        case .mediaLibrary:
            if !libraryCategories.isEmpty && indexPath.section == 0 {
                let cat = libraryCategories[indexPath.row]
                cell.textLabel?.text = cat.name
                cell.detailTextLabel?.text = "目录"
                cell.imageView?.image = MarcoSymbols.image(
                    "folder.fill",
                    pointSize: 18,
                    weight: .medium,
                    hierarchicalColor: MarcoColors.accentTint
                )
                cell.accessoryType = .disclosureIndicator
            } else {
                let vid = libraryVideos[indexPath.row]
                let isFolder = vid.tag == ExternalMediaLibraryDispatcher.folderTag
                cell.textLabel?.text = vid.title
                cell.detailTextLabel?.text = isFolder ? "目录" : (vid.remarks.isEmpty ? vid.year : vid.remarks)
                cell.imageView?.image = MarcoSymbols.image(
                    isFolder ? "folder.fill" : (vid.title.lowercased().hasSuffix(".iso") ? "opticaldisc.fill" : "play.rectangle.fill"),
                    pointSize: 18,
                    weight: .medium,
                    hierarchicalColor: isFolder ? MarcoColors.accentTint : MarcoColors.secondaryText
                )
                cell.accessoryType = .disclosureIndicator
            }
        }
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        MarcoHaptics.selection()
        let store = AppStateStore.shared

        switch mode {
        case .personalNetdisk(let provider, _, _, _):
            let file = cloudFiles[indexPath.row]
            if file.isDir {
                let next = NetdiskAndMediaBrowserViewController(
                    mode: .personalNetdisk(
                        provider: provider,
                        folderId: file.id,
                        driveId: file.driveId,
                        title: file.name
                    )
                )
                navigationController?.pushViewController(next, animated: true)
            } else {
                spinner.startAnimating()
                Task { [weak self] in
                    guard let self = self else { return }
                    defer { self.spinner.stopAnimating() }
                    do {
                        let resolved = try await store.personalNetdiskLibrary.resolveFile(
                            file,
                            rangeProxy: store.rangeProxy,
                            headerProxy: store.headerProxy
                        )
                        let ep = CmsEpisode(name: file.name, url: resolved.playableUrl.absoluteString, headers: resolved.headers)
                        let line = CmsLine(name: "\(provider.displayName) · \(resolved.resolutionBadge)", episodes: [ep])
                        let video = CmsVideo(id: file.id, title: ExternalMediaLibraryDispatcher.cleanMediaTitle(file.name), poster: file.thumbnail, lines: [line])
                        let site = AppStateStore.makeSyntheticPlaybackSite(key: "cloud_\(provider.rawValue)", name: provider.displayName)
                        store.presentPlayer(from: self, video: video, site: site, lines: [line])
                    } catch {
                        let alert = UIAlertController(title: "解析失败", message: error.localizedDescription, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "好的", style: .default))
                        self.present(alert, animated: true)
                    }
                }
            }

        case .mediaLibrary(let site, _, _):
            if !libraryCategories.isEmpty && indexPath.section == 0 {
                let cat = libraryCategories[indexPath.row]
                let next = NetdiskAndMediaBrowserViewController(
                    mode: .mediaLibrary(site: site, categoryId: cat.id, title: cat.name)
                )
                navigationController?.pushViewController(next, animated: true)
            } else {
                let vid = libraryVideos[indexPath.row]
                if vid.tag == ExternalMediaLibraryDispatcher.folderTag {
                    let next = NetdiskAndMediaBrowserViewController(
                        mode: .mediaLibrary(site: site, categoryId: vid.id, title: vid.title)
                    )
                    navigationController?.pushViewController(next, animated: true)
                } else {
                    let detail = VideoDetailViewController(video: vid, site: site)
                    navigationController?.pushViewController(detail, animated: true)
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "媒体文件" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
