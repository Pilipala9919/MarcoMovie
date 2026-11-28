// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Apple TV+ Poster Cards (2:3 Portrait & 16:9 Landscape) & Shelf Headers

import UIKit

// MARK: - Card Value Model

public struct PosterCardModel: Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let badge: String?
    public let rating: String?
    public let posterURL: String?
    public let headers: [String: String]
    public let isPrivate: Bool
    public let progressFraction: Double?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        rating: String? = nil,
        posterURL: String? = nil,
        headers: [String: String] = [:],
        isPrivate: Bool = false,
        progressFraction: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.rating = rating
        self.posterURL = posterURL
        self.headers = headers
        self.isPrivate = isPrivate
        self.progressFraction = progressFraction
    }
}

// MARK: - Vertical 2:3 Poster Card Cell

/// Clean 2:3 vertical cinema poster cell with full-bleed continuous-corner artwork,
/// understated translucent badge pill, optional bottom playback progress bar,
/// crisp 2-line title + 1-line subtitle, highlight spring animation, and iPad pointer lift.
public final class PosterCardCell: UICollectionViewCell, UIPointerInteractionDelegate {
    public static let reuseIdentifier = "PosterCardCell"

    private let shadowContainerView = UIView()
    private let posterContainerView = UIView()
    private let posterImageView = UIImageView()
    private let bottomScrimLayer = CAGradientLayer()

    private let badgeContainerView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let badgeLabel = UILabel()

    private let ratingContainerView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let ratingStarView = UIImageView()
    private let ratingLabel = UILabel()

    private let progressTrackView = UIView()
    private let progressFillView = UIView()
    private var progressFillWidthConstraint: NSLayoutConstraint?

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    private var imageToken: PosterImageLoadToken?
    private var currentModelID: String?

