import SwiftUI
import AppKit

/// Unified right pane: stats header + projects + diary
struct RightPaneView: View {
    @Bindable var viewModel: DiaryViewModel
    @State private var showCopied = false

    // App icons (loaded once)
    private let claudeIcon = AppIconHelper.icon(for: "Claude")
    private let cursorIcon = AppIconHelper.icon(for: "Cursor")

    // Show header only when diary exists or no activity
    private var shouldShowHeader: Bool {
        viewModel.currentDiary != nil || viewModel.currentDayStatistics == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sticky header with date and stats (hide for pre-generation view)
            if shouldShowHeader {
                headerSection
                Divider()
            }

            // Main content (don't show loading during index building - overlay handles that)
            if viewModel.isLoadingDate && !viewModel.isBuildingIndex {
                loadingView
            } else {
                mainScrollContent
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Header (sticky)

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 16) {
            // Date
            Text(formattedDate)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            // Inline stats (split by source)
            if let stats = viewModel.currentDayStatistics {
                HStack(spacing: 16) {
                    // Claude Code stats
                    if stats.ccProjectCount > 0 {
                        HStack(spacing: 8) {
                            Image(nsImage: claudeIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 20, height: 20)
                            StatBadge(value: stats.ccProjectCount, label: "proj")
                            StatBadge(value: stats.ccSessionCount, label: "sess")
                            StatBadge(value: stats.ccMessageCount, label: "msgs")
                        }
                    }

                    // Cursor stats
                    if stats.cursorProjectCount > 0 {
                        HStack(spacing: 8) {
                            Image(nsImage: cursorIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 20, height: 20)
                            StatBadge(value: stats.cursorProjectCount, label: "proj")
                            StatBadge(value: stats.cursorSessionCount, label: "sess")
                            StatBadge(value: stats.cursorMessageCount, label: "msgs")
                        }
                    }
                }
            }

            // Regenerate button
            if viewModel.currentDiary != nil {
                Button {
                    Task {
                        await viewModel.generateDiary()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Regenerate diary")
            }

            // Copy button
            if viewModel.currentDiary != nil {
                Button {
                    copyToClipboard()
                } label: {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Copy diary to clipboard")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    // MARK: - Main Content

    private var mainScrollContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Projects badges (only show when diary exists)
            if viewModel.currentDiary != nil,
               let stats = viewModel.currentDayStatistics, !stats.projects.isEmpty {
                projectsSection(projects: stats.projects)
            }

            // Diary section (fills remaining space, WKWebView handles scroll)
            diarySection
        }
    }

    // MARK: - Projects Section

    private func projectsSection(projects: [ProjectSummary]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Badge flow layout for projects with selection
            ProjectBadgesFlow(projects: projects, viewModel: viewModel)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()
        }
    }

    // MARK: - Diary Section

    @ViewBuilder
    private var diarySection: some View {
        if let diary = viewModel.currentDiary {
            // Diary content (WKWebView handles its own scrolling)
            MarkdownWebView(markdown: diary.markdown)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.currentDayStatistics != nil {
            // Has activity but no diary
            generatePrompt
        } else {
            // No activity
            noActivityView
        }
    }

    // MARK: - Generate Prompt

    private var generatePrompt: some View {
        ActivityReportView(viewModel: viewModel)
    }

    // MARK: - No Activity View

    private var noActivityView: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "moon.zzz")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)

            Text("No activity")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Loading...")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Generating View

    // MARK: - Helpers

    private var formattedDate: String {
        DateFormatting.japaneseDateWithWeekday.string(from: viewModel.selectedDate)
    }

    private func copyToClipboard() {
        guard let diary = viewModel.currentDiary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diary.markdown, forType: .string)

        showCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopied = false
        }
    }
}

// MARK: - Project Badges Flow

struct ProjectBadgesFlow: View {
    let projects: [ProjectSummary]
    @Bindable var viewModel: DiaryViewModel

    private var hasMultipleSources: Bool {
        let sources = Set(projects.map { $0.source })
        return sources.count > 1
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(projects) { project in
                ProjectBadge(
                    project: project,
                    showIcon: hasMultipleSources,
                    isSelected: viewModel.selectedProjects.contains(project.path),
                    onToggle: {
                        if viewModel.selectedProjects.contains(project.path) {
                            viewModel.selectedProjects.remove(project.path)
                        } else {
                            viewModel.selectedProjects.insert(project.path)
                        }
                    }
                )
            }
        }
    }
}

struct ProjectBadge: View {
    let project: ProjectSummary
    var showIcon: Bool = true
    var isSelected: Bool = true
    var onToggle: (() -> Void)? = nil

    private var appIcon: NSImage {
        switch project.source {
        case .claudeCode:
            return AppIconHelper.icon(for: "Claude")
        case .cursor:
            return AppIconHelper.icon(for: "Cursor")
        case .all:
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Checkbox
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))

            // App icon (only show when multiple sources exist)
            if showIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
            }

            // Project name
            Text(project.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)

            // Time range
            Text(project.formattedTimeRange)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isSelected ? .secondary : .tertiary)

            // Duration
            Text(project.formattedDuration)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? Color.primary.opacity(0.06) : Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle?()
        }
    }
}

// MARK: - Activity Report View (Pre-generation)

struct ActivityReportView: View {
    @Bindable var viewModel: DiaryViewModel

