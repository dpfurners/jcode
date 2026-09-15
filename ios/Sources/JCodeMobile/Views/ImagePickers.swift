import PhotosUI
import SwiftUI
import UIKit

/// UIImagePickerController wrapper for the camera (PhotosPicker has no
/// capture mode).
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Thumbnail strip above the composer field; each one removable.
struct AttachmentStrip: View {
    let images: [PendingImage]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { image in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                    .stroke(Theme.border, lineWidth: 1))
                        Button {
                            onRemove(image.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.body)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.black, Theme.textPrimary)
                                .frame(width: 32, height: 32)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 8, y: -8)
                        .accessibilityLabel("Remove image")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Attached image")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
    }
}
