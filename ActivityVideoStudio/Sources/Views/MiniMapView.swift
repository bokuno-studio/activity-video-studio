import SwiftUI
import MapKit
import CoreLocation

/// Minimap showing the GPS track with current position marker.
struct MiniMapView: NSViewRepresentable {
    let trackCoordinates: [CLLocationCoordinate2D]
    let currentCoordinate: CLLocationCoordinate2D?

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.isZoomEnabled = false
        mapView.isScrollEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        // Update track polyline
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        if trackCoordinates.count >= 2 {
            var coords = trackCoordinates
            let polyline = MKPolyline(coordinates: &coords, count: coords.count)
            mapView.addOverlay(polyline)

            // Fit map to track with padding
            let rect = polyline.boundingMapRect
            let padding = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            mapView.setVisibleMapRect(rect, edgePadding: padding, animated: false)
        }

        // Current position marker
        if let current = currentCoordinate {
            let annotation = MKPointAnnotation()
            annotation.coordinate = current
            mapView.addAnnotation(annotation)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 3
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let identifier = "currentPosition"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            if view == nil {
                view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                // Create a circle marker
                let size: CGFloat = 14
                let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                    NSColor.systemRed.setFill()
                    NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                    NSColor.white.setStroke()
                    let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                    path.lineWidth = 2
                    path.stroke()
                    return true
                }
                view?.image = image
                view?.canShowCallout = false
            }
            view?.annotation = annotation
            return view
        }
    }
}
