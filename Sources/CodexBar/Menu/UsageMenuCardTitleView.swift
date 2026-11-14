import SwiftUI

struct UsageMenuCardTitleView: View {
    let title: String

    var body: some View {
        Text(self.title)
            .font(.headline)
            .fontWeight(.semibold)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
    }
}
