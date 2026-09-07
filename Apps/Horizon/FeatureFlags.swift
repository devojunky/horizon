/// Switches for features that ship dark until they are ready to be shown.
enum FeatureFlags {
    /// The OpenAI route (the user's own key) in the More menu, Documents and the planner. Off hides it everywhere
    /// and the app reads with Apple's models only.
    static let openAI = true
}
