import Foundation

enum Live2DModelLibrary {
    static let mountedRootName = "installed-models"

    private static let accentPalette = [
        "#FF8B5E",
        "#FF6B9B",
        "#7D7BFF",
        "#4EC3B3",
        "#E6A93D",
        "#6FC36A",
    ]

    static func libraryDirectory(fileManager: FileManager = FileManager()) -> URL? {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("KinkoClaw/Live2DModels", isDirectory: true)
    }

    static func installedPacks(fileManager: FileManager = FileManager()) -> [PetPackManifest] {
        guard let baseURL = self.libraryDirectory(fileManager: fileManager) else { return [] }
        guard let children = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [URLResourceKey.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else {
            return []
        }

        return children.compactMap { packURL in
            let manifestURL = packURL.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  var pack = try? JSONDecoder().decode(PetPackManifest.self, from: data)
            else {
                return nil
            }

            if pack.previewImage?.isEmpty == true {
                pack = PetPackManifest(
                    id: pack.id,
                    displayName: pack.displayName,
                    accentHex: pack.accentHex,
                    previewImage: nil,
                    assets: pack.assets,
                    animationProfile: pack.animationProfile,
                    model: pack.model,
                    defaultSceneFrame: pack.defaultSceneFrame,
                    dialogueProfile: pack.dialogueProfile,
                    interactionProfile: pack.interactionProfile)
            }

            return pack
        }
    }

    static func resolveMountedFileURL(
        for relativePath: String,
        fileManager: FileManager = FileManager()) -> URL?
    {
        guard relativePath.hasPrefix("\(self.mountedRootName)/"),
              let rootURL = self.libraryDirectory(fileManager: fileManager)?.standardizedFileURL
        else {
            return nil
        }

        let suffix = String(relativePath.dropFirst(self.mountedRootName.count + 1))
        let candidate = rootURL.appendingPathComponent(suffix).standardizedFileURL
        guard candidate.path == rootURL.path || candidate.path.hasPrefix(rootURL.path + "/") else {
            return nil
        }

        return candidate
    }

    static func importModelPack(
        from sourceURL: URL,
        fileManager: FileManager = FileManager()) throws -> PetPackManifest
    {
        guard let libraryURL = self.libraryDirectory(fileManager: fileManager) else {
            throw NSError(
                domain: "KinkoClaw.Live2DModelLibrary",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法定位 Live2D 模型库目录。"])
        }

        try fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true, attributes: nil)

        let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
        let isDirectory = values.isDirectory == true
        let sourceName = values.name ?? sourceURL.lastPathComponent
        let displayName = self.humanReadableName(for: sourceName, isDirectory: isDirectory)
        let packID = self.uniquePackID(baseName: displayName, libraryURL: libraryURL, fileManager: fileManager)
        let packURL = libraryURL.appendingPathComponent(packID, isDirectory: true)
        try fileManager.createDirectory(at: packURL, withIntermediateDirectories: true, attributes: nil)

        let manifest: PetPackManifest
        if isDirectory {
            manifest = try self.importDirectoryPack(
                from: sourceURL,
                to: packURL,
                packID: packID,
                displayName: displayName,
                fileManager: fileManager)
        } else if sourceURL.pathExtension.lowercased() == "zip" {
            manifest = try self.importArchivePack(
                from: sourceURL,
                to: packURL,
                packID: packID,
                displayName: displayName,
                fileManager: fileManager)
        } else {
            throw NSError(
                domain: "KinkoClaw.Live2DModelLibrary",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "仅支持导入 Live2D 模型 ZIP，或包含 .model3.json 的文件夹。",
                ])
        }

        let manifestURL = packURL.appendingPathComponent("manifest.json")
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)
        return manifest
    }

    private static func importArchivePack(
        from sourceURL: URL,
        to packURL: URL,
        packID: String,
        displayName: String,
        fileManager: FileManager) throws -> PetPackManifest
    {
        let archiveURL = packURL.appendingPathComponent("model.zip")
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }
        try fileManager.copyItem(at: sourceURL, to: archiveURL)

        return self.buildManifest(
            packID: packID,
            displayName: displayName,
            modelPath: "\(self.mountedRootName)/\(packID)/model.zip",
            previewImage: nil,
            imported: true)
    }

    private static func importDirectoryPack(
        from sourceURL: URL,
        to packURL: URL,
        packID: String,
        displayName: String,
        fileManager: FileManager) throws -> PetPackManifest
    {
        let filesURL = packURL.appendingPathComponent("files", isDirectory: true)
        if fileManager.fileExists(atPath: filesURL.path) {
            try fileManager.removeItem(at: filesURL)
        }
        try fileManager.copyItem(at: sourceURL, to: filesURL)

        guard let modelRelativePath = self.findModelDefinition(in: filesURL, fileManager: fileManager) else {
            throw NSError(
                domain: "KinkoClaw.Live2DModelLibrary",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "文件夹导入需要包含 .model3.json 或 .model.json。若只有 moc3，请先打包为 ZIP 再导入。",
                ])
        }

        let previewRelativePath = self.findPreviewImage(in: filesURL, fileManager: fileManager)

        return self.buildManifest(
            packID: packID,
            displayName: displayName,
            modelPath: "\(self.mountedRootName)/\(packID)/files/\(modelRelativePath)",
            previewImage: previewRelativePath.map { "\(self.mountedRootName)/\(packID)/files/\($0)" },
            imported: true)
    }

    private static func buildManifest(
        packID: String,
        displayName: String,
        modelPath: String,
        previewImage: String?,
        imported: Bool) -> PetPackManifest
    {
        let accent = self.accentPalette[self.stablePaletteIndex(for: packID)]
        let subtitle = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "模型" : displayName
        let personaLabel = imported ? "已导入模型" : "内置模型"

        return PetPackManifest(
            id: packID,
            displayName: displayName,
            accentHex: accent,
            previewImage: previewImage,
            assets: .init(
                hairHex: "#F6B0CF",
                hairShadowHex: "#D85D90",
                skinHex: "#FFF1EC",
                eyeHex: "#5D223D",
                ribbonHex: accent,
                outfitHex: "#5A2142",
                glowHex: "#FFD4E3"),
            animationProfile: .init(
                floatAmplitude: 5,
                floatSpeed: 1.0,
                blinkEvery: 4.8,
                focusSwaySpeed: 0.88,
                thinkingHaloSpeed: 0.82,
                mouthSmoothing: 0.78),
            model: .init(
                modelPath: modelPath,
                textures: [],
                motions: [:],
                expressions: [:]),
            defaultSceneFrame: .neutral,
            dialogueProfile: .init(subtitlePrefix: subtitle),
            interactionProfile: .init(
                personaLabel: personaLabel,
                pointerFollowStrength: 0.24,
                shimmerIntensity: 0.82,
                breathingScale: 1.024))
    }

    private static func humanReadableName(for sourceName: String, isDirectory: Bool) -> String {
        let base = isDirectory ? sourceName : URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        let normalized = base
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "Live2D 模型" : normalized
    }

    private static func uniquePackID(baseName: String, libraryURL: URL, fileManager: FileManager) -> String {
        let slug = self.slugify(baseName)
        var candidate = slug
        var counter = 2
        while fileManager.fileExists(atPath: libraryURL.appendingPathComponent(candidate).path) {
            candidate = "\(slug)-\(counter)"
            counter += 1
        }
        return candidate
    }

    private static func slugify(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let slug = folded
            .replacingOccurrences(of: #"[^a-zA-Z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
        return slug.isEmpty ? "live2d-model" : slug
    }

    private static func stablePaletteIndex(for value: String) -> Int {
        let checksum = value.unicodeScalars.reduce(into: 0) { partial, scalar in
            partial = (partial &* 31 &+ Int(scalar.value)) % 65_521
        }
        return checksum % self.accentPalette.count
    }

    private static func findModelDefinition(in rootURL: URL, fileManager: FileManager) -> String? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants])

        let candidates = (enumerator?.allObjects as? [URL] ?? [])
            .filter {
                let path = $0.lastPathComponent.lowercased()
                return path.hasSuffix(".model3.json") || path.hasSuffix(".model.json")
            }
            .sorted { lhs, rhs in
                lhs.pathComponents.count < rhs.pathComponents.count
            }

        guard let modelURL = candidates.first else { return nil }
        return modelURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
    }

    private static func findPreviewImage(in rootURL: URL, fileManager: FileManager) -> String? {
        let preferredNames = ["preview.png", "avatar.png", "cover.png"]
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])

        let files = (enumerator?.allObjects as? [URL] ?? []).filter {
            $0.pathExtension.lowercased() == "png"
        }

        if let preferred = preferredNames.compactMap({ name in
            files.first(where: { $0.lastPathComponent.lowercased() == name })
        }).first {
            return preferred.path.replacingOccurrences(of: rootURL.path + "/", with: "")
        }

        return files.first?.path.replacingOccurrences(of: rootURL.path + "/", with: "")
    }
}
