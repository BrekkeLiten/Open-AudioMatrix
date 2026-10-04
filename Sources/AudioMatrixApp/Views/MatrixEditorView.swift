import SwiftUI

struct MatrixEditorView: View {
    @Bindable var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(model: model)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Divider()
            RoutingMatrixView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Open AudioMatrix")
        .background(MatrixTheme.background)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showPermissionsGuide) {
            PermissionsGuideView(model: model)
        }
    }
}
