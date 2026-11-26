import MapKit
import SwiftUI

struct MappedPictures {
    var places: [PhotoLocation: [Photo]] = [:]
    var count = 0
}

extension PhotoSorter {
    func mappedPictures(in photos: PhotoList) throws -> MappedPictures {
        loadDatesIfNeeded()
        defer { saveDatesIfNeeded() }
        var result = MappedPictures()
        for photo in photos {
            try Task.checkCancellation()
            if let location = facts(of: photo)?.location {
                result.places[location, default: []].append(photo)
                result.count += 1
            }
        }
        return result
    }
}

struct PictureMapAccess: ViewModifier {
    let photos: PhotoList
    let open: (Photo) -> Void
    @ViewState private var showing = false

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(id: "picture-map", placement: .navigation) {
                HeaderAction(title: "Maps", symbol: "map") { showing = true }
                    .padding(.horizontal, 8)
                    .help("Show these pictures on a map")
            }.withoutSharedGlass()
        }.sheet(isPresented: $showing) {
            PictureMapSheet(photos: photos, open: { photo in
                showing = false
                open(photo)
            })
        }
    }
}

private struct PictureMapSheet: View {
    let photos: PhotoList
    let open: (Photo) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var result: (source: PhotoList, pictures: MappedPictures)?
    @ViewState private var selected: [Photo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeading(title: "Picture map")
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
            }
            if let result, result.source === photos {
                if result.pictures.places.isEmpty {
                    EmptyPanel(title: "No locations found", detail: "Pictures with embedded GPS coordinates appear here.") {
                        EmptyGlyph(symbol: "map")
                    } actions: { EmptyView() }
                } else {
                    Text("\(result.pictures.count) of \(countText(photos.count, "picture")) geotagged")
                        .font(.callout).foregroundStyle(Palette.secondary)
                    PictureLocationsMap(pictures: result.pictures) { selected = $0 }
                        .id(ObjectIdentifier(photos))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    if selected.isEmpty {
                        Text("Select a pin to see its pictures.")
                            .font(.callout).foregroundStyle(Palette.secondary)
                            .frame(height: 64)
                    } else {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 10) {
                                ForEach(selected) { photo in
                                    Button { open(photo) } label: {
                                        HStack(spacing: 8) {
                                            FileImage(url: photo.url, modified: photo.modified)
                                                .frame(width: 66, height: 48).clipShape(RoundedRectangle(cornerRadius: 4))
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(photo.url.lastPathComponent).font(.headline)
                                                Text(photo.url.deletingLastPathComponent().lastPathComponent)
                                                    .font(.caption).foregroundStyle(Palette.secondary)
                                            }.lineLimit(1).truncationMode(.middle).frame(maxWidth: 156, alignment: .leading)
                                        }.padding(5).background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                                    }.buttonStyle(.plain).help("Open " + photo.url.path)
                                }
                            }.padding(.vertical, 2)
                        }.frame(height: 64)
                    }
                }
            } else {
                ProgressView("Reading picture locations…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(18).frame(width: 660, height: 460).foregroundStyle(Palette.ink).background(Palette.paper)
            .task(id: photos) {
                selected = []
                if let pictures = try? await PhotoSorter.shared.mappedPictures(in: photos), !Task.isCancelled {
                    result = (photos, pictures)
                }
            }
    }
}

private final class PicturePin: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let photos: [Photo]

    init(location: PhotoLocation, photos: [Photo]) {
        coordinate = location.coordinate
        self.photos = photos
    }
    var title: String? { photos.count == 1 ? photos.first?.url.lastPathComponent : countText(photos.count, "picture") }
}

struct PictureLocationsMap: NSViewRepresentable {
    let pictures: MappedPictures
    let select: ([Photo]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsZoomControls = true
        map.pointOfInterestFilter = .excludingAll
        let pins = pictures.places.map { PicturePin(location: $0.key, photos: $0.value) }
        map.addAnnotations(pins)
        if pins.count == 1, let pin = pins.first {
            map.setRegion(MKCoordinateRegion(center: pin.coordinate, latitudinalMeters: 2400, longitudinalMeters: 2400), animated: false)
        } else {
            map.showAnnotations(pins, animated: false)
        }
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) { context.coordinator.select = select }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var select: ([Photo]) -> Void
        init(select: @escaping ([Photo]) -> Void) { self.select = select }

        private func pins(in annotation: MKAnnotation?) -> [PicturePin] {
            if let cluster = annotation as? MKClusterAnnotation { return cluster.memberAnnotations.compactMap { $0 as? PicturePin } }
            return (annotation as? PicturePin).map { [$0] } ?? []
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let members = pins(in: annotation)
            guard !members.isEmpty else { return nil }
            let cluster = annotation is MKClusterAnnotation
            let key = cluster ? "PictureCluster" : "PicturePin"
            let marker = mapView.dequeueReusableAnnotationView(withIdentifier: key) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: key)
            marker.annotation = annotation
            marker.clusteringIdentifier = cluster ? nil : "Pictures"
            let count = members.reduce(0) { $0 + $1.photos.count }
            marker.glyphImage = count == 1 ? NSImage(systemSymbolName: "photo", accessibilityDescription: nil) : nil
            marker.glyphText = count > 1 ? String(count) : nil
            marker.setAccessibilityLabel(countText(count, "picture"))
            return marker
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            select(pins(in: view.annotation).flatMap(\.photos))
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            if mapView.selectedAnnotations.isEmpty { select([]) }
        }
    }
}
