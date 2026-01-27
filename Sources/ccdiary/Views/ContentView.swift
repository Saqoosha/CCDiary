import SwiftUI
import AppKit

// MARK: - FocusedValue for menu access

struct DiaryViewModelKey: FocusedValueKey {
    typealias Value = DiaryViewModel
}

extension FocusedValues {
    var diaryViewModel: DiaryViewModel? {
        get { self[DiaryViewModelKey.self] }
        set { self[DiaryViewModelKey.self] = newValue }
    }
}

struct ContentView: View {
    @State private var viewModel = DiaryViewModel()

    var body: some View {
        HSplitView {
            // Left: Calendar
            CalendarGridView(
                selectedDate: $viewModel.selectedDate,
                datesWithActivity: viewModel.datesWithActivity,
                datesWithDiary: viewModel.datesWithDiary
            )
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)

            // Right: Unified stats + diary pane
            RightPaneView(viewModel: viewModel)
        }
        .navigationTitle("ccdiary")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .focusedSceneValue(\.diaryViewModel, viewModel)
        .task {
            await viewModel.loadInitialData()
        }
        .onChange(of: viewModel.selectedDate) { _, newDate in
            // Don't load during initial data loading (will be loaded at the end)
            guard !viewModel.isLoadingInitial else { return }
            Task {
                await viewModel.loadDataForDate(newDate)
            }
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") { }
        } message: {
            Text(viewModel.errorMessage)
        }
        .alert("Complete", isPresented: $viewModel.showSuccess) {
            Button("OK") { }
        } message: {
            Text(viewModel.successMessage)
        }
        .alert("Cursor Access Required", isPresented: $viewModel.showCursorPermissionAlert) {
            Button("Open System Settings") {
                viewModel.openFullDiskAccessSettings()
            }
            Button("Ignore", role: .cancel) { }
        } message: {
            Text("ccdiary needs Full Disk Access to read Cursor activity data.\n\nPlease add ccdiary to Full Disk Access in System Settings, then restart the app.")
        }
        .overlay {
            if viewModel.isBuildingIndex || viewModel.isGenerating {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text(viewModel.isBuildingIndex ? viewModel.indexBuildProgress : viewModel.generationProgress)
                            .font(.headline)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .ignoresSafeArea()
            }
        }
    }
}

// MARK: - View Model

@Observable
@MainActor
final class DiaryViewModel {
    // Calendar data
    var datesWithActivity: Set<String> = []
    var datesWithDiary: Set<String> = []
    var selectedDate: Date = Date()

    // Current day data
    var currentDayStatistics: DayStatistics?
    var currentDiary: DiaryEntry?

    // Project selection for diary generation (paths of selected projects)
    var selectedProjects: Set<String> = []

    // Loading states
    var isLoadingInitial = false
    var isLoadingDate = false
    var isBuildingIndex = false
    var indexBuildProgress = ""
    private var lastLoadedDateString: String = ""

    // Generation state
    var isGenerating = false
    var generationProgress = ""

    // Error handling
    var showError = false
    var errorMessage = ""
    var showSuccess = false
    var successMessage = ""

    // Cursor permission
    var showCursorPermissionAlert = false

    // Stored properties that sync with UserDefaults
    var aiProvider: AIProvider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .claudeCLI
    var model: String = UserDefaults.standard.string(forKey: "claudeModel") ?? "sonnet"
    var diariesDirectoryPath: String = UserDefaults.standard.string(forKey: "diariesDirectory") ?? ""

    @ObservationIgnored
    private let aggregator = AggregatorService()

    @ObservationIgnored
    private let claudeCLI = ClaudeCLIService()

    @ObservationIgnored
    private let claudeAPI = ClaudeAPIService()

    @ObservationIgnored
    private let geminiAPI = GeminiAPIService()

    @ObservationIgnored
    private var storage: DiaryStorage?

    @ObservationIgnored
    nonisolated(unsafe) private var defaultsObserver: NSObjectProtocol?

