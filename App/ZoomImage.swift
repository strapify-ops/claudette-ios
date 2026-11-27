import SwiftUI
import UIKit

// Full-screen image viewer: fits the image to the screen (folded or unfolded), centred,
// pinch to zoom up to 8x, double tap to zoom in/out, pan when zoomed.
struct ZoomImage: View {
    let image: UIImage?
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image { ZoomScroll(image: image).ignoresSafeArea() }
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundStyle(.white, .gray.opacity(0.5))
            }.padding()
        }
    }
}

struct ZoomScroll: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> CenteringScrollView {
        let v = CenteringScrollView()
        v.imageView.image = image
        return v
    }
    func updateUIView(_ v: CenteringScrollView, context: Context) {
        if v.imageView.image !== image { v.imageView.image = image; v.setNeedsLayout() }
    }
}

final class CenteringScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private var lastSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .black
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        addSubview(imageView)
        let dbl = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        addGestureRecognizer(dbl)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Re-fit whenever the view size changes (fold/unfold, rotation).
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let img = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != lastSize {
            lastSize = bounds.size
            zoomScale = 1
            let fit = min(bounds.width / img.size.width, bounds.height / img.size.height)
            imageView.frame = CGRect(x: 0, y: 0, width: img.size.width * fit, height: img.size.height * fit)
            contentSize = imageView.frame.size
            minimumZoomScale = 1
            maximumZoomScale = max(8, 1 / fit)
        }
        centre()
    }

    private func centre() {
        let w = imageView.frame.width, h = imageView.frame.height
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - h) / 2), left: max(0, (bounds.width - w) / 2), bottom: 0, right: 0)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale > 1.01 { setZoomScale(1, animated: true); return }
        let p = g.location(in: imageView)
        let s: CGFloat = 3
        let size = CGSize(width: bounds.width / s, height: bounds.height / s)
        zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
}
