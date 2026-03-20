//
//  RealityKitContentDebug.swift
//  SpatialSynesthesia
//
//  Diagnostic helpers for Reality Composer Pro asset loading.
//  Verbose logging is wrapped in #if DEBUG.
//

import Foundation
import RealityKit

// MARK: - Entity hierarchy diagnostic

/// Recursively prints the full entity hierarchy: name, ModelComponent, child count, transform.
func printEntityHierarchy(_ entity: Entity, indent: Int = 0) {
    #if DEBUG
    let prefix = String(repeating: "  ", count: indent)
    let hasModel = entity.components[ModelComponent.self] != nil
    let childCount = entity.children.count
    let typeHint = entity is ModelEntity ? " [ModelEntity]" : ""
    let t = entity.transform
    print("\(prefix)├─ \(entity.name)\(typeHint) | ModelComponent: \(hasModel) | children: \(childCount)")
    print("\(prefix)   position: \(t.translation) | scale: \(t.scale) | rotation: \(t.rotation)")
    for child in entity.children {
        printEntityHierarchy(child, indent: indent + 1)
    }
    #endif
}

/// Prints only entities that have ModelComponent (visible geometry).
func printEntitiesWithModel(_ entity: Entity, path: String = "") {
    #if DEBUG
    let fullPath = path.isEmpty ? entity.name : "\(path)/\(entity.name)"
    if entity.components[ModelComponent.self] != nil {
        let t = entity.transform
        print("  [HAS MODEL] \(fullPath) | pos: \(t.translation) scale: \(t.scale)")
    }
    for child in entity.children {
        printEntitiesWithModel(child, path: fullPath)
    }
    #endif
}

// MARK: - Bundle inspection

/// Logs .usda, .usdc, .usdz resources in the bundle.
func printBundleRealityResources(_ bundle: Bundle) {
    #if DEBUG
    let exts: [String] = ["usda", "usdc", "usdz"]
    let subpath: String? = nil
    for ext in exts {
        guard let urls = bundle.urls(forResourcesWithExtension: ext, subdirectory: subpath) else { continue }
        for url in urls {
            print("  [Bundle] \(url.lastPathComponent)")
        }
    }
    #endif
}
