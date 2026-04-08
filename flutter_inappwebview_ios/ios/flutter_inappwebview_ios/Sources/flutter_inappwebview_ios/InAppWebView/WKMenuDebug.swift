//
//  WKMenuDebug.swift
//  flutter_inappwebview_ios
//
//  iOS WKWebView 系统文本选择菜单 — 排查埋点（日志 + 辅助函数）。
//

import Foundation
import ObjectiveC
import UIKit
import WebKit

// MARK: - 如何根据日志判断下一步（阅读后再跑真机）
//
// 1) 菜单已出现，但「swizzled canPerformAction / buildMenu」完全没有日志
//    → 说明当前菜单不是走 WKContentView 上这两个入口构建的，或 swizzle 未装上
//    （类名不是 WKContentView、实现落在其它子类、或菜单由系统私有路径直接呈现）。
//
// 2) willPresentEditMenuWithAnimator 从未打印
//    → 系统编辑菜单可能不是通过 WKUIDelegate 这条 iOS 16.4+ 回调触发的；
//    或当前 WebKit/场景未走 UIEditMenuInteraction 的该 delegate 路径。
//
// 3) dumpViewTree 里 UIEditMenuInteraction / UITextInteraction 不在类名含 WKContentView 的 view 上
//    → 交互挂在别的子视图（或后续 WebKit 调整了层级）；应对该 view 单独处理或换 hook 点。
//
// 4) swizzle 日志有、但 InAppWebView 的 override canPerformAction/buildMenu 无日志
//    → 第一响应者仍是 WKContentView，父类 WKWebView 上的 override 未参与本次菜单链。

enum WKMenuDebug {

    private static let prefix = "🔥 [WKMenu]"

    /// 埋点用 selector；必须在 `disableContextMenu` / swizzle 拦截下仍走系统链，否则 `logCurrentFirstResponder` 永远捕不到 FR。
    static func isFirstResponderCaptureDebugAction(_ action: Selector) -> Bool {
        action == #selector(UIResponder.wkMenuDebug_captureFirstResponder)
    }

    /// `true`：WKContentView 上的 swizzle **只打日志并始终调用原始 IMP**，不 return false、不 remove menu。
    /// 用于确认「若完全不拦，菜单是否仍出现」以及原始链是否被调用。
    /// `false`：保持 fork 原有 swizzle 行为（disableContextMenu 时拦截）。
    static var wkContentViewSwizzleObserveOnly = false

    private static var contentViewSwizzleApplied = false

    private static weak var capturedFirstResponder: UIResponder?

    /// 先拼成单行再以 `NSLog("%@", line)` 输出，避免 `message` 中含 `%` 时被当作格式串解析。
    static func log(_ message: String) {
        let line = "\(prefix) \(message)"
        NSLog("%@", line)
    }

    fileprivate static func storeCapturedFirstResponder(_ r: UIResponder) {
        capturedFirstResponder = r
    }

    /// 通过 `sendAction` 捕获当前 first responder 的类名（调试用）。
    static func logCurrentFirstResponder(tag: String) {
        capturedFirstResponder = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.wkMenuDebug_captureFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        let name: String
        if let r = capturedFirstResponder {
            name = NSStringFromClass(type(of: r))
        } else {
            name = "nil"
        }
        log("firstResponder [\(tag)]: \(name)")
    }

    static func allDescendantViews(of root: UIView) -> [UIView] {
        var out: [UIView] = [root]
        for sub in root.subviews {
            out.append(contentsOf: allDescendantViews(of: sub))
        }
        return out
    }

    static func dumpViewTree(scrollView: UIScrollView, tag: String, maxDepth: Int = 16) {
        log("dumpViewTree BEGIN [\(tag)] subviews.count=\(scrollView.subviews.count) maxDepth=\(maxDepth)")

        func dump(_ view: UIView, depth: Int) {
            guard depth <= maxDepth else {
                log("dumpViewTree [\(tag)] ... (truncated at depth \(maxDepth))")
                return
            }
            let pad = String(repeating: "  ", count: depth)
            let interactionTypes: String
            if #available(iOS 13.0, *) {
                interactionTypes = view.interactions
                    .map { NSStringFromClass(type(of: $0)) }
                    .joined(separator: ", ")
            } else {
                interactionTypes = "(iOS<13)"
            }
            log("dumpViewTree [\(tag)] \(pad)\(NSStringFromClass(type(of: view))) interactions=[\(interactionTypes)]")
            for sub in view.subviews {
                dump(sub, depth: depth + 1)
            }
        }

