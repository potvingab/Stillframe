import MapKit
import SwiftUI

struct LocationFilterEditor: View {
    let cancel: () -> Void
    let use: (LocationFilter) -> Void
    @ViewState private var center: PhotoLocation?
    @ViewState private var name: String?
    @ViewState private var radiusKm: Int
    @ViewState private var query = ""
    @ViewState private var results: [Place] = []
    @ViewState private var searchMessage: String?

    private struct Place: Identifiable {
        let id = UUID()
        let center: PhotoLocation
        let name: String?
        let address: String?
    }

    init(initial: LocationFilter?, cancel: @escaping () -> Void, use: @escaping (LocationFilter) -> Void) {
        self.cancel = cancel
        self.use = use
        _center = ViewState(initialValue: initial?.center)
        _name = ViewState(initialValue: initial?.name)
        _radiusKm = ViewState(initialValue: initial?.radiusKm ?? 10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filter by location").font(.headline)
            TextField("Search a place, address, or latitude, longitude", text: $query)
                .textFieldStyle(.roundedBorder)
            FilterAreaMap(area: area) { point in select(point, name: nil) }
                .frame(height: 175).clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .top) { searchResults }
            Text(name ?? center?.coordinateText ?? "Click the map or choose a search result.")
                .font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
            Picker("Radius", selection: $radiusKm) {
                ForEach([1, 5, 10, 25, 50, 100, 250, 500], id: \.self) { km in Text("\(km) km").tag(km) }
            }.fixedSize()
            Divider()
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Button("Use Location") {
                    if let area { use(area) }
                }.disabled(center == nil || !query.isEmpty)
            }
        }.font(.system(size: 12)).controlSize(.small).padding(16).frame(width: 340)
            .task(id: query) { await search(query) }
    }

    private var area: LocationFilter? {
        center.map { LocationFilter(center: $0, name: name, radiusKm: radiusKm) }
    }

    @ViewBuilder private var searchResults: some View {
        if !query.isEmpty && (!results.isEmpty || searchMessage != nil) {
            VStack(alignment: .leading, spacing: 2) {
                if let searchMessage { Text(searchMessage).font(.caption).padding(5) }
                ForEach(results) { place in
                    Button { select(place.center, name: place.name) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.name ?? place.center.coordinateText).lineLimit(1)
                            if let address = place.address, address != place.name {
                                Text(address).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(4)
        }
    }

    private func select(_ point: PhotoLocation, name: String?) {
        center = point
        self.name = name
        query = ""
    }

    private func search(_ input: String) async {
        results = []
        searchMessage = nil
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pair = text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if pair.count == 2, let lat = Double(pair[0]), let lon = Double(pair[1]),
           let point = PhotoLocation(coordinate: .init(latitude: lat, longitude: lon)) {
            results = [Place(center: point, name: nil, address: nil)]
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(400))
            searchMessage = "Searching…"
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            let search = MKLocalSearch(request: request)
            let response = try await search.start()
            try Task.checkCancellation()
            results = response.mapItems.prefix(4).compactMap { item in
                let coordinate: CLLocationCoordinate2D
                let address: String?
                if #available(macOS 26, *) {
                    coordinate = item.location.coordinate
                    address = item.address?.fullAddress
                } else {
                    coordinate = item.placemark.coordinate
                    address = item.placemark.title
                }
                guard let point = PhotoLocation(coordinate: coordinate) else { return nil }
                return Place(center: point, name: item.name, address: address)
            }
            searchMessage = results.isEmpty ? "No places found. Try another search or click the map." : nil
        } catch {
            if !Task.isCancelled { searchMessage = "Place search is unavailable. Click the map or enter coordinates." }
        }
    }
}

private struct FilterAreaMap: NSViewRepresentable {
    let area: LocationFilter?
    let select: (PhotoLocation) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.setVisibleMapRect(.world, animated: false)
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.placePin(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        map.addGestureRecognizer(click)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.select = select
        guard coordinator.displayed != area else { return }
        coordinator.displayed = area
        map.removeAnnotations(map.annotations)
        map.removeOverlays(map.overlays)
        guard let area else { return }
        let point = MKPointAnnotation()
        point.coordinate = area.center.coordinate
        point.title = area.name ?? "Filter center"
        map.addAnnotation(point)
        map.addOverlay(MKCircle(center: point.coordinate, radius: area.meters))
        map.setRegion(MKCoordinateRegion(center: point.coordinate, latitudinalMeters: area.meters * 3,
                                         longitudinalMeters: area.meters * 3), animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var displayed: LocationFilter?
        var select: (PhotoLocation) -> Void
        init(select: @escaping (PhotoLocation) -> Void) { self.select = select }

        @objc func placePin(_ gesture: NSClickGestureRecognizer) {
            guard let map = gesture.view as? MKMapView,
                  let center = PhotoLocation(coordinate: map.convert(gesture.location(in: map), toCoordinateFrom: map)) else { return }
            select(center)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.strokeColor = .controlAccentColor
            renderer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18)
            renderer.lineWidth = 1.5
            return renderer
        }
    }
}