    /// Source view used by `MarcoZoomTransitionHelper` on iOS 18+ to zoom smoothly out of the poster.
    public var zoomSourceView: UIView {
        posterContainerView
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupHierarchy()
        addInteraction(UIPointerInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupHierarchy() {
        contentView.backgroundColor = .clear
        clipsToBounds = false
        contentView.clipsToBounds = false

        shadowContainerView.translatesAutoresizingMaskIntoConstraints = false
        shadowContainerView.backgroundColor = .clear
        shadowContainerView.layer.shadowColor = UIColor.black.cgColor
        shadowContainerView.layer.shadowOffset = CGSize(width: 0, height: 8)
        shadowContainerView.layer.shadowRadius = 14
        contentView.addSubview(shadowContainerView)

        posterContainerView.translatesAutoresizingMaskIntoConstraints = false
        posterContainerView.backgroundColor = MarcoColors.posterPlaceholderBase
        posterContainerView.applyContinuousCorners(MarcoRadii.poster)
        shadowContainerView.addSubview(posterContainerView)

        posterImageView.translatesAutoresizingMaskIntoConstraints = false
        posterImageView.contentMode = .scaleAspectFill
        posterImageView.clipsToBounds = true
        posterContainerView.addSubview(posterImageView)

        bottomScrimLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.62).cgColor,
        ]
        bottomScrimLayer.locations = [0.45, 1.0]
        bottomScrimLayer.isHidden = true
        posterContainerView.layer.addSublayer(bottomScrimLayer)

        // Subtle top-right badge pill
        badgeContainerView.translatesAutoresizingMaskIntoConstraints = false
        badgeContainerView.applyContinuousCorners(7)
        badgeContainerView.isHidden = true
        posterContainerView.addSubview(badgeContainerView)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = MarcoTypography.badge
        badgeLabel.textColor = .white
        badgeLabel.lineBreakMode = .byTruncatingTail
        badgeContainerView.contentView.addSubview(badgeLabel)

        // Subtle bottom-left rating pill
        ratingContainerView.translatesAutoresizingMaskIntoConstraints = false
        ratingContainerView.applyContinuousCorners(7)
        ratingContainerView.isHidden = true
        posterContainerView.addSubview(ratingContainerView)

        ratingStarView.translatesAutoresizingMaskIntoConstraints = false
        ratingStarView.image = MarcoSymbols.image(
            "star.fill",
            pointSize: 9.5,
            weight: .semibold,
            hierarchicalColor: MarcoColors.ratingGold
        )
        ratingStarView.contentMode = .scaleAspectFit
        ratingContainerView.contentView.addSubview(ratingStarView)

        ratingLabel.translatesAutoresizingMaskIntoConstraints = false
        ratingLabel.font = MarcoTypography.monospacedDigits(size: 11, weight: .semibold, textStyle: .caption2)
        ratingLabel.textColor = .white
        ratingContainerView.contentView.addSubview(ratingLabel)

        // Optional bottom playback progress bar
        progressTrackView.translatesAutoresizingMaskIntoConstraints = false
        progressTrackView.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        progressTrackView.applyContinuousCorners(1.75)
        progressTrackView.isHidden = true
        posterContainerView.addSubview(progressTrackView)

        progressFillView.translatesAutoresizingMaskIntoConstraints = false
        progressFillView.backgroundColor = .white
        progressFillView.applyContinuousCorners(1.75)
        progressTrackView.addSubview(progressFillView)

        // Crisp 2-line title & 1-line subtitle below poster
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MarcoTypography.cardTitle
        titleLabel.textColor = MarcoColors.primaryText
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = MarcoTypography.cardSubtitle
        subtitleLabel.textColor = MarcoColors.secondaryText
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(subtitleLabel)

        let aspectConstraint = shadowContainerView.heightAnchor.constraint(
            equalTo: shadowContainerView.widthAnchor,
            multiplier: 1.5
        )
        aspectConstraint.priority = .defaultHigh

        let widthConstraint = progressFillView.widthAnchor.constraint(equalTo: progressTrackView.widthAnchor, multiplier: 0.01)
        progressFillWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            shadowContainerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            shadowContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            shadowContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            aspectConstraint,

            posterContainerView.topAnchor.constraint(equalTo: shadowContainerView.topAnchor),
            posterContainerView.leadingAnchor.constraint(equalTo: shadowContainerView.leadingAnchor),
            posterContainerView.trailingAnchor.constraint(equalTo: shadowContainerView.trailingAnchor),
            posterContainerView.bottomAnchor.constraint(equalTo: shadowContainerView.bottomAnchor),

            posterImageView.topAnchor.constraint(equalTo: posterContainerView.topAnchor),
            posterImageView.leadingAnchor.constraint(equalTo: posterContainerView.leadingAnchor),
            posterImageView.trailingAnchor.constraint(equalTo: posterContainerView.trailingAnchor),
            posterImageView.bottomAnchor.constraint(equalTo: posterContainerView.bottomAnchor),

            badgeContainerView.topAnchor.constraint(equalTo: posterContainerView.topAnchor, constant: 8),
            badgeContainerView.trailingAnchor.constraint(equalTo: posterContainerView.trailingAnchor, constant: -8),
            badgeContainerView.leadingAnchor.constraint(greaterThanOrEqualTo: posterContainerView.leadingAnchor, constant: 8),

            badgeLabel.topAnchor.constraint(equalTo: badgeContainerView.contentView.topAnchor, constant: 3),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeContainerView.contentView.bottomAnchor, constant: -3),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainerView.contentView.leadingAnchor, constant: 6.5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainerView.contentView.trailingAnchor, constant: -6.5),

            ratingContainerView.leadingAnchor.constraint(equalTo: posterContainerView.leadingAnchor, constant: 8),
            ratingContainerView.bottomAnchor.constraint(equalTo: progressTrackView.topAnchor, constant: -6),

            ratingStarView.leadingAnchor.constraint(equalTo: ratingContainerView.contentView.leadingAnchor, constant: 5.5),
            ratingStarView.centerYAnchor.constraint(equalTo: ratingContainerView.contentView.centerYAnchor),
            ratingStarView.widthAnchor.constraint(equalToConstant: 10),
            ratingStarView.heightAnchor.constraint(equalToConstant: 10),

            ratingLabel.leadingAnchor.constraint(equalTo: ratingStarView.trailingAnchor, constant: 3),
            ratingLabel.trailingAnchor.constraint(equalTo: ratingContainerView.contentView.trailingAnchor, constant: -6),
            ratingLabel.topAnchor.constraint(equalTo: ratingContainerView.contentView.topAnchor, constant: 3),
            ratingLabel.bottomAnchor.constraint(equalTo: ratingContainerView.contentView.bottomAnchor, constant: -3),

            progressTrackView.leadingAnchor.constraint(equalTo: posterContainerView.leadingAnchor, constant: 8),
            progressTrackView.trailingAnchor.constraint(equalTo: posterContainerView.trailingAnchor, constant: -8),
            progressTrackView.bottomAnchor.constraint(equalTo: posterContainerView.bottomAnchor, constant: -8),
            progressTrackView.heightAnchor.constraint(equalToConstant: 3.5),

            progressFillView.topAnchor.constraint(equalTo: progressTrackView.topAnchor),
            progressFillView.leadingAnchor.constraint(equalTo: progressTrackView.leadingAnchor),
            progressFillView.bottomAnchor.constraint(equalTo: progressTrackView.bottomAnchor),
            widthConstraint,

            titleLabel.topAnchor.constraint(equalTo: shadowContainerView.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 1),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -1),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -1),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])

        updateSurfaceStyle()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomScrimLayer.frame = posterContainerView.bounds
        shadowContainerView.layer.shadowPath = UIBezierPath(
            roundedRect: shadowContainerView.bounds,
            cornerRadius: MarcoRadii.poster
        ).cgPath
        CATransaction.commit()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateSurfaceStyle()
        }
    }

    private func updateSurfaceStyle() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        shadowContainerView.layer.shadowOpacity = isDark ? 0.34 : 0.12
        posterContainerView.applyHairlineBorder(
            color: MarcoColors.hairlineBorder.resolvedColor(with: traitCollection)
        )
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        imageToken?.cancel()
        imageToken = nil
        currentModelID = nil
        posterImageView.image = nil
        badgeContainerView.isHidden = true
        ratingContainerView.isHidden = true
        progressTrackView.isHidden = true
        bottomScrimLayer.isHidden = true
        titleLabel.text = nil
        subtitleLabel.text = nil
    }

    public func configure(with model: PosterCardModel) {
        imageToken?.cancel()
        imageToken = nil
        currentModelID = model.id

        titleLabel.text = model.title
        if let subtitle = model.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.text = nil
            subtitleLabel.isHidden = true
        }

        if let badge = model.badge?.trimmingCharacters(in: .whitespacesAndNewlines), !badge.isEmpty {
            badgeLabel.text = badge
            badgeContainerView.isHidden = false
        } else {
            badgeContainerView.isHidden = true
        }

        let hasRating: Bool
        if let rating = model.rating?.trimmingCharacters(in: .whitespacesAndNewlines), !rating.isEmpty {
            ratingLabel.text = rating
            ratingContainerView.isHidden = false
            hasRating = true
        } else {
            ratingContainerView.isHidden = true
            hasRating = false
        }

        let hasProgress: Bool
        if let progress = model.progressFraction, progress > 0.005 {
            let clamped = CGFloat(min(max(progress, 0.02), 1.0))
            progressTrackView.isHidden = false
            progressFillWidthConstraint?.isActive = false
            let next = progressFillView.widthAnchor.constraint(
                equalTo: progressTrackView.widthAnchor,
                multiplier: clamped
            )
            next.isActive = true
            progressFillWidthConstraint = next
            hasProgress = true
        } else {
            progressTrackView.isHidden = true
            hasProgress = false
        }

        bottomScrimLayer.isHidden = !(hasProgress || hasRating)

        // Instant editorial studio placeholder prevents gray boxes during load or missing artwork.
        let placeholder = PosterImageLoader.makeStudioPlaceholder(
            title: model.title,
            subtitle: model.subtitle,
            seed: model.id,
            aspectRatio: 2.0 / 3.0,
            includeText: false
        )
        posterImageView.image = placeholder

        let expectedID = model.id
        imageToken = PosterImageLoader.shared.loadImage(
            urlString: model.posterURL,
            headers: model.headers,
            isPrivate: model.isPrivate
        ) { [weak self] image in
            guard let self = self, self.currentModelID == expectedID, let image = image else { return }
            if UIAccessibility.isReduceMotionEnabled {
                self.posterImageView.image = image
            } else {
                UIView.transition(
                    with: self.posterImageView,
                    duration: 0.22,
                    options: [.transitionCrossDissolve, .allowUserInteraction],
                    animations: {
                        self.posterImageView.image = image
                    }
                )
            }
        }
    }

    /// Triggers subtle SF Symbol bounce feedback on the rating star icon.
    public func bounceRatingSymbol() {
        guard !ratingContainerView.isHidden else { return }
        MarcoSymbols.bounce(ratingStarView)
    }

    public override var isHighlighted: Bool {
        didSet {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            UIView.animate(
                withDuration: isHighlighted ? 0.14 : 0.28,
                delay: 0,
                usingSpringWithDamping: 0.76,
                initialSpringVelocity: 0.25,
                options: [.allowUserInteraction, .beginFromCurrentState],
                animations: {
                    self.shadowContainerView.transform = self.isHighlighted
                        ? CGAffineTransform(scaleX: 0.962, y: 0.962)
                        : .identity
                }
            )
        }
    }

    public func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        let preview = UITargetedPreview(view: posterContainerView)
        return UIPointerStyle(effect: .lift(preview))
    }
}

