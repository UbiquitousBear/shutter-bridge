#if canImport(SwiftUI) && canImport(UIKit) && canImport(ImageCaptureCore) && os(iOS)
import CameraTransport
import SwiftUI
import UIKit

/// The Browse screen (backlog section 6): the card newest first by day, with the last-known card from the catalogue
/// shown at once while the camera reads the live one; RAW, HEIF and *already imported* badges; filters (new only,
/// type, date); selection as in Photos (the title reports it, *Select All New* turns into *Deselect All*, Back is
/// hidden), with the count, size and Import in the system bottom toolbar; and press and hold a photo for *Copy as
/// JPEG* and *Share as JPEG…*. The link is held while the screen is up and let go when it goes (it closes unless an
/// import still uses it). Selecting ticks, and a JPEG copied or shared (or not) plays success or error (HIG Playing
/// haptics).
struct BrowseScreen: View {
    @State private var model: BrowseModel
    private let importer: ImportModel?
    private let showImport: @MainActor () -> Void
    /// Whether the Import sheet is up, so VoiceOver's focus can go back to the cell it was on when it closes.
    private let isImportShown: Bool
    @State private var showsFilters = false
    @AccessibilityFocusState private var focusedCell: CameraItem.ID?
    /// The cell VoiceOver was last on, restored when the Import sheet closes (HIG Accessibility > VoiceOver: return
    /// to a logical place after a modal view closes).
    @State private var lastFocusedCell: CameraItem.ID?
    /// The Wi-Fi connection's status, when the app has Wi-Fi (W16): its strip for this camera, and the Local Network
    /// explanation before the first connection, which begins as Browse opens a Wi-Fi camera.
    @Environment(WiFiImportModel.self) private var wifiStatus: WiFiImportModel?

    init(model: @autoclosure () -> BrowseModel, importer: ImportModel? = nil, isImportShown: Bool = false,
         showImport: @escaping @MainActor () -> Void = {}) {
        _model = State(initialValue: model())
        self.importer = importer
        self.isImportShown = isImportShown
        self.showImport = showImport
    }

    var body: some View {
        // Read here, not in the haptic's closure, so the closure captures a value rather than the main-actor model.
        let isSelecting = model.isSelecting
        content
            .navigationTitle(model.navigationTitle)
            .navigationSubtitle(model.navigationSubtitle)
            .navigationBarTitleDisplayMode(.inline)
            // Leaving would throw the selection away, so Back (and swipe-back) waits until Done.
            .navigationBarBackButtonHidden(model.isSelecting)
            .toolbar { toolbar }
            .safeAreaBar(edge: .top) {
                StatusStrips {
                    if let wifiStatus, wifiStatus.hasStatus(for: model.camera.id) {
                        JoinStatusView(status: wifiStatus)
                    }
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
            }
            .animation(.default, value: model.action)
            .animation(.default, value: model.importStatus)
            .animation(.default, value: model.isSelecting)
            .animation(.default, value: importer?.hasJob)
            .animation(.default, value: wifiStatus?.activityLine)
            .animation(.default, value: wifiStatus?.notes)
            .localNetworkExplanation(model.camera.carrier == .wifi ? wifiStatus : nil)
            // Ticks as files are picked, not when Done or Import ends selecting and clears the selection (as Photos).
            .sensoryFeedback(.selection, trigger: model.selection) { _, _ in isSelecting }
            .sensoryFeedback(trigger: model.action) { _, new in
                OutcomeFeedback.forJPEGAction(new)?.sensoryFeedback
            }
            .onChange(of: model.importStatus) { _, notice in notice?.announcement.post() }
            .onChange(of: model.actionNotice) { _, notice in notice?.announcement.post() }
            .onChange(of: focusedCell) { _, cell in
                if let cell { lastFocusedCell = cell }
            }
            .onChange(of: isImportShown) { wasShown, isShown in
                if wasShown, !isShown, let lastFocusedCell { focusedCell = lastFocusedCell }
            }
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

    /// The top bar: while selecting, *Select All New* or *Deselect All* where Back was; Filters and Select (or Done)
    /// as separate items, each added and removed whole (HIG Toolbars). While selecting, the bottom toolbar holds the
    /// selection's count and size and Import.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(model.allNewSelected ? BrowseWording.deselectAll : BrowseWording.selectAllNew) {
                    model.toggleSelectAllNew()
                }
                .disabled(!model.canToggleSelectAllNew)
            }
        }
        if model.hasFiles {
            ToolbarItem(placement: .topBarTrailing) {
                FiltersButton(isActive: model.filter.isActive) { showsFilters = true }
            }
        }
        if model.phase == .listed, model.hasFiles {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button(model.isSelecting ? BrowseWording.doneSelecting : BrowseWording.select) {
                    model.isSelecting.toggle()
                }
            }
        }
        if model.isSelecting {
            ToolbarItem(placement: .status) {
                Text(BrowseWording.selectionSummary(model.selectionSummary))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    importTapped()
                } label: {
                    if model.isStartingImport {
                        // Keeps the button's name for VoiceOver while Photos may be asking.
                        ProgressView()
                            .accessibilityLabel(BrowseWording.importAction)
                    } else {
                        Text(BrowseWording.importAction)
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!model.canImport)
            }
        }
    }

    /// Import in the bottom bar: hands the selection over, and opens the Import screen when a job started.
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
                ContentUnavailableView(BrowseWording.emptyCardTitle, systemImage: "sdcard",
                                       description: Text(BrowseWording.emptyCardDetail))
            }
        case .listsNoFiles:
            // The camera is connected, so not the unplugged cable of `.gone`: the mode needs changing, not the cable.
            ContentUnavailableView(BrowseWording.noFilesTitle, systemImage: "camera.badge.ellipsis",
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
                    LastKnownLine(mode: model.camera.mode, listedAt: listedAt, readingSince: readingSince)
                        .padding()
                }
                ContentUnavailableView {
                    Label(BrowseWording.noMatchesTitle, systemImage: "line.3.horizontal.decrease")
                } description: {
                    Text(BrowseWording.noMatchesDetail)
                } actions: {
                    Button(BrowseWording.clearFilters) { model.filter = .none }
                        .buttonStyle(.bordered)
                }
            }
        } else {
            CardGrid(model: model, readingSince: readingSince, focusedCell: $focusedCell)
        }
    }
}

