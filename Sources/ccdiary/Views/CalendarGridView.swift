import SwiftUI

/// Continuous scrollable calendar grid - no month dividers
struct CalendarGridView: View {
    @Binding var selectedDate: Date
    let datesWithActivity: Set<String>
    let datesWithDiary: Set<String>

    @State private var allDays: [DayItem] = []
    @State private var todayIndex: Int = 0
    @State private var hasScrolledToToday = false

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private let weekdaySymbols = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        VStack(spacing: 0) {
            // Fixed weekday header
            WeekdayHeader(symbols: weekdaySymbols)

            // Scrollable continuous calendar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 0) {
                        ForEach(Array(allDays.enumerated()), id: \.element.id) { index, item in
                            DayCellView(
                                item: item,
                                isSelected: item.date.map { calendar.isDate($0, inSameDayAs: selectedDate) } ?? false,
                                isToday: item.date.map { calendar.isDateInToday($0) } ?? false,
                                hasActivity: item.dateString.map { datesWithActivity.contains($0) } ?? false,
                                hasDiary: item.dateString.map { datesWithDiary.contains($0) } ?? false,
                                isOddMonth: item.isOddMonth ?? false
                            )
                            .id(index)
                            .onTapGesture {
                                if let date = item.date {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        selectedDate = date
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
                .onAppear {
                    if !datesWithActivity.isEmpty {
                        initializeDays()
                        Task {
                            try? await Task.sleep(for: .milliseconds(50))
                            proxy.scrollTo(todayIndex, anchor: .center)
                            hasScrolledToToday = true
                        }
                    }
                }
                .onChange(of: datesWithActivity) { _, _ in
                    initializeDays()
                    Task {
                        try? await Task.sleep(for: .milliseconds(50))
                        proxy.scrollTo(todayIndex, anchor: .center)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func initializeDays() {
        let today = Date()
        let startOfToday = calendar.startOfDay(for: today)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        // Combine all dates with data
        let allDateStrings = datesWithActivity.union(datesWithDiary)

        // Parse date strings and find range
        let parsedDates = allDateStrings.compactMap { formatter.date(from: $0) }

        guard let earliestDate = parsedDates.min() else {
            // No data, show current month
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: startOfToday))!
            let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart)!
            initializeDaysForRange(from: monthStart, to: monthEnd, today: today, formatter: formatter)
            return
        }

        // Start from the first day of the earliest month
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: earliestDate))!

        // End date is the last day of current month
        let endOfMonth = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: calendar.date(from: calendar.dateComponents([.year, .month], from: startOfToday))!)!

        initializeDaysForRange(from: startOfMonth, to: endOfMonth, today: today, formatter: formatter)
    }

    private func initializeDaysForRange(from startDate: Date, to endDate: Date, today: Date, formatter: DateFormatter) {
        // Find the Sunday before startDate
        let startWeekday = calendar.component(.weekday, from: startDate)
        guard let gridStartDate = calendar.date(byAdding: .day, value: -(startWeekday - 1), to: startDate) else {
            return
        }

        // Extend endDate to end of its week (Saturday)
        let endWeekday = calendar.component(.weekday, from: endDate)
        guard let gridEndDate = calendar.date(byAdding: .day, value: (7 - endWeekday), to: endDate) else {
            return
        }

        var days: [DayItem] = []
        var currentDate = gridStartDate
        var foundTodayIndex: Int?

        while currentDate <= gridEndDate {
            let isInRange = currentDate >= startDate && currentDate <= endDate
            let dateString = formatter.string(from: currentDate)

            // Check if this is the first day of a month
            let dayOfMonth = calendar.component(.day, from: currentDate)
            let monthLabel: String? = dayOfMonth == 1 ? monthAbbreviation(for: currentDate) : nil

            let month = calendar.component(.month, from: currentDate)
            let isOddMonth = month % 2 == 1

            if isInRange {
                if calendar.isDate(currentDate, inSameDayAs: today) {
                    foundTodayIndex = days.count
                }
                days.append(DayItem(
                    date: currentDate,
                    dateString: dateString,
                    dayOfMonth: dayOfMonth,
                    monthLabel: monthLabel,
                    isOddMonth: isOddMonth,
                    index: days.count
                ))
            } else {
                // Empty placeholder for alignment
                days.append(DayItem(date: nil, dateString: nil, dayOfMonth: nil, monthLabel: nil, isOddMonth: nil, index: days.count))
            }

            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) else { break }
            currentDate = nextDate
        }

        allDays = days
        todayIndex = foundTodayIndex ?? max(0, days.count - 1)
    }

    private func monthAbbreviation(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter.string(from: date).uppercased()
    }
}

// MARK: - Day Item

struct DayItem: Identifiable {
    let id: String
    let date: Date?
    let dateString: String?
    let dayOfMonth: Int?
    let monthLabel: String?
    let isOddMonth: Bool?

    init(date: Date?, dateString: String?, dayOfMonth: Int?, monthLabel: String?, isOddMonth: Bool?, index: Int) {
        self.id = dateString ?? "empty-\(index)"
        self.date = date
        self.dateString = dateString
        self.dayOfMonth = dayOfMonth
        self.monthLabel = monthLabel
        self.isOddMonth = isOddMonth
    }
}

// MARK: - Weekday Header

struct WeekdayHeader: View {
    let symbols: [String]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
            }
        }
        .padding(.horizontal, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Day Cell View

struct DayCellView: View {
    let item: DayItem
    let isSelected: Bool
    let isToday: Bool
    let hasActivity: Bool
    let hasDiary: Bool
    let isOddMonth: Bool

    var body: some View {
        ZStack {
            // Background
            backgroundColor

            if let day = item.dayOfMonth {
                VStack(spacing: 0) {
                    // Month label (only on 1st)
                    if let month = item.monthLabel {
                        Text(month)
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                            .frame(height: 10)
                    } else {
                        Spacer().frame(height: 10)
                    }

                    // Day number
                    Text("\(day)")
                        .font(.system(size: 11, weight: isSelected || isToday ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(textColor)

                    // Activity indicator
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: 4, height: 4)
                        .opacity(hasDiary || hasActivity ? 1 : 0)
                }
            }
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var textColor: Color {
        if isSelected {
            return .white
        } else if isToday {
            return .accentColor
        } else if item.date == nil {
            return .clear
        } else if !hasActivity && !hasDiary {
            return .secondary.opacity(0.4)
        } else {
            return .primary
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return .accentColor
        } else if isToday {
            return Color.accentColor.opacity(0.12)
        } else if isOddMonth {
            return Color.primary.opacity(0.04)
        } else {
            return .clear
        }
    }

    private var indicatorColor: Color {
        if isSelected {
            return .white
        } else if hasDiary {
            return .accentColor
        } else {
            return .secondary.opacity(0.5)
        }
    }
}
