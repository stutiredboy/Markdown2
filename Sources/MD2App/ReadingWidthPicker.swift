import SwiftUI

struct ReadingWidthPicker: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Picker(settings.text(.readingWidth), selection: $settings.typography.readingWidth) {
            ForEach(ReadingWidth.allCases) { width in
                Text(settings.text(width.label)).tag(width)
            }
        }
    }
}