    private var stats: DayStatistics? { viewModel.currentDayStatistics }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack {
                    Spacer(minLength: 0)

                    // Report container
                    VStack(spacing: 24) {
                        // Header: Date & Label
                        reportHeader

                        // Stats summary
                        if let stats = stats {
                            statsSummary(stats: stats)
                        }

                        // Divider
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 1)
                            .padding(.horizontal, 8)

                        // Project selection
                        if let stats = stats, !stats.projects.isEmpty {
                            projectSection(stats: stats)
                        }

                        // Generate button
                        generateButton
                    }
                    .padding(28)
                    .frame(maxWidth: 420)
                    .background {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.08), radius: 20, y: 8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                            )
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }

    // MARK: - Report Header

    private var reportHeader: some View {
        VStack(spacing: 6) {
            // Small label
            Text("ACTIVITY REPORT")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(.secondary)

            // Date
            Text(DateFormatting.japaneseDateWithWeekday.string(from: viewModel.selectedDate))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Stats Summary

    private func statsSummary(stats: DayStatistics) -> some View {
        HStack(spacing: 0) {
            statItem(
                value: stats.projectCount,
                label: "Projects",
                icon: "folder.fill"
            )

            Divider()
                .frame(height: 32)

            statItem(
                value: stats.sessionCount,
                label: "Sessions",
                icon: "bubble.left.and.bubble.right.fill"
            )

            Divider()
                .frame(height: 32)

            statItem(
                value: stats.messageCount,
                label: "Messages",
                icon: "text.bubble.fill"
            )
        }
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func statItem(value: Int, label: String, icon: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("\(value)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Project Section

    private func projectSection(stats: DayStatistics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack {
                Text("Include in diary")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if viewModel.selectedProjects.count == stats.projects.count {
                            viewModel.selectedProjects.removeAll()
                        } else {
                            viewModel.selectedProjects = Set(stats.projects.map { $0.path })
                        }
                    }
                } label: {
                    Text(viewModel.selectedProjects.count == stats.projects.count ? "None" : "All")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }

            // Project list
            VStack(spacing: 2) {
                ForEach(stats.projects) { project in
                    ReportProjectRow(
                        project: project,
                        isSelected: viewModel.selectedProjects.contains(project.path),
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if viewModel.selectedProjects.contains(project.path) {
                                    viewModel.selectedProjects.remove(project.path)
                                } else {
                                    viewModel.selectedProjects.insert(project.path)
                                }
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Generate Button

    private var generateButton: some View {
        Button {
            Task {
                await viewModel.generateDiary()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                Text("Generate Diary")
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(viewModel.selectedProjects.isEmpty
                          ? Color.accentColor.opacity(0.3)
                          : Color.accentColor)
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.selectedProjects.isEmpty)
    }
}

// MARK: - Report Project Row

struct ReportProjectRow: View {
    let project: ProjectSummary
    let isSelected: Bool
    let onToggle: () -> Void

    private var appIcon: NSImage {
        switch project.source {
        case .claudeCode:
            return AppIconHelper.icon(for: "Claude")
        case .cursor:
            return AppIconHelper.icon(for: "Cursor")
        case .all:
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Checkbox
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(width: 18, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isSelected ? Color.clear : Color.primary.opacity(0.2), lineWidth: 1.5)
                    )

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }

            // App icon
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .opacity(isSelected ? 1 : 0.5)

            // Project info
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)

                Text(project.formattedTimeRange)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Duration badge
            Text(project.formattedDuration)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
    }
}

// MARK: - Project Selection List

struct ProjectSelectionList: View {
    let projects: [ProjectSummary]
    @Bindable var viewModel: DiaryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(projects) { project in
                ProjectSelectionRow(
                    project: project,
                    isSelected: viewModel.selectedProjects.contains(project.path),
                    onToggle: {
                        if viewModel.selectedProjects.contains(project.path) {
                            viewModel.selectedProjects.remove(project.path)
                        } else {
                            viewModel.selectedProjects.insert(project.path)
                        }
                    }
                )
            }
        }
    }
}

struct ProjectSelectionRow: View {
    let project: ProjectSummary
    let isSelected: Bool
    let onToggle: () -> Void

    private var appIcon: NSImage {
        switch project.source {
        case .claudeCode:
            return AppIconHelper.icon(for: "Claude")
        case .cursor:
            return AppIconHelper.icon(for: "Cursor")
        case .all:
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Checkbox
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)

            // App icon
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)

            // Project name
            Text(project.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)

            Spacer()

            // Time range
            Text(project.formattedTimeRange)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)

            // Duration
            Text(project.formattedDuration)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
            totalHeight = currentY + lineHeight
        }

        return (CGSize(width: totalWidth, height: totalHeight), positions)
    }
}

// MARK: - Stat Badge (shared)

struct StatBadge: View {
    let value: Int
    let label: String
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(compact ? formatCompact(value) : "\(value)")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    private func formatCompact(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }
}

// MARK: - App Icon Helper

enum AppIconHelper {
    /// Get app icon from /Applications or fallback to asset catalog
    static func icon(for appName: String) -> NSImage {
        let paths = [
            "/Applications/\(appName).app",
            "/System/Applications/\(appName).app",
            NSHomeDirectory() + "/Applications/\(appName).app"
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }

        // Fallback to asset catalog icon
        if let assetIcon = NSImage(named: "\(appName)Icon") {
            return assetIcon
        }

        // Last resort: generic app icon
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
