/// Stable preference values. Case declaration order is the navigation display order.
enum AppDestination: String, CaseIterable, Codable {
    case today
    case learning
    case projects
    case focus
    case tasks
    case news
    case settings
}