// MARK: - Widescreen 16:9 Landscape Card Cell (Hero / Continue Watching / Episodes)

/// 16:9 widescreen artwork card engineered for iPad cinema shelves, Continue Watching strips,
/// and multi-column 16:9 episode still grids.
public final class LandscapeCardCell: UICollectionViewCell, UIPointerInteractionDelegate {
    public static let reuseIdentifier = "LandscapeCardCell"

    private let shadowContainerView = UIView()
    private let artworkContainerView = UIView()
    private let artworkImageView = UIImageView()
    private let bottomScrimLayer = CAGradientLayer()

    private let badgeContainerView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let badgeLabel = UILabel()

    private let playGlyphContainer = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let playGlyphView = UIImageView()

    private let progressTrackView = UIView()
    private let progressFillView = UIView()
    private var progressFillWidthConstraint: NSLayoutConstraint?

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    private var imageToken: PosterImageLoadToken?
    private var currentModelID: String?

    public var zoomSourceView: UIView {
        artworkContainerView
    }

    /// Controls whether the understated bottom-right play glyph chip is displayed (ideal for episodes/continue watching).
    public var showsPlayGlyph: Bool = false {
        didSet {
            playGlyphContainer.isHidden = !showsPlayGlyph
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupHierarchy()
        addInteraction(UIPointerInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupHierarchy() {
        contentView.backgroundColor = .clear
        clipsToBounds = false
        contentView.clipsToBounds = false

        shadowContainerView.translatesAutoresizingMaskIntoConstraints = false
        shadowContainerView.backgroundColor = .clear
        shadowContainerView.layer.shadowColor = UIColor.black.cgColor
        shadowContainerView.layer.shadowOffset = CGSize(width: 0, height: 8)
        shadowContainerView.layer.shadowRadius = 16
        contentView.addSubview(shadowContainerView)

        artworkContainerView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainerView.backgroundColor = MarcoColors.posterPlaceholderBase
        artworkContainerView.applyContinuousCorners(MarcoRadii.card)
        shadowContainerView.addSubview(artworkContainerView)

        artworkImageView.translatesAutoresizingMaskIntoConstraints = false
        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.clipsToBounds = true
        artworkContainerView.addSubview(artworkImageView)

        bottomScrimLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.64).cgColor,
        ]
        bottomScrimLayer.locations = [0.42, 1.0]
        bottomScrimLayer.isHidden = true
        artworkContainerView.layer.addSublayer(bottomScrimLayer)

        badgeContainerView.translatesAutoresizingMaskIntoConstraints = false
        badgeContainerView.applyContinuousCorners(8)
        badgeContainerView.isHidden = true
        artworkContainerView.addSubview(badgeContainerView)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = MarcoTypography.badge
        badgeLabel.textColor = .white
        badgeLabel.lineBreakMode = .byTruncatingTail
        badgeContainerView.contentView.addSubview(badgeLabel)

        playGlyphContainer.translatesAutoresizingMaskIntoConstraints = false
        playGlyphContainer.applyContinuousCorners(16)
        playGlyphContainer.isHidden = true
        artworkContainerView.addSubview(playGlyphContainer)

        playGlyphView.translatesAutoresizingMaskIntoConstraints = false
        playGlyphView.image = MarcoSymbols.image("play.fill", pointSize: 12, weight: .semibold, hierarchicalColor: .white)
        playGlyphView.contentMode = .scaleAspectFit
        playGlyphContainer.contentView.addSubview(playGlyphView)

        progressTrackView.translatesAutoresizingMaskIntoConstraints = false
        progressTrackView.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        progressTrackView.applyContinuousCorners(2)
        progressTrackView.isHidden = true
        artworkContainerView.addSubview(progressTrackView)

        progressFillView.translatesAutoresizingMaskIntoConstraints = false
        progressFillView.backgroundColor = .white
        progressFillView.applyContinuousCorners(2)
        progressTrackView.addSubview(progressFillView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MarcoTypography.cardTitle
        titleLabel.textColor = MarcoColors.primaryText
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = MarcoTypography.cardSubtitle
        subtitleLabel.textColor = MarcoColors.secondaryText
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(subtitleLabel)

        let aspectConstraint = shadowContainerView.heightAnchor.constraint(
            equalTo: shadowContainerView.widthAnchor,
            multiplier: 9.0 / 16.0
        )
        aspectConstraint.priority = .defaultHigh

        let widthConstraint = progressFillView.widthAnchor.constraint(equalTo: progressTrackView.widthAnchor, multiplier: 0.01)
        progressFillWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            shadowContainerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            shadowContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            shadowContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            aspectConstraint,

            artworkContainerView.topAnchor.constraint(equalTo: shadowContainerView.topAnchor),
            artworkContainerView.leadingAnchor.constraint(equalTo: shadowContainerView.leadingAnchor),
            artworkContainerView.trailingAnchor.constraint(equalTo: shadowContainerView.trailingAnchor),
            artworkContainerView.bottomAnchor.constraint(equalTo: shadowContainerView.bottomAnchor),

            artworkImageView.topAnchor.constraint(equalTo: artworkContainerView.topAnchor),
            artworkImageView.leadingAnchor.constraint(equalTo: artworkContainerView.leadingAnchor),
            artworkImageView.trailingAnchor.constraint(equalTo: artworkContainerView.trailingAnchor),
            artworkImageView.bottomAnchor.constraint(equalTo: artworkContainerView.bottomAnchor),

            badgeContainerView.topAnchor.constraint(equalTo: artworkContainerView.topAnchor, constant: 10),
            badgeContainerView.trailingAnchor.constraint(equalTo: artworkContainerView.trailingAnchor, constant: -10),
            badgeContainerView.leadingAnchor.constraint(greaterThanOrEqualTo: artworkContainerView.leadingAnchor, constant: 10),

            badgeLabel.topAnchor.constraint(equalTo: badgeContainerView.contentView.topAnchor, constant: 3.5),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeContainerView.contentView.bottomAnchor, constant: -3.5),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainerView.contentView.leadingAnchor, constant: 7.5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainerView.contentView.trailingAnchor, constant: -7.5),

            playGlyphContainer.trailingAnchor.constraint(equalTo: artworkContainerView.trailingAnchor, constant: -10),
            playGlyphContainer.bottomAnchor.constraint(equalTo: progressTrackView.topAnchor, constant: -8),
            playGlyphContainer.widthAnchor.constraint(equalToConstant: 32),
            playGlyphContainer.heightAnchor.constraint(equalToConstant: 32),

            playGlyphView.centerXAnchor.constraint(equalTo: playGlyphContainer.contentView.centerXAnchor, constant: 1),
            playGlyphView.centerYAnchor.constraint(equalTo: playGlyphContainer.contentView.centerYAnchor),

            progressTrackView.leadingAnchor.constraint(equalTo: artworkContainerView.leadingAnchor, constant: 10),
            progressTrackView.trailingAnchor.constraint(equalTo: artworkContainerView.trailingAnchor, constant: -10),
            progressTrackView.bottomAnchor.constraint(equalTo: artworkContainerView.bottomAnchor, constant: -10),
            progressTrackView.heightAnchor.constraint(equalToConstant: 4),

            progressFillView.topAnchor.constraint(equalTo: progressTrackView.topAnchor),
            progressFillView.leadingAnchor.constraint(equalTo: progressTrackView.leadingAnchor),
            progressFillView.bottomAnchor.constraint(equalTo: progressTrackView.bottomAnchor),
            widthConstraint,

            titleLabel.topAnchor.constraint(equalTo: shadowContainerView.bottomAnchor, constant: 9),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])

        updateSurfaceStyle()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomScrimLayer.frame = artworkContainerView.bounds
        shadowContainerView.layer.shadowPath = UIBezierPath(
            roundedRect: shadowContainerView.bounds,
            cornerRadius: MarcoRadii.card
        ).cgPath
        CATransaction.commit()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateSurfaceStyle()
        }
    }

    private func updateSurfaceStyle() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        shadowContainerView.layer.shadowOpacity = isDark ? 0.36 : 0.13
        artworkContainerView.applyHairlineBorder(
            color: MarcoColors.hairlineBorder.resolvedColor(with: traitCollection)
        )
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        imageToken?.cancel()
        imageToken = nil
        currentModelID = nil
        artworkImageView.image = nil
        badgeContainerView.isHidden = true
        progressTrackView.isHidden = true
        bottomScrimLayer.isHidden = true
        showsPlayGlyph = false
        titleLabel.text = nil
        subtitleLabel.text = nil
    }

    public func configure(with model: PosterCardModel, showPlayGlyph: Bool = false) {
        imageToken?.cancel()
        imageToken = nil
        currentModelID = model.id
        showsPlayGlyph = showPlayGlyph

        titleLabel.text = model.title
        if let subtitle = model.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.text = nil
            subtitleLabel.isHidden = true
        }

        if let badge = model.badge?.trimmingCharacters(in: .whitespacesAndNewlines), !badge.isEmpty {
            badgeLabel.text = badge
            badgeContainerView.isHidden = false
        } else {
            badgeContainerView.isHidden = true
        }

        let hasProgress: Bool
        if let progress = model.progressFraction, progress > 0.005 {
            let clamped = CGFloat(min(max(progress, 0.02), 1.0))
            progressTrackView.isHidden = false
            progressFillWidthConstraint?.isActive = false
            let next = progressFillView.widthAnchor.constraint(
                equalTo: progressTrackView.widthAnchor,
                multiplier: clamped
            )
            next.isActive = true
            progressFillWidthConstraint = next
            hasProgress = true
        } else {
            progressTrackView.isHidden = true
            hasProgress = false
        }

        bottomScrimLayer.isHidden = !(hasProgress || showPlayGlyph)

        let placeholder = PosterImageLoader.makeStudioPlaceholder(
            title: model.title,
            subtitle: model.subtitle,
            seed: model.id,
            aspectRatio: 16.0 / 9.0,
            includeText: false
        )
        artworkImageView.image = placeholder

        let expectedID = model.id
        imageToken = PosterImageLoader.shared.loadImage(
            urlString: model.posterURL,
            headers: model.headers,
            isPrivate: model.isPrivate
        ) { [weak self] image in
            guard let self = self, self.currentModelID == expectedID, let image = image else { return }
            if UIAccessibility.isReduceMotionEnabled {
                self.artworkImageView.image = image
            } else {
                UIView.transition(
                    with: self.artworkImageView,
                    duration: 0.22,
                    options: [.transitionCrossDissolve, .allowUserInteraction],
                    animations: {
                        self.artworkImageView.image = image
                    }
                )
            }
        }
    }

    public func bouncePlayGlyph() {
        guard !playGlyphContainer.isHidden else { return }
        MarcoSymbols.bounce(playGlyphView)
    }

    public override var isHighlighted: Bool {
        didSet {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            UIView.animate(
                withDuration: isHighlighted ? 0.14 : 0.28,
                delay: 0,
                usingSpringWithDamping: 0.76,
                initialSpringVelocity: 0.25,
                options: [.allowUserInteraction, .beginFromCurrentState],
                animations: {
                    self.shadowContainerView.transform = self.isHighlighted
                        ? CGAffineTransform(scaleX: 0.968, y: 0.968)
                        : .identity
                }
            )
        }
    }

    public func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        let preview = UITargetedPreview(view: artworkContainerView)
        return UIPointerStyle(effect: .lift(preview))
    }
}