    init() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSettings()
            }
        }
    }

    deinit {
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func refreshSettings() {
        let newProvider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .claudeCLI
        let newModel = UserDefaults.standard.string(forKey: "claudeModel") ?? "sonnet"
        let newPath = UserDefaults.standard.string(forKey: "diariesDirectory") ?? ""

        if aiProvider != newProvider { aiProvider = newProvider }
        if model != newModel { model = newModel }
        if diariesDirectoryPath != newPath {
            diariesDirectoryPath = newPath
            storage = nil
        }
    }

    private func getStorage() -> DiaryStorage {
        if let storage = storage {
            return storage
        }
        let newStorage: DiaryStorage
        if diariesDirectoryPath.isEmpty {
            newStorage = DiaryStorage()
        } else {
            newStorage = DiaryStorage(directory: URL(fileURLWithPath: diariesDirectoryPath))
        }
        storage = newStorage
        return newStorage
    }

    // MARK: - Initial Data Loading

    func loadInitialData() async {
        isLoadingInitial = true

        // Check Cursor access permission
        checkCursorPermission()

        do {
            // Build date index first (fast if already cached)
            isBuildingIndex = true
            indexBuildProgress = "Building Claude Code index..."
            await aggregator.buildDateIndex { @MainActor [weak self] progress in
                self?.indexBuildProgress = progress
            }
            isBuildingIndex = false
            indexBuildProgress = ""

            // Load all dates with activity
            datesWithActivity = try await aggregator.getAllActivityDates()

            // Load all dates with diaries
            let diaries = try await getStorage().loadAll()
            datesWithDiary = Set(diaries.map { $0.dateString })

            // Load data for selected date
            await loadDataForDate(selectedDate)
        } catch {
            showErrorMessage(error.localizedDescription)
        }
        isBuildingIndex = false
        isLoadingInitial = false
    }

    private func checkCursorPermission() {
        let cursorService = CursorService()
        let status = cursorService.checkAccessStatus()
        if status == .noPermission {
            showCursorPermissionAlert = true
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Date Selection

    func loadDataForDate(_ date: Date, force: Bool = false) async {
        let dateString = formatDateString(date)

        // Skip if already loaded this date (prevents double loading)
        if !force && dateString == lastLoadedDateString && !isLoadingDate {
            return
        }

        isLoadingDate = true
        lastLoadedDateString = dateString

        // Reset immediately to avoid showing stale data
        currentDayStatistics = nil
        currentDiary = nil
        selectedProjects = []

        // Load diary if exists
        do {
            currentDiary = try await getStorage().load(dateString: dateString)
        } catch {
            currentDiary = nil
        }

        // Load statistics
        do {
            currentDayStatistics = try await aggregator.getQuickStatistics(for: date)

            // Remove from activity dates if no actual messages
            if let stats = currentDayStatistics, stats.messageCount == 0 {
                datesWithActivity.remove(dateString)
            }

            // Select all projects by default
            if let stats = currentDayStatistics {
                selectedProjects = Set(stats.projects.map { $0.path })
            }
        } catch {
            currentDayStatistics = nil
        }
        isLoadingDate = false
    }

    // MARK: - Diary Generation

    func generateDiary() async {
        // Guard against concurrent generation
        guard !isGenerating else { return }

        // Capture state at start to avoid race conditions during async execution
        let targetDate = selectedDate
        let targetDateString = formatDateString(targetDate)
        let selectedPaths = selectedProjects

        isGenerating = true
        generationProgress = "Aggregating activity data..."

        do {
            let fullActivity = try await aggregator.aggregateForDate(targetDate)

            // Filter to only selected projects (using captured state)
            let filteredProjects = fullActivity.projects.filter { selectedPaths.contains($0.path) }
            let activity = DailyActivity(
                date: fullActivity.date,
                projects: filteredProjects,
                totalInputs: fullActivity.totalInputs
            )

            if activity.projects.isEmpty {
                isGenerating = false
                showErrorMessage("No projects selected for \(activity.formattedDate)")
                return
            }

            generationProgress = "Generating diary with \(aiProvider.displayName)..."

            let content: DiaryContent
            switch aiProvider {
            case .claudeCLI:
                content = try await claudeCLI.generateDiary(
                    activity: activity,
                    model: model
                )
            case .claudeAPI:
                guard let apiKey = KeychainHelper.load(service: KeychainHelper.claudeAPIService) else {
                    throw ClaudeAPIError.missingAPIKey
                }
                content = try await claudeAPI.generateDiary(
                    activity: activity,
                    apiKey: apiKey
                )
            case .gemini:
                guard let apiKey = KeychainHelper.load(service: KeychainHelper.geminiAPIService) else {
                    throw GeminiAPIError.missingAPIKey
                }
                content = try await geminiAPI.generateDiary(
                    activity: activity,
                    apiKey: apiKey
                )
            }

            let entry = DiaryFormatter.format(content)

            generationProgress = "Saving diary..."
            try await getStorage().save(entry)

            // Update calendar indicators
            datesWithDiary.insert(entry.dateString)
            
            // Only update currentDiary if still on the same date
            if formatDateString(selectedDate) == targetDateString {
                currentDiary = entry
            }

            isGenerating = false
            generationProgress = ""
        } catch {
            isGenerating = false
            generationProgress = ""
            showErrorMessage(error.localizedDescription)
        }
    }

    func generateAllDiaries() async {
        isGenerating = true

        do {
            let datesToGenerate = datesWithActivity.subtracting(datesWithDiary).sorted()
            let totalCount = datesToGenerate.count
            var generatedCount = 0
            var skippedCount = 0

            for (index, dateStr) in datesToGenerate.enumerated() {
                generationProgress = "Processing \(index + 1)/\(totalCount): \(dateStr)"

                guard let date = DateFormatting.iso.date(from: dateStr) else {
                    skippedCount += 1
                    continue
                }

                let activity = try await aggregator.aggregateForDate(date)
                if activity.projects.isEmpty {
                    skippedCount += 1
                    continue
                }

                generationProgress = "Generating \(index + 1)/\(totalCount): \(dateStr)"

                // Generate with retry
                let content = try await generateDiaryWithRetry(activity: activity, dateStr: dateStr, index: index, totalCount: totalCount)

                let diary = DiaryFormatter.format(content)
                try await getStorage().save(diary)
                datesWithDiary.insert(diary.dateString)
                generatedCount += 1

                // Small delay to avoid rate limiting
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            // Update current diary if it was generated
            let currentDateString = formatDateString(selectedDate)
            if datesWithDiary.contains(currentDateString) && currentDiary == nil {
                currentDiary = try await getStorage().load(dateString: currentDateString)
            }

            isGenerating = false
            generationProgress = ""

            if generatedCount > 0 || skippedCount > 0 {
                showSuccessMessage("Generated \(generatedCount) diaries, skipped \(skippedCount)")
            }
        } catch {
            isGenerating = false
            generationProgress = ""
            showErrorMessage(error.localizedDescription)
        }
    }

    private func generateDiaryWithRetry(
        activity: DailyActivity,
        dateStr: String,
        index: Int,
        totalCount: Int,
        maxRetries: Int = 3
    ) async throws -> DiaryContent {
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                if attempt > 1 {
                    generationProgress = "Retry \(attempt)/\(maxRetries) for \(index + 1)/\(totalCount): \(dateStr)"
                    // Wait before retry (exponential backoff)
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                }

                switch aiProvider {
                case .claudeCLI:
                    return try await claudeCLI.generateDiary(
                        activity: activity,
                        model: model
                    )
                case .claudeAPI:
                    guard let apiKey = KeychainHelper.load(service: KeychainHelper.claudeAPIService) else {
                        throw ClaudeAPIError.missingAPIKey
                    }
                    return try await claudeAPI.generateDiary(
                        activity: activity,
                        apiKey: apiKey
                    )
                case .gemini:
                    guard let apiKey = KeychainHelper.load(service: KeychainHelper.geminiAPIService) else {
                        throw GeminiAPIError.missingAPIKey
                    }
                    return try await geminiAPI.generateDiary(
                        activity: activity,
                        apiKey: apiKey
                    )
                }
            } catch {
                lastError = error
                // Don't retry for non-network errors (like missing API key)
                if (error as NSError).domain != NSURLErrorDomain {
                    throw error
                }
            }
        }

        throw lastError ?? NSError(domain: "DiaryGeneration", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed after \(maxRetries) retries"])
    }

    // MARK: - Helpers

    private func formatDateString(_ date: Date) -> String {
        DateFormatting.iso.string(from: date)
    }

    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }

    private func showSuccessMessage(_ message: String) {
        successMessage = message
        showSuccess = true
    }
}
