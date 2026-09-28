import SwiftUI
import Foundation

#if canImport(UIKit)
import UIKit

struct SessionSharePresenter: View {
    @Binding var request: SessionShareRequest?
    let onPresented: (UUID) -> Void
    let onOutcome: (SessionShareOutcome, UUID) -> Void

    var body: some View {
        Color.clear
            .overlay(
                ActivitySharePresenter(
                    request: $request,
                    onPresented: onPresented,
                    onOutcome: onOutcome
                )
            )
            .allowsHitTesting(false)
    }
}

private final class SessionShareItemSource: NSObject, UIActivityItemSource {
    private let archiveURL: URL
    private let subject: String

    init(archiveURL: URL, subject: String) {
        self.archiveURL = archiveURL
        self.subject = subject
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        archiveURL
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        archiveURL
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        subject
    }
}

private struct ActivitySharePresenter: UIViewControllerRepresentable {
    @Binding var request: SessionShareRequest?
    let onPresented: (UUID) -> Void
    let onOutcome: (SessionShareOutcome, UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(request: $request, onPresented: onPresented, onOutcome: onOutcome)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let request else {
            return
        }
        guard context.coordinator.lastPresentedID != request.id else {
            return
        }
        guard uiViewController.presentedViewController == nil,
              uiViewController.view.window != nil else {
            return
        }

        let itemSource = SessionShareItemSource(archiveURL: request.archiveURL, subject: request.subject)
        let activityViewController = UIActivityViewController(activityItems: [itemSource], applicationActivities: nil)
        activityViewController.completionWithItemsHandler = { _, completed, _, activityError in
            DispatchQueue.main.async {
                if activityError != nil {
                    context.coordinator.finish(.failed, requestID: request.id)
                } else if completed {
                    context.coordinator.finish(.completed, requestID: request.id)
                } else {
                    context.coordinator.finish(.cancelled, requestID: request.id)
                }
            }
        }

        if let popover = activityViewController.popoverPresentationController {
            popover.sourceView = uiViewController.view
            popover.sourceRect = uiViewController.view.bounds
            popover.permittedArrowDirections = [.up, .down]
        }

        let coordinator = context.coordinator
        coordinator.lastPresentedID = request.id
        uiViewController.present(activityViewController, animated: true) {
            coordinator.onPresented(request.id)
        }
    }

    final class Coordinator: NSObject {
        var request: Binding<SessionShareRequest?>
        let onPresented: (UUID) -> Void
        let onOutcome: (SessionShareOutcome, UUID) -> Void
        var lastPresentedID: UUID?

        init(
            request: Binding<SessionShareRequest?>,
            onPresented: @escaping (UUID) -> Void,
            onOutcome: @escaping (SessionShareOutcome, UUID) -> Void
        ) {
            self.request = request
            self.onPresented = onPresented
            self.onOutcome = onOutcome
        }

        func finish(_ outcome: SessionShareOutcome, requestID: UUID) {
            guard lastPresentedID == requestID else { return }
            if request.wrappedValue?.id == requestID { request.wrappedValue = nil }
            lastPresentedID = nil
            onOutcome(outcome, requestID)
        }
    }
}

#elseif os(macOS)
import AppKit

struct SessionSharePresenter: View {
    @Binding var request: SessionShareRequest?
    let onPresented: (UUID) -> Void
    let onOutcome: (SessionShareOutcome, UUID) -> Void

    var body: some View {
        Color.clear
            .overlay(
                MacSharePickerPresenter(
                    request: $request,
                    onPresented: onPresented,
                    onOutcome: onOutcome
                )
            )
            .allowsHitTesting(false)
    }
}

private struct MacSharePickerPresenter: NSViewRepresentable {
    @Binding var request: SessionShareRequest?
    let onPresented: (UUID) -> Void
    let onOutcome: (SessionShareOutcome, UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(request: $request, onPresented: onPresented, onOutcome: onOutcome)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let request else {
            return
        }
        guard context.coordinator.lastPresentedID != request.id else {
            return
        }
        guard nsView.window != nil else {
            return
        }

        context.coordinator.pickerOwners.removeAll()
        context.coordinator.serviceOwners.removeAll()
        context.coordinator.currentRequest = request
        context.coordinator.lastPresentedID = request.id
        context.coordinator.didChooseService = false

        let coordinator = context.coordinator
        let picker = NSSharingServicePicker(items: [request.archiveURL])
        coordinator.pickerOwners[ObjectIdentifier(picker)] = request.id
        picker.delegate = coordinator
        picker.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .maxY)
        Task { @MainActor in
            await Task.yield()
            coordinator.onPresented(request.id)
        }
    }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        var request: Binding<SessionShareRequest?>
        let onPresented: (UUID) -> Void
        let onOutcome: (SessionShareOutcome, UUID) -> Void
        var currentRequest: SessionShareRequest?
        var lastPresentedID: UUID?
        var didChooseService = false
        var pickerOwners: [ObjectIdentifier: UUID] = [:]
        var serviceOwners: [ObjectIdentifier: UUID] = [:]

        init(
            request: Binding<SessionShareRequest?>,
            onPresented: @escaping (UUID) -> Void,
            onOutcome: @escaping (SessionShareOutcome, UUID) -> Void
        ) {
            self.request = request
            self.onPresented = onPresented
            self.onOutcome = onOutcome
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            sharingServicesForItems items: [Any],
            proposedSharingServices proposedServices: [NSSharingService]
        ) -> [NSSharingService] {
            guard let subject = currentRequest?.subject else {
                return proposedServices
            }
            proposedServices.forEach { $0.subject = subject }
            return proposedServices
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            delegateFor sharingService: NSSharingService
        ) -> NSSharingServiceDelegate? {
            sharingService.subject = currentRequest?.subject
            serviceOwners[ObjectIdentifier(sharingService)] = pickerOwners[ObjectIdentifier(sharingServicePicker)]
            return self
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            didChoose service: NSSharingService?
        ) {
            if service == nil {
                finish(.cancelled, requestID: pickerOwners[ObjectIdentifier(sharingServicePicker)])
            } else {
                didChooseService = true
            }
        }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            finish(.completed, requestID: serviceOwners[ObjectIdentifier(sharingService)])
        }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
            finish(.failed, requestID: serviceOwners[ObjectIdentifier(sharingService)])
        }

        private func finish(_ outcome: SessionShareOutcome, requestID: UUID?) {
            guard let requestID, lastPresentedID == requestID else { return }
            if request.wrappedValue?.id == requestID { request.wrappedValue = nil }
            currentRequest = nil
            lastPresentedID = nil
            didChooseService = false
            pickerOwners = pickerOwners.filter { $0.value != requestID }
            serviceOwners = serviceOwners.filter { $0.value != requestID }
            onOutcome(outcome, requestID)
        }
    }
}
#endif
