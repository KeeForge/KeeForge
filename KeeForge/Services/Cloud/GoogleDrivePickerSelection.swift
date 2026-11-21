enum GoogleDrivePickerSelection {
    /// Read only from an authorization response already validated by AppAuth.
    static func fileID(from additionalParameters: [String: Any]?) -> String? {
        guard let fileID = additionalParameters?["picked_file_ids"] as? String,
              fileID.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil else { return nil }
        return fileID
    }
}