// MARK: - Apple TV+ Shelf Section Header

/// Editorial section header featuring bold title, optional subtitle, and "查看全部" chevron action button.
public final class ShelfHeaderReusableView: UICollectionReusableView, UIPointerInteractionDelegate {
    public static let reuseIdentifier = "ShelfHeaderReusableView"
    public static let elementKind = UICollectionView.elementKindSectionHeader

    private let titleStack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let actionButton = UIButton(type: .system)

    private var actionHandler: (() -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear

        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.axis = .vertical
        titleStack.spacing = 2
        titleStack.alignment = .leading
        addSubview(titleStack)

        titleLabel.font = MarcoTypography.sectionHeader
        titleLabel.textColor = MarcoColors.primaryText
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleStack.addArrangedSubview(titleLabel)

        subtitleLabel.font = MarcoTypography.cardSubtitle
        subtitleLabel.textColor = MarcoColors.secondaryText
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = true
        titleStack.addArrangedSubview(subtitleLabel)

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.isHidden = true
        actionButton.addTarget(self, action: #selector(handleActionTap), for: .touchUpInside)
        actionButton.addInteraction(UIPointerInteraction(delegate: self))
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -12),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        subtitleLabel.text = nil
        subtitleLabel.isHidden = true
        actionHandler = nil
        actionButton.isHidden = true
    }

