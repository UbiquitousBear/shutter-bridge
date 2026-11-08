#if canImport(SwiftUI) && canImport(UIKit) && canImport(ImageCaptureCore) && os(iOS)
import CameraTransport
import SwiftUI
import UIKit

/// The thin Browse screen (backlog section 6, *Order*): the card newest first by day, and press and hold a photo for
/// *Copy as JPEG* and *Share as JPEG…*. The link opens when the screen appears and closes when it goes.
struct BrowseScreen: View {
    @State private var model: BrowseModel

    init(model: @autoclosure () -> BrowseModel) {
        _model = State(initialValue: model())
    }

    var body: some View {
        content
            .navigationTitle(model.camera.name)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                ActionStrip(model: model)
                    .padding(.horizontal)
            }
            .animation(.default, value: model.action)
            .task { await model.run() }
            .onChange(of: model.share) { _, share in
                guard let share else { return }
                let model = self.model
                SharePresenter.present(fileAt: share.url,
                                       onFinish: { model.shareFinished() },
                                       onFailure: { model.shareFailed() })
            }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case let .reading(since):
            ReadingCardView(mode: model.camera.mode, since: since)
        case .listed:
            if model.sections.isEmpty {
                ContentUnavailableView(BrowseWording.emptyCardTitle, systemImage: "photo.on.rectangle",
                                       description: Text(BrowseWording.emptyCardDetail))
            } else {
                CardGrid(model: model)
            }
        case .listsNoFiles:
            ContentUnavailableView(BrowseWording.noFilesTitle, systemImage: "cable.connector.slash",
                                   description: Text(BrowseWording.noFilesDetail))
        case let .failed(message):
            ContentUnavailableView {
                Label(BrowseWording.listingFailedTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if model.canRetry {
                    Button(BrowseWording.tryAgain) { model.retry() }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .gone:
            ContentUnavailableView(BrowseWording.goneTitle, systemImage: "cable.connector.slash",
                                   description: Text(BrowseWording.goneDetail))
        }
    }
}

/// While ImageCaptureCore reads the card: what to expect, from the bench's measurements, and the time so far.
struct ReadingCardView: View {
    let mode: CameraMode
    let since: Date

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(BrowseWording.readingTitle)
            } icon: {
                ProgressView()
                    .controlSize(.large)
            }
        } description: {
            VStack(spacing: 8) {
                Text(BrowseWording.readingDetail(mode))
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(BrowseWording.elapsed(seconds: Int(context.date.timeIntervalSince(since))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The card as a lazy grid with a pinned header per day.
struct CardGrid: View {
    let model: BrowseModel

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            CardCell(item: item, model: model)
                        }
                    } header: {
                        DayHeader(day: section.day)
                    }
                }
            }
        }
    }
}

struct DayHeader: View {
    let day: Date?

    var body: some View {
        Group {
            if let day {
                Text(day, format: .dateTime.weekday(.wide).day().month(.wide).year())
            } else {
                Text(BrowseWording.undatedHeader)
            }
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One file: the camera's thumbnail (fetched when the cell appears, given up when it scrolls away), its badge, and
/// for a still the press-and-hold menu. Video and other files are greyed out with no actions.
struct CardCell: View {
    let item: CameraItem
    let model: BrowseModel
    @State private var image: UIImage?

    private var kind: CardCellKind { CardLayout.kind(of: item) }

    var body: some View {
        let cell = thumbnail
            .overlay(alignment: .topTrailing) { badge }
            .overlay(alignment: .bottomLeading) { label }
            .opacity(kind.offersJPEGActions ? 1 : 0.45)
            .task(id: item.id) {
                guard image == nil, let data = await model.thumbnail(for: item.id) else { return }
                image = UIImage(data: data)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)

        if kind.offersJPEGActions {
            cell
                .contextMenu {
                    Button {
                        model.copyAsJPEG(item)
                    } label: {
                        Label(JPEGWording.copyAction, systemImage: "doc.on.doc")
                    }
                    .disabled(model.isBusy)
                    Button {
                        model.shareAsJPEG(item)
                    } label: {
                        Label(JPEGWording.shareAction, systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.isBusy)
                } preview: {
                    CellPreview(item: item, image: image)
                }
                .accessibilityAction(named: JPEGWording.copyAction) { model.copyAsJPEG(item) }
                .accessibilityAction(named: JPEGWording.shareAction) { model.shareAsJPEG(item) }
        } else {
            cell
        }
    }

    private var thumbnail: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if kind == .video {
                    Image(systemName: "video")
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
    }

    @ViewBuilder private var badge: some View {
        if case let .photo(text?) = kind {
            Text(text)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(4)
        }
    }

    @ViewBuilder private var label: some View {
        switch kind {
        case .video: CellLabel(text: BrowseWording.videoLabel)
        case .other: CellLabel(text: BrowseWording.otherLabel)
        case .photo: EmptyView()
        }
    }

    private var accessibilityText: String {
        var parts = [item.name]
        if let date = item.captureDate {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        switch kind {
        case let .photo(badge): if let badge { parts.append(badge) }
        case .video: parts.append(BrowseWording.videoLabel)
        case .other: parts.append(BrowseWording.otherLabel)
        }
        return parts.joined(separator: ", ")
    }
}

struct CellLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(4)
    }
}

/// The context menu's preview: the camera's thumbnail, larger, with the file's name and date. The camera's
/// thumbnail is all the phone has before the file is fetched, so it is shown at its own size or a little above.
struct CellPreview: View {
    let item: CameraItem
    let image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .aspectRatio(4 / 3, contentMode: .fit)
                }
            }
            .frame(width: 320)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.headline)
                if let date = item.captureDate {
                    Text(date, format: .dateTime.day().month().year().hour().minute().second())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: 320)
    }
}

/// The action's progress with Cancel, then its confirmation or error, at the top of the screen so it stays
/// visible above the share sheet.
struct ActionStrip: View {
    let model: BrowseModel

    var body: some View {
        switch model.action {
        case .idle:
            EmptyView()
        case let .working(work):
            HStack(spacing: 12) {
                if let fraction = work.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                } else {
                    ProgressView()
                }
                Text(work.statusLine)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(JPEGWording.cancel) { model.cancelAction() }
                    .disabled(work.cancelling)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case let .finished(message):
            NoticeStrip(text: message, systemImage: "checkmark.circle") { model.dismissMessage() }
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(5))
                    if case .finished(message) = model.action { model.dismissMessage() }
                }
        case let .failed(message):
            NoticeStrip(text: message, systemImage: "exclamationmark.triangle") { model.dismissMessage() }
        }
    }
}
#endif
