import SwiftUI
import AppKit

@main
struct CCDiaryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1000, height: 700)
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) { }
            DiaryCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Menu Commands

struct DiaryCommands: Commands {
    @FocusedValue(\.diaryViewModel) var viewModel

    var body: some Commands {
        CommandMenu("Diary") {
            Button("Generate All Diaries") {
                guard let viewModel else { return }
                Task {
                    await viewModel.generateAllDiaries()
                }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(viewModel?.isGenerating ?? true)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
