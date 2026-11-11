import ImportEngine

extension ImportModel {
    /// How many rejected files the job left out (D3), once there are counts to show: "3 rejected files left out. Pick
    /// them in Browse to import them anyway."; nil when it left none out. The engine counts only the rejects it left
    /// out itself (*all new*, a date range, a job queued again from History, a *Select All New* pick it was handed);
    /// Browse's *Select All New* never picks them in the first place.
    public var rejectsLeftOutLine: String? {
        guard camera != nil, progress.filesDone > 0 || isFinished else { return nil }
        return ImportWording.rejectsLeftOut(progress.rejectsLeftOut)
    }
}
