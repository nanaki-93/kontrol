import CoreGraphics

/// 4-point layout grid shared with the selected design-system reference.
/// Content grows with typography; only interactive bounds have minimum sizes.
enum AppMetrics {
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space6: CGFloat = 24
    static let space8: CGFloat = 32

    static let horizontalInset = space8
    static let contentInset = space6
    static let smallRadius: CGFloat = 4
    static let mediumRadius: CGFloat = 8
    static let minimumTarget: CGFloat = 32
    static let preferredTarget: CGFloat = 44
}