    public func configure(
        title: String,
        subtitle: String? = nil,
        actionTitle: String = "查看全部",
        onAction: (() -> Void)? = nil
    ) {
        titleLabel.text = title
        if let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.text = nil
            subtitleLabel.isHidden = true
        }

        actionHandler = onAction
        actionButton.isHidden = (onAction == nil)
        if onAction != nil {
            configureActionButton(title: actionTitle)
        }
    }

    private func configureActionButton(title: String) {
        let chevron = MarcoSymbols.image(
            "chevron.right",
            pointSize: 12.5,
            weight: .semibold,
            hierarchicalColor: MarcoColors.secondaryText
        )

        if #available(iOS 15.0, *) {
            var cfg = UIButton.Configuration.plain()
            var attr = AttributedString(title)
            attr.font = MarcoTypography.cardSubtitle
            cfg.attributedTitle = attr
            cfg.image = chevron
            cfg.imagePlacement = .trailing
            cfg.imagePadding = 3
            cfg.baseForegroundColor = MarcoColors.secondaryText
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 2)
            actionButton.configuration = cfg
        } else {
            actionButton.setTitle(title, for: .normal)
            actionButton.setTitleColor(MarcoColors.secondaryText, for: .normal)
            actionButton.titleLabel?.font = MarcoTypography.cardSubtitle
            actionButton.setImage(chevron, for: .normal)
            actionButton.tintColor = MarcoColors.secondaryText
            actionButton.semanticContentAttribute = .forceRightToLeft
            actionButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 2)
            actionButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: -4)
        }
    }

    @objc private func handleActionTap() {
        MarcoHaptics.selection()
        actionHandler?()
    }

    public func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        let preview = UITargetedPreview(view: actionButton)
        return UIPointerStyle(effect: .highlight(preview))
    }
}
