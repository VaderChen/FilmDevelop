import AppKit

extension PhotoStyleWebCoordinator {
    func addThumbnailOrganizationMenus(to menu: NSMenu, ids: [String]) {
        let metadata = ids.compactMap { photoDirectoryStore.url(for: $0) }.map { photoOrganizationStore.metadata(for: $0) }
        guard !metadata.isEmpty else { return }
        func item(_ title: String, action: Selector, payload: [String: Any]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = payload.merging(["ids": ids]) { current, _ in current }
            return item
        }
        func selectionState(_ count: Int) -> NSControl.StateValue {
            count == metadata.count ? .on : (count == 0 ? .off : .mixed)
        }
        let rating = NSMenuItem(title: PhotoL10n.text("分級"), action: nil, keyEquivalent: "")
        let ratings = NSMenu()
        for value in 0...5 {
            let entry = item(value == 0 ? PhotoL10n.text("未分級") : String(repeating: "★", count: value),
                             action: #selector(performThumbnailOrganization(_:)), payload: ["rating": value])
            entry.state = selectionState(metadata.filter { $0.rating == value }.count)
            ratings.addItem(entry)
        }
        rating.submenu = ratings
        menu.addItem(rating)

        let category = NSMenuItem(title: PhotoL10n.text("分類"), action: nil, keyEquivalent: "")
        let tags = NSMenu()
        for tag in photoOrganizationStore.tags {
            let count = metadata.filter { $0.tags.contains(tag) }.count
            let entry = item(tag, action: #selector(performThumbnailOrganization(_:)),
                             payload: ["tag": tag, "present": count != metadata.count])
            entry.state = selectionState(count)
            tags.addItem(entry)
        }
        if !photoOrganizationStore.tags.isEmpty { tags.addItem(.separator()) }
        tags.addItem(item(PhotoL10n.text("新增分類…"), action: #selector(promptThumbnailCategory(_:)), payload: [:]))
        let remove = NSMenuItem(title: PhotoL10n.text("移除分類"), action: nil, keyEquivalent: "")
        let removalMenu = NSMenu()
        for tag in photoOrganizationStore.tags {
            let entry = NSMenuItem(title: tag, action: #selector(confirmRemovePhotoCategory(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = tag
            removalMenu.addItem(entry)
        }
        remove.submenu = removalMenu
        remove.isEnabled = !photoOrganizationStore.tags.isEmpty
        tags.addItem(remove)
        let clear = item(PhotoL10n.text("清除分類"), action: #selector(performThumbnailOrganization(_:)), payload: ["clearTags": true])
        clear.isEnabled = metadata.contains { !$0.tags.isEmpty }
        tags.autoenablesItems = false
        tags.addItem(clear)
        category.submenu = tags
        menu.addItem(category)
        menu.addItem(.separator())
    }

    @objc func performThumbnailOrganization(_ item: NSMenuItem) {
        guard canImport, let payload = item.representedObject as? [String: Any],
              let ids = payload["ids"] as? [String] else { return }
        let urls = ids.compactMap { photoDirectoryStore.url(for: $0) }
        do {
            if let rating = payload["rating"] as? Int { try photoOrganizationStore.setRating(rating, for: urls) }
            else if let tag = payload["tag"] as? String, let present = payload["present"] as? Bool {
                try photoOrganizationStore.setTag(tag, present: present, for: urls)
            } else if payload["clearTags"] as? Bool == true { try photoOrganizationStore.clearTags(for: urls) }
            sendPhotoDirectoryState()
        } catch { sendToast("無法儲存照片分級與分類：\(PhotoL10n.text(error.localizedDescription))") }
    }

    @objc func confirmRemovePhotoCategory(_ item: NSMenuItem) {
        guard canImport, let tag = item.representedObject as? String,
              photoOrganizationStore.tags.contains(tag),
              let window = webView?.window, window.attachedSheet == nil else { return }
        do {
            let count = try photoOrganizationStore.photoCount(forTag: tag)
            let alert = NSAlert()
            if count > 0 {
                alert.messageText = PhotoL10n.text("無法移除分類「\(tag)」")
                alert.informativeText = PhotoL10n.text("此分類仍有 \(count) 張照片（包含其他目錄）。請先移除這些照片的分類標記。")
                alert.addButton(withTitle: PhotoL10n.text("確定"))
                alert.beginSheetModal(for: window, completionHandler: nil)
                return
            }
            alert.messageText = PhotoL10n.text("移除分類「\(tag)」？")
            alert.informativeText = PhotoL10n.text("已確認沒有照片使用此分類。移除後，分類名稱將從選單中刪除。")
            alert.addButton(withTitle: PhotoL10n.text("移除"))
            alert.addButton(withTitle: PhotoL10n.text("取消"))
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self, self.canImport else { return }
                do {
                    try self.photoOrganizationStore.removeTag(tag)
                    self.sendPhotoDirectoryState()
                } catch { self.sendToast("無法儲存照片分級與分類：\(PhotoL10n.text(error.localizedDescription))") }
            }
        } catch { sendToast("無法儲存照片分級與分類：\(PhotoL10n.text(error.localizedDescription))") }
    }

    @objc func promptThumbnailCategory(_ item: NSMenuItem) {
        guard canImport, let payload = item.representedObject as? [String: Any],
              let ids = payload["ids"] as? [String],
              let window = webView?.window, window.attachedSheet == nil else { return }
        // Capture the photo URLs before the sheet opens; later directory changes cannot retarget the action.
        let urls = ids.compactMap { photoDirectoryStore.url(for: $0) }
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = PhotoL10n.text("新增分類")
        alert.informativeText = PhotoL10n.text("為選取的照片加入分類，可同時保留多個分類標籤。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = PhotoL10n.text("分類名稱（1～40 個字）")
        field.setAccessibilityLabel(PhotoL10n.text("分類名稱"))
        alert.accessoryView = field
        alert.addButton(withTitle: PhotoL10n.text("加入"))
        alert.addButton(withTitle: PhotoL10n.text("取消"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.canImport else { return }
            do {
                try self.photoOrganizationStore.setTag(field.stringValue, present: true, for: urls)
                self.sendPhotoDirectoryState()
            } catch { self.sendToast("無法儲存照片分級與分類：\(PhotoL10n.text(error.localizedDescription))") }
        }
    }
}
