import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The reply box. A UITextView rather than a SwiftUI TextField so Paste also takes images,
// screenshots and files from the clipboard and turns them into attachments.
struct PasteTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var maxLines: CGFloat = 8
    let onFiles: ([Attachment]) -> Void

    func makeUIView(context: Context) -> PastingTextView {
        let v = PastingTextView()
        v.delegate = context.coordinator
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear
        v.textColor = .label
        v.isScrollEnabled = false
        v.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.onFiles = onFiles
        v.placeholderLabel.text = placeholder
        return v
    }

    func updateUIView(_ v: PastingTextView, context: Context) {
        if v.text != text { v.text = text }
        v.onFiles = onFiles
        v.placeholderLabel.text = placeholder
        v.placeholderLabel.isHidden = !text.isEmpty
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: PastingTextView, context: Context) -> CGSize? {
        let w = proposal.width ?? 280
        let fit = v.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        let maxH = (v.font?.lineHeight ?? 20) * maxLines + 16
        v.isScrollEnabled = fit.height > maxH
        return CGSize(width: w, height: min(fit.height, maxH))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PasteTextView
        init(_ p: PasteTextView) { parent = p }
        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            (tv as? PastingTextView)?.placeholderLabel.isHidden = !tv.text.isEmpty
            tv.invalidateIntrinsicContentSize()
        }
    }
}

final class PastingTextView: UITextView {
    var onFiles: (([Attachment]) -> Void)?
    let placeholderLabel = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.numberOfLines = 1
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            placeholderLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var clipboardHasFiles: Bool {
        let pb = UIPasteboard.general
        return pb.hasImages || pb.itemProviders.contains { p in p.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: .fileURL) == true || UTType($0)?.conforms(to: .pdf) == true } }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings || clipboardHasFiles }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        var files: [Attachment] = []
        if pb.hasImages, let imgs = pb.images {
            files = imgs.compactMap { Attachment.photo($0, name: "pasted") }
        } else {
            for p in pb.itemProviders {
                for t in p.registeredTypeIdentifiers {
                    guard let ut = UTType(t), !ut.conforms(to: .text), !(ut.conforms(to: .url) && !ut.conforms(to: .fileURL)) else { continue }
                    let sema = DispatchSemaphore(value: 0)
                    var got: Attachment?
                    p.loadDataRepresentation(forTypeIdentifier: t) { d, _ in
                        if let d { got = Attachment(name: (p.suggestedName ?? "pasted") + (ut.preferredFilenameExtension.map { "." + $0 } ?? ""), data: d, preview: UIImage(data: d)) }
                        sema.signal()
                    }
                    _ = sema.wait(timeout: .now() + 5)
                    if let got { files.append(got) }
                    break
                }
            }
        }
        if !files.isEmpty {
            onFiles?(files)
            if pb.hasStrings && !pb.hasImages { super.paste(sender) }
        } else {
            super.paste(sender)
        }
    }
}
