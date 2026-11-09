#if canImport(SwiftUI) && canImport(UIKit) && canImport(ImageCaptureCore) && os(iOS)
import CameraTransport
import SwiftUI
import UIKit

/// The Browse screen (backlog section 6): the card newest first by day, with the last-known card from the catalogue
/// shown at once while the camera reads the live one; RAW, HEIF and *already imported* badges; filters (new only,
/// type, date); selection with *Select All New* and a sticky bar with the count, size and Import; and press and hold a
/// photo for *Copy as JPEG* and *Share as JPEG…*. The link is held while the screen is up and let go when it goes (it
/// closes unless an import still uses it).
struct BrowseScreen: View {
    @State private var model: BrowseModel
    private let importer: ImportModel?
    private let showImport: @MainActor () -> Void
    @State private var showsFilters = false

    init(model: @autoclosure () -> BrowseModel, importer: ImportModel? = nil,
         showImport: @escaping @MainActor () -> Void = {}) {
        _model = State(initialValue: model())
        self.importer = importer
        self.showImport = showImport
    }

    var body: some View {
        content
            .navigationTitle(CamerasWording.displayName(for: model.camera))
            .navigationSubtitle(CamerasWording.modeLine(model.camera.mode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    ActionStrip(model: model)
                    if let notice = model.importStatus {
                        NoticeStrip(notice: notice) {
                            if model.importStatus == notice { model.dismissImportNotice() }
                        }
                    }
                    if let importer, importer.hasJob {
                        ImportStatusStrip(importer: importer, action: showImport)
                    }
                }
                .padding(.horizontal)
            }
            .safeAreaInset(edge: .bottom) {
                if model.isSelecting {
                    SelectionBar(model: model, importTapped: { importTapped() })
                }
            }
            .animation(.default, value: model.action)
            .animation(.default, value: model.importStatus)
            .animation(.default, value: model.isSelecting)
            .onChange(of: model.importStatus) { _, notice in notice?.announcement.post() }
            .onChange(of: model.actionNotice) { _, notice in notice?.announcement.post() }
            .sheet(isPresented: $showsFilters) {
                BrowseFilterSheet(model: model)
                    .presentationDetents([.medium, .large])
            }
            .task { await model.run() }
            .onChange(of: model.share) { _, share in
                guard let share else { return }
                let model = self.model
                SharePresenter.present(fileAt: share.url,
                                       onFinish: { model.shareFinished() },
                                       onFailure: { model.shareFailed() })
            }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.hasFiles {
                Button {
                    showsFilters = true
                } label: {
                    Label(BrowseWording.filters,
                          systemImage: model.filter.isActive ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                }
            }
            if model.phase == .listed, model.hasFiles {
                Button(model.isSelecting ? BrowseWording.doneSelecting : BrowseWording.select) {
                    model.isSelecting.toggle()
                }
            }
        }
    }

