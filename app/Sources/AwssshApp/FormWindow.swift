import Combine
import SwiftUI

struct FormWindowRoot: View {
    @EnvironmentObject var model: AppModel

    static let width: CGFloat = 400

    var body: some View {
        Group {
            if let editing = model.editing {
                FormView(draft: editing)
            }
        }
        .padding(14)
        .frame(width: FormWindowRoot.width)
    }
}

@MainActor
final class FormWindowPresenter {
    private weak var model: AppModel?
    private let host = WindowHost()
    private var watch: AnyCancellable?

    func attach(to model: AppModel) {
        self.model = model
        host.onClose = { [weak model] in model?.cancelForm() }
        watch =
            model.$showingForm
            .removeDuplicates()
            .sink { [weak self] showing in
                Task { @MainActor in
                    guard let self else { return }
                    showing ? self.show() : self.host.hide()
                }
            }
    }

    private func show() {
        guard let model, let draft = model.editing else { return }
        let editing = model.forwards.contains { $0.id == draft.id }
        host.show(title: editing ? "Edit forward" : "Add forward") {
            FormWindowRoot().environmentObject(model)
        }
    }
}
