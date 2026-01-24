import SwiftUI

/// Unified right pane: stats header + projects + diary
struct RightPaneView: View {
    @Bindable var viewModel: DiaryViewModel
    @State private var showCopied = false
    @State private var sourceFilter: ActivitySource = .all

    var body: some View {
        VStack(spacing: 0) {
            // Sticky header with date and stats
            headerSection

            Divider()

            // Main content
            if viewModel.isLoadingInitial || viewModel.isLoadingDate {
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

            // Inline stats
            if let stats = viewModel.currentDayStatistics {
                HStack(spacing: 16) {
                    // Claude Code stats
                    HStack(spacing: 8) {
                        Image(systemName: ActivitySource.claudeCode.iconName)
                            .foregroundStyle(ActivitySource.claudeCode.color)
                            .font(.system(size: 11))
                        StatBadge(value: stats.projectCount, label: "projects")
                        StatBadge(value: stats.messageCount, label: "msgs")
                    }

                    // Cursor stats (if available)
                    if stats.hasCursorActivity {
                        Divider()
                            .frame(height: 16)

                        HStack(spacing: 8) {
                            Image(systemName: ActivitySource.cursor.iconName)
                                .foregroundStyle(ActivitySource.cursor.color)
                                .font(.system(size: 11))
                            StatBadge(value: stats.cursorTotalAccepted, label: "lines")
                        }
                    }
                }
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
            // Projects section (fixed height, no scroll)
            if let stats = viewModel.currentDayStatistics, !stats.projects.isEmpty {
                projectsSection(projects: stats.projects)
            }

            // Diary section (fills remaining space, WKWebView handles scroll)
            diarySection
        }
    }

    // MARK: - Projects Section

    private func projectsSection(projects: [ProjectSummary]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Badge flow layout for projects
            ProjectBadgesFlow(projects: projects)
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
        VStack(spacing: 16) {
            Spacer()
                .frame(height: 40)

            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)

            VStack(spacing: 4) {
                Text("No diary yet")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Generate from your activity")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            Button {
                Task {
                    await viewModel.generateDiary()
                }
            } label: {
                Label("Generate", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
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

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(projects) { project in
                ProjectBadge(project: project)
            }
        }
    }
}

struct ProjectBadge: View {
    let project: ProjectSummary

    var body: some View {
        HStack(spacing: 6) {
            // Project name
            Text(project.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            // Time range
            Text(project.formattedTimeRange)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            // Duration
            Text(project.formattedDuration)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
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

