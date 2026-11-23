import SwiftUI

struct PhotoSortMenu: View {
    let order: PhotoOrder
    let inCollection: Bool
    let change: (PhotoOrder) -> Void

    private func binding<Value>(_ key: WritableKeyPath<PhotoOrder, Value>) -> Binding<Value> {
        Binding(get: { order[keyPath: key] }, set: { value in
            var next = order
            next[keyPath: key] = value
            if next.key != order.key { next.descending = next.key != .filename }
            change(next)
        })
    }

    var body: some View {
        Menu {
            Toggle("Group by folder", isOn: binding(\.groupByFolder))
            Divider()
            Picker("Sort by", selection: binding(\.key)) {
                ForEach(PhotoSortKey.allCases.filter { inCollection || $0 != .added }, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }.pickerStyle(.inline)
            Divider()
            Picker("Order", selection: binding(\.descending)) {
                Text(order.key == .filename ? "A to Z" : "Oldest first").tag(false)
                Text(order.key == .filename ? "Z to A" : "Newest first").tag(true)
            }.pickerStyle(.inline)
        } label: {
            HeaderActionLabel(title: "Sort", symbol: "arrow.up.arrow.down")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(order.key.title + (order.groupByFolder ? " within each folder" : " across all folders"))
        .accessibilityLabel("Sort pictures")
    }
}

private struct SortRequest: Equatable {
    let source: PhotoList
    let order: PhotoOrder
}

struct SortedPhotos<Content: View>: View {
    let source: PhotoList
    let sourceOrder: PhotoOrder
    let order: PhotoOrder
    @ViewBuilder let content: (PhotoList) -> Content
    @ViewState private var result: (request: SortRequest, photos: PhotoList)?

    private var request: SortRequest { SortRequest(source: source, order: order) }

    private var visible: PhotoList? {
        if order == sourceOrder { return source }
        guard let result, result.request.source === source else { return nil }
        return result.photos
    }

    var body: some View {
        let progress = order.key == .taken ? "Reading capture dates…" : "Sorting pictures…"
        Group {
            if let visible {
                content(visible).overlay(alignment: .topTrailing) {
                    if order != sourceOrder && result?.request != request {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(progress).font(.caption)
                        }.padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule()).padding(8)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                ProgressView(progress).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.task(id: request) {
            let current = request
            if order == sourceOrder { result = (current, source) }
            else if let sorted = try? await PhotoSorter.shared.sorted(source, by: order), !Task.isCancelled {
                result = (current, sorted)
            }
        }
    }
}