/// Filters: a plain glyph (HIG Toolbars: no circle inside the glass circle). While a filter hides files it is drawn
/// prominent and VoiceOver hears "On", so hidden files aren't taken for missing ones (HIG Accessibility: don't show
/// state by visuals alone).
struct FiltersButton: View {
    let isActive: Bool
    let action: @MainActor () -> Void

    var body: some View {
        if isActive {
            button.buttonStyle(.glassProminent)
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            action()
        } label: {
            Label(BrowseWording.filters, systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityValue(BrowseWording.filtersValue(isActive: isActive))
    }
}

/// While the last-known card is shown: one line above the grid saying it is the card as it was, with the time the
/// live card has been read for; the bench's measured times are behind the info button (HIG Layout: content first;
/// one heading per group). "Reading the card…" is the bar's subtitle meanwhile.
struct LastKnownLine: View {
    let mode: CameraMode
    let listedAt: Date
    let readingSince: Date
    @State private var showsTimes = false

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(BrowseWording.lastKnownLine(listedAt.formatted(date: .abbreviated, time: .shortened)))
                    ElapsedText(since: readingSince)
                }
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button {
                showsTimes = true
            } label: {
                Label(BrowseWording.readingTimesButton, systemImage: "info.circle")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showsTimes) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(BrowseWording.readingTitle)
                        .font(.headline)
                    Text(BrowseWording.readingDetail(mode))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(idealWidth: 320, alignment: .leading)
                .padding()
                .presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// The filters (backlog section 6): new only, the types shown, and a range of whole days. They apply as they change,
/// so the sheet closes with the system close button, not Done, and Clear Filters sits in its bar (HIG Sheets).
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
            }
            .navigationTitle(BrowseWording.filters)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Clearing loses nothing, so no destructive role; in the bar, it is in reach at the medium detent.
                ToolbarItem(placement: .topBarLeading) {
                    Button(BrowseWording.clearFilters) { model.filter = .none }
                        .disabled(!model.filter.isActive)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
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
                ElapsedText(since: since)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// How long the card has been read for: the system's own timer counting up ("0:12 so far"), so it is written as the
/// person's region writes times and updates without a timeline of its own.
struct ElapsedText: View {
    let since: Date

    var body: some View {
        Text("\(Text(timerInterval: since ... Date.distantFuture, countsDown: false)) \(BrowseWording.elapsedSuffix)")
            .monospacedDigit()
    }
}

/// The card as a lazy grid with a pinned header per day, and the last-known note above it while the live card is
/// read. The cells grow with the text size, so their labels aren't clipped at the largest sizes.
struct CardGrid: View {
    let model: BrowseModel
    let readingSince: Date?
    let focusedCell: AccessibilityFocusState<CameraItem.ID?>.Binding
    @ScaledMetric(relativeTo: .caption2) private var cellMinimum: CGFloat = 104

    var body: some View {
        let minimum = min(cellMinimum, 240)
        let columns = [GridItem(.adaptive(minimum: minimum, maximum: minimum * 1.75), spacing: 2)]
        ScrollView {
            VStack(spacing: 0) {
                if let readingSince, let listedAt = model.lastKnownListedAt {
                    LastKnownLine(mode: model.camera.mode, listedAt: listedAt, readingSince: readingSince)
                        .padding(.leading)
                        .padding(.trailing, 8)
                        .padding(.vertical, 4)
                }
                LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                CardCell(item: item, model: model)
                                    .accessibilityFocused(focusedCell, equals: item.id)
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

/// A day's pinned header: the date on a small glass capsule at the leading edge, not a full-width bar band, so it
/// doesn't stack a second bar look under the glass navigation bar (HIG Materials > Liquid Glass); the capsule keeps it
/// readable over the thumbnails scrolling under it.
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One file: the camera's thumbnail (fetched when the cell appears, given up when it scrolls away), its badges (RAW,
/// HEIF, Imported), and, while selecting, its selection mark. It is a button, so a tap shows it was pressed: while
/// selecting it selects the file, otherwise it starts selecting with this file (`BrowseModel.tap(_:)`, until the
/// loupe exists); VoiceOver's default action does the same. A still of the live card offers the press-and-hold menu.
/// Video and other files are greyed out with no actions, and while selecting so are stills that can't be imported
/// (already imported, no capture date); VoiceOver's value says why.
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
        let picture = thumbnail
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
        let cell = Button {
            model.tap(item)
        } label: {
            picture
        }
        .buttonStyle(.plain)
        .task(id: item.id) {
            guard image == nil, let data = await model.thumbnail(for: item.id) else { return }
            image = UIImage(data: data)
        }
        .accessibilityLabel(model.accessibilityLabel(
            for: item, date: item.captureDate?.formatted(date: .abbreviated, time: .shortened)))
        .accessibilityValue(model.accessibilityValue(for: item) ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Video, other files, and stills that can't be selected now do nothing when tapped: not a button.
        .accessibilityRemoveTraits(model.respondsToTap(item) ? [] : .isButton)

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

/// The selection mark in a cell's corner while selecting, as Photos draws it: a white check on the accent colour in
/// the symbol's own palette layers, or a white ring, each with a soft shadow so it reads on light photos too (HIG SF
/// Symbols > rendering modes). The cell's accent ring stays (the proposal's mockups).
struct SelectionMark: View {
    let selected: Bool

    var body: some View {
        Group {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.accentColor)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(Color.white)
            }
        }
        .font(.title3)
        .shadow(color: .black.opacity(0.35), radius: 2)
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
/// visible above the share sheet. While the file is fetched a bar under the text shows how far (a circular
/// `ProgressView` ignores its value on iOS); otherwise a spinner (HIG Progress indicators).
struct ActionStrip: View {
    let model: BrowseModel

    var body: some View {
        switch model.action {
        case .idle:
            EmptyView()
        case let .working(work):
            HStack(alignment: .center, spacing: 12) {
                if work.fraction == nil {
                    ProgressView()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(work.statusLine)
                        .font(.subheadline)
                        .stripLineLimit()
                    if let fraction = work.fraction {
                        ProgressView(value: fraction)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // A large bordered button is at least 44 pt tall (HIG Buttons).
                Button(JPEGWording.cancel) { model.cancelAction() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(work.cancelling)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: stripShape)
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
