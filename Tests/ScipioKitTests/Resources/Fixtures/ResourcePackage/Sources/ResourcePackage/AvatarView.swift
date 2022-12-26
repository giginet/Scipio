import Foundation
import UIKit

public class AvatarView: UIView {
    @IBOutlet weak var imageView: UIImageView!

    public static func build() -> Self {
        let nib = UINib(nibName: "AvatarView", bundle: .module).instantiate(withOwner: nil).first as! Self
        return nib
    }

    public override func awakeFromNib() {
        super.awakeFromNib()

        imageView.image = self.image
    }

    private var image: UIImage {
        #if SWIFT_PACKAGE
        UIImage(named: "giginet", in: .module, compatibleWith: nil)!
        #else
        UIImage(named: "giginet", in: .main, compatibleWith: nil)!
        #endif
    }
}
