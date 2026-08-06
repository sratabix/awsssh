import Combine
import SwiftUI

struct WhatsNewView: View {
    @EnvironmentObject var model: AppModel

    static let width: CGFloat = 420
    static let maxHeight: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.orange)
                Text(title).font(.headline)
            }
            ScrollingList(maxHeight: WhatsNewView.maxHeight) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.whatsNew) { section in
                        VStack(alignment: .leading, spacing: 5) {
                            if model.whatsNew.count > 1 {
                                Text(section.displayVersion)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(entry).font(.callout).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { model.closeWhatsNew() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: WhatsNewView.width)
    }

    private var title: String {
        guard let first = model.whatsNew.first else { return "What's new" }
        return model.whatsNew.count == 1
            ? "What's new in \(first.displayVersion)"
            : "What's new since \(model.whatsNew.last?.displayVersion ?? first.displayVersion)"
    }
}

@MainActor
final class WhatsNewWindowPresenter {
    private weak var model: AppModel?
    private let host = WindowHost()
    private var watch: AnyCancellable?

    func attach(to model: AppModel) {
        self.model = model
        host.onClose = { [weak model] in model?.closeWhatsNew() }
        watch =
            model.$showingWhatsNew
            .removeDuplicates()
            .sink { [weak self] showing in
                Task { @MainActor in
                    guard let self else { return }
                    showing ? self.show() : self.host.hide()
                }
            }
    }

    private func show() {
        guard let model else { return }
        host.show(title: "What's New") {
            WhatsNewView().environmentObject(model)
        }
    }
}
