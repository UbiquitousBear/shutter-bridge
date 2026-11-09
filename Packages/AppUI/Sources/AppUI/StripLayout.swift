/// How the top strips lay out their text (`StatusStrips`): held to a few lines at the accessibility text sizes, so
/// together they never fill the screen (HIG Dynamic Type), and to one line in compact height (an iPhone in
/// landscape), where the bar and the strips would otherwise leave little of the card (HIG Layout). VoiceOver still
/// reads the whole text. A problem notice is the exception: it stays until closed and ends with what to do next, so
/// it keeps three lines in compact height and has no limit at the accessibility sizes, where it can be read in full.
public enum StripLayout {
    /// The most lines a strip's text takes; nil for no limit.
    public static func lineLimit(isAccessibilitySize: Bool, isCompactHeight: Bool, isProblem: Bool = false) -> Int? {
        if isProblem { return isAccessibilitySize ? nil : (isCompactHeight ? 3 : nil) }
        if isCompactHeight { return 1 }
        return isAccessibilitySize ? 3 : nil
    }

    /// The space between strips and around a strip's text, in points: tighter in compact height.
    public static func spacing(isCompactHeight: Bool) -> Double { isCompactHeight ? 4 : 8 }
}