    /// Import in the sticky bar: hands the selection over, and opens the Import screen when a job started.
    private func importTapped() {
        let model = self.model
        let showImport = self.showImport
        Task {
            let outcome = await model.importSelected()
            if case .started? = outcome { showImport() }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case let .reading(since):
            if model.lastKnownListedAt != nil {
                card(readingSince: since)
            } else {
                ReadingCardView(mode: model.camera.mode, since: since)
            }
        case .listed:
            if model.hasFiles {
                card(readingSince: nil)
            } else {
                ContentUnavailableView(BrowseWording.emptyCardTitle, systemImage: "photo.on.rectangle",
                                       description: Text(BrowseWording.emptyCardDetail))
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

    /// The card shown (live, or last-known while `readingSince` is set), or, when the filters hide every file, a line
    /// saying so with Clear Filters.
    @ViewBuilder private func card(readingSince: Date?) -> some View {
        if model.sections.isEmpty {
            VStack(spacing: 0) {
                if let readingSince, let listedAt = model.lastKnownListedAt {
                    LastKnownBanner(mode: model.camera.mode, listedAt: listedAt, readingSince: readingSince)
                        .padding()
                }
                ContentUnavailableView {
                    Label(BrowseWording.noMatchesTitle, systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(BrowseWording.noMatchesDetail)
                } actions: {
                    Button(BrowseWording.clearFilters) { model.filter = .none }
                        .buttonStyle(.bordered)
                }
            }
        } else {
            CardGrid(model: model, readingSince: readingSince)
        }
    }
}

/// While a job exists: its state in one line; tapping it opens the Import screen.
struct ImportStatusStrip: View {
    let importer: ImportModel
    let action: @MainActor () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "square.and.arrow.down")
                    .accessibilityHidden(true)
                Text(importer.statusLine ?? ImportWording.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(BrowseWording.showImport)
    }
}

/// The last-known card's note, above the grid while the camera reads the live card: when it was listed, that it
/// will be replaced, and the reading's measured times with the seconds so far.
struct LastKnownBanner: View {
    let mode: CameraMode
    let listedAt: Date
    let readingSince: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(BrowseWording.lastKnownTitle)
                    .font(.headline)
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            Text(BrowseWording.lastKnownListed(listedAt.formatted(date: .abbreviated, time: .shortened)))
            Text(BrowseWording.lastKnownDetail)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text(BrowseWording.readingTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(BrowseWording.readingDetail(mode))
                        .foregroundStyle(.secondary)
                    TimelineView(.periodic(from: readingSince, by: 1)) { context in
                        Text(BrowseWording.elapsed(seconds: Int(context.date.timeIntervalSince(readingSince))))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The sticky bar while selecting: *Select All New*, the count and size of the selection, and Import. Stacked at the
/// accessibility text sizes.
struct SelectionBar: View {
    let model: BrowseModel
    let importTapped: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            Button(BrowseWording.selectAllNew) { model.selectAllNew() }
            Text(BrowseWording.selectionSummary(model.selectionSummary))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .multilineTextAlignment(stacked ? .leading : .center)
                .frame(maxWidth: .infinity, alignment: stacked ? .leading : .center)
            Button {
                importTapped()
            } label: {
                if model.isStartingImport {
                    ProgressView()
                } else {
                    Text(BrowseWording.importAction)
                        .bold()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canImport)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

/// The filters (backlog section 6): new only, the types shown, and a range of whole days.
struct BrowseFilterSheet: View {
    @Bindable var model: BrowseModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(BrowseWording.newOnly, isOn: $model.filter.newOnly)
                }
                Section(BrowseWording.type) {
                    ForEach(BrowseFileType.allCases, id: \.self) { type in
                        let shown = model.filter.types.contains(type)
                        Button {
                            model.filter.toggle(type)
                        } label: {
                            HStack {
                                Text(BrowseWording.typeLabel(type))
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                if shown {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityAddTraits(shown ? .isSelected : [])
                    }
                }
                Section(BrowseWording.dateRange) {
                    if let days = model.dayBounds {
                        Toggle(BrowseWording.limitDates, isOn: $model.limitsDates)
                        if model.limitsDates {
                            DatePicker(BrowseWording.from, selection: $model.firstDay, in: days,
                                       displayedComponents: .date)
                            DatePicker(BrowseWording.to, selection: $model.lastDay, in: days,
                                       displayedComponents: .date)
                        }
                    } else {
                        Text(BrowseWording.noDatedFiles)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(BrowseWording.clearFilters, role: .destructive) { model.filter = .none }
                        .disabled(!model.filter.isActive)
                }
            }
            .navigationTitle(BrowseWording.filters)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(SettingsWording.done) { dismiss() }
                }
            }
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

/// The card as a lazy grid with a pinned header per day, and the last-known note above it while the live card is
/// read. The cells grow with the text size, so their labels aren't clipped at the largest sizes.
struct CardGrid: View {
    let model: BrowseModel
    let readingSince: Date?
    @ScaledMetric(relativeTo: .caption2) private var cellMinimum: CGFloat = 104

    var body: some View {
        let minimum = min(cellMinimum, 240)
        let columns = [GridItem(.adaptive(minimum: minimum, maximum: minimum * 1.75), spacing: 2)]
        ScrollView {
            VStack(spacing: 0) {
                if let readingSince, let listedAt = model.lastKnownListedAt {
                    LastKnownBanner(mode: model.camera.mode, listedAt: listedAt, readingSince: readingSince)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
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

/// One file: the camera's thumbnail (fetched when the cell appears, given up when it scrolls away), its badges (RAW,
/// HEIF, Imported), and, while selecting, its selection mark; tapping it then selects it. A still of the live card
/// offers the press-and-hold menu. Video and other files are greyed out with no actions, and while selecting so are
/// stills that can't be imported (already imported, no capture date).
struct CardCell: View {
    let item: CameraItem
    let model: BrowseModel
    @State private var image: UIImage?

    private var kind: CardCellKind { CardLayout.kind(of: item) }

    var body: some View {
        let selecting = model.isSelecting
        let selected = model.isSelected(item)
        let block = model.selectionBlock(for: item)
        let imported = model.isImported(item)
        // Only the picture is dimmed: the labels that explain a greyed-out cell stay readable (HIG Colour and
        // contrast).
        let cell = thumbnail
            .opacity(opacity(selecting: selecting, selectable: block == nil))
            .overlay(alignment: .topTrailing) { badge }
            .overlay(alignment: .bottomLeading) { label(imported: imported) }
            .overlay(alignment: .bottomTrailing) {
                if selecting, block == nil || selected {
                    SelectionMark(selected: selected)
                }
            }
            .overlay {
                if selected {
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if selecting { model.toggleSelection(item) }
            }
            .task(id: item.id) {
                guard image == nil, let data = await model.thumbnail(for: item.id) else { return }
                image = UIImage(data: data)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel(
                for: item, date: item.captureDate?.formatted(date: .abbreviated, time: .shortened)))
            .accessibilityHint(selecting ? (block.map { BrowseWording.notSelectable($0) } ?? "") : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAddTraits(selecting && block == nil ? .isButton : [])
            .accessibilityAction {
                if selecting { model.toggleSelection(item) }
            }

        if model.offersJPEGActions(item) {
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

    private func opacity(selecting: Bool, selectable: Bool) -> Double {
        if !kind.offersJPEGActions { return 0.45 }
        if selecting && !selectable { return 0.6 }
        return 1
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
            CellLabel(text: text)
        }
    }

    @ViewBuilder private func label(imported: Bool) -> some View {
        switch kind {
        case .video:
            CellLabel(text: BrowseWording.videoLabel)
        case .other:
            CellLabel(text: BrowseWording.otherLabel)
        case .photo:
            if imported {
                CellLabel(text: BrowseWording.importedBadge, systemImage: "checkmark.circle.fill")
            }
        }
    }
}

/// The selection mark in a cell's corner while selecting.
struct SelectionMark: View {
    let selected: Bool

    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? Color.accentColor : Color.white)
            .background(Circle().fill(selected ? Color.white : Color.black.opacity(0.25)).padding(2))
            .padding(6)
            .accessibilityHidden(true)
    }
}

/// A badge or label over a thumbnail (RAW, HEIF, Imported, "Video: from 1.1", "Not a photo"): white semibold text
/// on a dark capsule in both appearances, as Photos does, so it reads over any picture. Opaque with Increase Contrast
/// or Reduce Transparency. The text keeps the size the person chose (no scaling down).
struct CellLabel: View {
    let text: String
    var systemImage: String?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let opaque = contrast == .increased || reduceTransparency
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(2)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.black.opacity(opaque ? 1 : 0.55), in: Capsule())
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
                // A large bordered button is at least 44 pt tall (HIG Buttons).
                Button(JPEGWording.cancel) { model.cancelAction() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(work.cancelling)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .finished, .failed:
            // A confirmation closes itself (not while VoiceOver runs); an error stays until closed.
            if let notice = model.actionNotice {
                NoticeStrip(notice: notice) {
                    if model.actionNotice == notice { model.dismissMessage() }
                }
            }
        }
    }
}
#endif
