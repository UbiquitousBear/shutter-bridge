#if canImport(SwiftUI) && canImport(UIKit) && canImport(Accessibility) && canImport(CoreImage) && canImport(ImageIO) && canImport(CoreGraphics) && canImport(UniformTypeIdentifiers) && os(iOS)
import SwiftUI
import UIKit

/// The full-screen loupe (backlog section 7.3): one unit at a time, a RAW+JPEG pair shown by its JPG with one mark.
///
/// - Swipe left and right moves between units; swipe up keeps, swipe down rejects (`LoupeSwipe`); a Keep or Reject
///   moves on to the next unit. Keep and Reject are also buttons, with 0–5 optional stars between them and Undo in the
///   bar, which reverts the last mark and goes back to its unit.
/// - A pinch zooms up to the original's 100 % (`LoupeZoom`), a double tap goes there and back; while zoomed, a drag pans
///   and doesn't swipe. Past the screen-sized preview's own pixels, the region on screen is decoded from the original
///   when the pinch, the pan or the double tap ends (`CullLoupe.showDetail`) and drawn over the preview in its place.
/// - The preview comes from the prefetcher (the next 3 and the previous 1 decoded, evicted files downloaded further
///   ahead), with a progress bar while the unit's iCloud file downloads, and a line when a RAW shows only the camera's
///   embedded preview. A small EXIF line sits under the photo (D5).
/// - VoiceOver: the photo is one adjustable element (swipe up or down with one finger for the next or previous photo),
///   whose value is its position, mark and stars, and, while no preview shows, the download's progress, the failure or
///   the missing preview (`CullLoupe.spokenValue`, I17), with Next Photo, Previous Photo, Keep, Reject, Clear Mark, the
///   stars, Undo, the zoom and, after a failure, Try Again as actions; each mark is announced, and so is a preview that
///   couldn't be shown. The stars are one adjustable element too.
struct LoupeView: View {
    let loupe: CullLoupe<DecodedPreviewImage>
    let close: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var zoom: Double = 1
    @State private var pinchStart: Double?
    @State private var offset: CGSize = .zero
    @State private var panStart: CGSize?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                photo(in: proxy.size)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .background(Color.black)
            .navigationTitle(loupe.position)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close, action: close)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        loupe.undo()
                    } label: {
                        Label(CullWording.undo, systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!loupe.session.canUndo)
                }
            }
            .safeAreaInset(edge: .top) {
                if let notice = loupe.writeFailureNotice {
                    NoticeStrip(notice: notice) { loupe.dismissWriteFailure() }
                        .padding(.horizontal)
                }
            }
            .safeAreaInset(edge: .bottom) {
                controls
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: loupe.announcement) { _, new in new?.announcement.post() }
        .onChange(of: loupe.writeFailureNotice) { _, notice in notice?.announcement.post() }
        .onChange(of: loupe.session.index) { _, _ in resetZoom() }
        // The failure's Try Again is inside the photo's one element, out of VoiceOver's reach but for the action, so
        // the failure is said.
        .onChange(of: loupe.previewFailed) { _, failed in
            if failed { StatusAnnouncement(CullWording.previewFailedTitle).post() }
        }
    }

    // MARK: The photo

    @ViewBuilder private func photo(in size: CGSize) -> some View {
        ZStack {
            if let preview = loupe.preview {
                Image(decorative: preview.image.cgImage, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        // The region decoded from the original, over the same part of the preview, scaled with it.
                        if zoom > 1, let detail = loupe.detail, detail.unit == loupe.current?.id {
                            GeometryReader { fitted in
                                let region = detail.region
                                let (width, height) = (fitted.size.width, fitted.size.height)
                                Image(decorative: detail.preview.image.cgImage, scale: 1)
                                    .resizable()
                                    .frame(width: width * CGFloat(region.width), height: height * CGFloat(region.height))
                                    .position(x: width * CGFloat(region.x + region.width / 2),
                                              y: height * CGFloat(region.y + region.height / 2))
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .scaleEffect(zoom)
                    .offset(offset)
            } else if loupe.hasNoPreview {
                Text(CullWording.noPreview)
                    .foregroundStyle(.secondary)
            } else if loupe.previewFailed {
                ContentUnavailableView {
                    Label(CullWording.previewFailedTitle, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(CullWording.previewFailedDetail)
                } actions: {
                    Button(CullWording.tryAgain) { loupe.retryPreview() }
                        .buttonStyle(.bordered)
                }
            } else if let download = loupe.download {
                Group {
                    if let fraction = download.fraction {
                        ProgressView(value: fraction) { Text(CullWording.downloading) }
                    } else {
                        ProgressView { Text(CullWording.downloading) }
                    }
                }
                .padding(.horizontal, 48)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if let unit = loupe.current, let badge = CullWording.pairBadge(unit) {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: Capsule())
                    .padding()
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .gesture(drag(in: size))
        .simultaneousGesture(pinch(in: size))
        .onTapGesture(count: 2) { toggleZoom(in: size) }
        // A RAW's render replacing its stand-in brings the original's size: decode the region if zoomed in past it.
        .onChange(of: loupe.preview?.fullPixelSize) { _, _ in updateDetail(in: size) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loupe.accessibilityLabel)
        .accessibilityValue(loupe.spokenValue)
        .accessibilityHint(CullWording.loupeHint)
        .accessibilityAddTraits(.isImage)
        .accessibilityAdjustableAction { direction in
            if direction == .increment {
                loupe.next()
            } else if direction == .decrement {
                loupe.previous()
            }
        }
        .accessibilityActions {
            Button(CullWording.nextPhoto) { loupe.next() }
            Button(CullWording.previousPhoto) { loupe.previous() }
            Button(CullWording.keep) { loupe.keep() }
            Button(CullWording.reject) { loupe.reject() }
            Button(CullWording.clearMark) { loupe.clearDecision() }
            ForEach(Array(CullMark.ratingRange), id: \.self) { rating in
                Button(CullWording.rateAction(rating)) { loupe.setRating(rating) }
            }
            Button(CullWording.undo) { loupe.undo() }
            if loupe.previewFailed {
                Button(CullWording.tryAgain) { loupe.retryPreview() }
            }
            if let preview = loupe.preview {
                Button(zoom > 1 ? CullWording.zoomOut
                    : preview.fullPixelSize != nil ? CullWording.zoomIn : CullWording.zoomInPreview) {
                    toggleZoom(in: size)
                }
            }
        }
    }

    /// Swipes while the photo fits the screen; pans while it is zoomed in.
    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard zoom > 1 else { return }
                let start = panStart ?? offset
                if panStart == nil { panStart = offset }
                offset = CGSize(width: start.width + value.translation.width,
                                height: start.height + value.translation.height)
            }
            .onEnded { value in
                guard zoom <= 1 else {
                    panStart = nil
                    updateDetail(in: size)
                    return
                }
                let swipe = LoupeSwipe.of(translationX: value.translation.width,
                                          translationY: value.translation.height,
                                          predictedX: value.predictedEndTranslation.width,
                                          predictedY: value.predictedEndTranslation.height)
                switch swipe {
                case .next?: loupe.next()
                case .previous?: loupe.previous()
                case .keep?: loupe.keep()
                case .reject?: loupe.reject()
                case nil: break
                }
            }
    }

    private func pinch(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? zoom
                if pinchStart == nil { pinchStart = zoom }
                zoom = LoupeZoom.clamped(start * Double(value.magnification), maximum: maximumZoom(in: size))
            }
            .onEnded { _ in
                pinchStart = nil
                if zoom <= 1.01 { resetZoom() }
                updateDetail(in: size)
            }
    }

    /// The original's 100 % (or the preview's, when the original's pixels can't be decoded).
    private func maximumZoom(in size: CGSize) -> Double {
        LoupeZoom.maximumScale(for: loupe.preview, fittingWidth: size.width, fittingHeight: size.height,
                               displayScale: displayScale)
    }

    /// Asks for the region on screen from the original when zoomed in past the preview's own pixels, or drops it.
    private func updateDetail(in size: CGSize) {
        let region = LoupeZoom.detailRegion(for: loupe.preview, scale: zoom, offsetX: Double(offset.width),
                                            offsetY: Double(offset.height), fittingWidth: Double(size.width),
                                            fittingHeight: Double(size.height), displayScale: Double(displayScale))
        guard let region else {
            loupe.clearDetail()
            return
        }
        let side = max(size.width, size.height) * displayScale
        loupe.showDetail(region, maxPixelSize: side > 0 ? Int(side.rounded(.up)) : 2_800)
    }

    private func toggleZoom(in size: CGSize) {
        withAnimation(.snappy) {
            if zoom > 1 {
                zoom = 1
                offset = .zero
            } else {
                zoom = maximumZoom(in: size)
            }
        }
        updateDetail(in: size)
    }

    private func resetZoom() {
        zoom = 1
        offset = .zero
        pinchStart = nil
        panStart = nil
        loupe.clearDetail()
    }

    // MARK: The controls

    private var controls: some View {
        let mark = loupe.currentMark
        return VStack(spacing: 10) {
            if let line = loupe.exif?.line {
                Text(line)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            if loupe.preview?.quality == .embeddedOnly {
                Text(CullWording.embeddedOnly)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            LoupeStars(rating: mark.rating) { loupe.setRating($0) }
            HStack(spacing: 12) {
                Button {
                    loupe.reject()
                } label: {
                    Label(CullWording.reject, systemImage: "xmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(mark.decision == .reject ? Color.red : Color.secondary)
                .accessibilityValue(mark.decision == .reject ? CullWording.decisionWord(.reject) : "")

                Button {
                    loupe.keep()
                } label: {
                    Label(CullWording.keep, systemImage: "checkmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(mark.decision == .keep ? Color.green : Color.secondary)
                .accessibilityValue(mark.decision == .keep ? CullWording.decisionWord(.keep) : "")
            }
        }
        .padding()
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 4)
    }
}

/// Five stars, any of which sets that many; tapping the current number takes them all off. VoiceOver reads the row as
/// one adjustable element ("Stars, 3 stars").
private struct LoupeStars: View {
    let rating: Int
    let rate: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(1 ... CullMark.ratingRange.upperBound), id: \.self) { star in
                Button {
                    rate(star == rating ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .tint(Color.yellow)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CullWording.ratingTitle)
        .accessibilityValue(CullWording.stars(rating))
        .accessibilityAdjustableAction { direction in
            if direction == .increment {
                rate(min(rating + 1, CullMark.ratingRange.upperBound))
            } else if direction == .decrement {
                rate(max(rating - 1, CullMark.ratingRange.lowerBound))
            }
        }
    }
}
#endif