        dump(scrollView, depth: 0)
        log("dumpViewTree END [\(tag)]")
    }

    static func resolveInAppWebView(from view: UIView?) -> InAppWebView? {
        var parent = view?.superview
        while let p = parent {
            if let w = p as? InAppWebView {
                return w
            }
            parent = p.superview
        }
        return nil
    }

    static func applyContentViewMenuSwizzleIfNeeded() {
        log("applyContentViewMenuSwizzleIfNeeded ENTER alreadyApplied=\(contentViewSwizzleApplied) observeOnly=\(wkContentViewSwizzleObserveOnly)")
        guard !contentViewSwizzleApplied else {
            log("applyContentViewMenuSwizzleIfNeeded SKIP (already applied)")
            return
        }
        contentViewSwizzleApplied = true

        guard let wkContentViewClass = NSClassFromString("WKContentView") else {
            log("applyContentViewMenuSwizzleIfNeeded FAIL NSClassFromString(\"WKContentView\") == nil")
            return
        }
        log("applyContentViewMenuSwizzleIfNeeded OK WKContentView class=\(NSStringFromClass(wkContentViewClass))")

        let canPerformSel = #selector(UIResponder.canPerformAction(_:withSender:))
        guard let canPerformMethod = class_getInstanceMethod(wkContentViewClass, canPerformSel) else {
            log("applyContentViewMenuSwizzleIfNeeded FAIL class_getInstanceMethod(canPerformAction:withSender:) == nil")
            return
        }
        let originalCanPerformIMP = method_getImplementation(canPerformMethod)
        log("applyContentViewMenuSwizzleIfNeeded OK canPerformAction originalIMP=\(originalCanPerformIMP)")

        let canPerformBlock: @convention(block) (AnyObject, Selector, Any?) -> Bool = { obj, action, sender in
            let selfCls = NSStringFromClass(type(of: obj))
            let actionStr = NSStringFromSelector(action)
            let senderType: String
            if let s = sender {
                senderType = String(describing: type(of: s as Any))
            } else {
                senderType = "nil"
            }
            let host = resolveInAppWebView(from: obj as? UIView)
            let disabled = host?.settings?.disableContextMenu == true
            log("swizzled canPerformAction self=\(selfCls) action=\(actionStr) senderType=\(senderType) hostInAppWebView=\(host != nil) disableContextMenu=\(String(describing: disabled)) observeOnly=\(wkContentViewSwizzleObserveOnly)")

            if isFirstResponderCaptureDebugAction(action) {
                typealias F = @convention(c) (AnyObject, Selector, Selector, Any?) -> Bool
                let r = unsafeBitCast(originalCanPerformIMP, to: F.self)(obj, canPerformSel, action, sender)
                log("swizzled canPerformAction branch=allowDebugFirstResponderCapture -> \(r)")
                return r
            }

            if wkContentViewSwizzleObserveOnly {
                typealias F = @convention(c) (AnyObject, Selector, Selector, Any?) -> Bool
                let r = unsafeBitCast(originalCanPerformIMP, to: F.self)(obj, canPerformSel, action, sender)
                log("swizzled canPerformAction branch=callOriginal(observeOnly) -> \(r)")
                return r
            }

            if let view = obj as? UIView {
                var parent = view.superview
                while let p = parent {
                    if let webView = p as? InAppWebView,
                       webView.settings?.disableContextMenu == true {
                        log("swizzled canPerformAction branch=BLOCK return false (disableContextMenu)")
                        return false
                    }
                    parent = p.superview
                }
            }
            typealias F = @convention(c) (AnyObject, Selector, Selector, Any?) -> Bool
            let r = unsafeBitCast(originalCanPerformIMP, to: F.self)(obj, canPerformSel, action, sender)
            log("swizzled canPerformAction branch=callOriginal -> \(r)")
            return r
        }
        method_setImplementation(canPerformMethod, imp_implementationWithBlock(canPerformBlock))
        log("applyContentViewMenuSwizzleIfNeeded OK canPerformAction swizzle installed")

        if #available(iOS 13.0, *) {
            let buildMenuSel = #selector(UIResponder.buildMenu(with:))
            guard let buildMenuMethod = class_getInstanceMethod(wkContentViewClass, buildMenuSel) else {
                log("applyContentViewMenuSwizzleIfNeeded FAIL class_getInstanceMethod(buildMenu(with:)) == nil")
                return
            }
            let originalBuildMenuIMP = method_getImplementation(buildMenuMethod)
            log("applyContentViewMenuSwizzleIfNeeded OK buildMenu(with:) originalIMP=\(originalBuildMenuIMP)")

            let buildMenuBlock: @convention(block) (AnyObject, UIMenuBuilder) -> Void = { obj, builder in
                let selfCls = NSStringFromClass(type(of: obj))
                let host = resolveInAppWebView(from: obj as? UIView)
                let disabled = host?.settings?.disableContextMenu == true
                log("swizzled buildMenu self=\(selfCls) hostInAppWebView=\(host != nil) disableContextMenu=\(String(describing: disabled)) observeOnly=\(wkContentViewSwizzleObserveOnly)")

                if wkContentViewSwizzleObserveOnly {
                    typealias F = @convention(c) (AnyObject, Selector, UIMenuBuilder) -> Void
                    log("swizzled buildMenu branch=callOriginal(observeOnly)")
                    unsafeBitCast(originalBuildMenuIMP, to: F.self)(obj, buildMenuSel, builder)
                    return
                }

                if let view = obj as? UIView {
                    var parent = view.superview
                    while let p = parent {
                        if let webView = p as? InAppWebView,
                           webView.settings?.disableContextMenu == true {
                            log("swizzled buildMenu branch=removeSystemMenus+return (disableContextMenu)")
                            builder.remove(menu: .standardEdit)
                            builder.remove(menu: .lookup)
                            builder.remove(menu: .share)
                            builder.remove(menu: .learn)
                            builder.remove(menu: .format)
                            builder.remove(menu: .textStyle)
                            builder.remove(menu: .spelling)
                            builder.remove(menu: .speech)
                            builder.remove(menu: .find)
                            builder.remove(menu: .replace)
                            if #available(iOS 17.0, *) {
                                builder.remove(menu: .autoFill)
                            }
                            return
                        }
                        parent = p.superview
                    }
                }
                typealias F = @convention(c) (AnyObject, Selector, UIMenuBuilder) -> Void
                log("swizzled buildMenu branch=callOriginal")
                unsafeBitCast(originalBuildMenuIMP, to: F.self)(obj, buildMenuSel, builder)
            }
            method_setImplementation(buildMenuMethod, imp_implementationWithBlock(buildMenuBlock))
            log("applyContentViewMenuSwizzleIfNeeded OK buildMenu(with:) swizzle installed")
        }
    }
}

extension UIResponder {
    @objc func wkMenuDebug_captureFirstResponder() {
        WKMenuDebug.storeCapturedFirstResponder(self)
    }
}
