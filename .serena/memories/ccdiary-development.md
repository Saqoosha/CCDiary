# ccdiary Development Notes

## Build Commands

**Important**: Always use `xcodebuild`, not `swift build`.

```bash
# Kill running app
pkill -f ccdiary

# Regenerate project after adding files
xcodegen generate

# Build
xcodebuild -scheme ccdiary -configuration Debug -derivedDataPath build build

# Run
open build/Build/Products/Debug/ccdiary.app
```

## Project Info

- Swift macOS app with SwiftUI
- Uses `project.yml` with xcodegen
- Statistics cache: `~/Library/Caches/ccdiary/statistics/`

## Architecture

- Models: `Sources/ccdiary/Models/`
- Views: `Sources/ccdiary/Views/`
- Services: `Sources/ccdiary/Services/`
  - `StatisticsCache` - Caches DayStatistics for dates before today
