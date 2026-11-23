import CoreLocation
import Foundation

public struct WeatherSnapshot: Equatable {
    public let locationName: String
    public let temperatureC: Int
    public let highC: Int
    public let lowC: Int
    public let conditionKorean: String
    public let iconCode: String // "sun", "cloud", "rain", "snow", "storm"
    public let updatedAt: Date

    public var compactLine: String {
        "\(locationName) \(temperatureC)° \(conditionKorean) (\(lowC)°/\(highC)°)"
    }
}

/// Free, keyless weather provider backed by CoreLocation + Open-Meteo API.
public final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public private(set) var snapshot: WeatherSnapshot?
    @Published public private(set) var lastError: String?

    public var onUpdate: ((WeatherSnapshot) -> Void)?

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var refreshTimer: Timer?
    private var lastCoords: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780) // Seoul default
    private var lastPlaceName: String = "서울"

    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    deinit {
        refreshTimer?.invalidate()
    }

    public func start() {
        requestLocationAndRefresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.requestLocationAndRefresh()
        }
    }

    private func isLocationAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(iOS)
        return status == .authorizedWhenInUse || status == .authorizedAlways
        #else
        return status == .authorizedAlways
        #endif
    }

    public func requestLocationAndRefresh() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            // Also fetch immediately with default coordinates so dashboard is never blank.
            fetchWeather(lat: lastCoords.latitude, lon: lastCoords.longitude, placeName: lastPlaceName)
        } else if isLocationAuthorized(status) {
            locationManager.requestLocation()
        } else {
            fetchWeather(lat: lastCoords.latitude, lon: lastCoords.longitude, placeName: lastPlaceName)
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if isLocationAuthorized(manager.authorizationStatus) {
            manager.requestLocation()
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lastCoords = loc.coordinate
        geocoder.reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "ko_KR")) { [weak self] placemarks, _ in
            guard let self else { return }
            let place = placemarks?.first?.subLocality
                ?? placemarks?.first?.locality
                ?? placemarks?.first?.administrativeArea
                ?? self.lastPlaceName
            self.lastPlaceName = place
            self.fetchWeather(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, placeName: place)
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        fetchWeather(lat: lastCoords.latitude, lon: lastCoords.longitude, placeName: lastPlaceName)
    }

    private func fetchWeather(lat: Double, lon: Double, placeName: String) {
        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1"
        guard let url = URL(string: urlStr) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { self.lastError = error.localizedDescription }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let temp = current["temperature_2m"] as? Double
            else { return }

            let wmo = current["weather_code"] as? Int ?? 0
            let daily = json["daily"] as? [String: Any]
            let highs = daily?["temperature_2m_max"] as? [Double]
            let lows = daily?["temperature_2m_min"] as? [Double]
            let (desc, icon) = Self.describeWMO(wmo)

            let snap = WeatherSnapshot(
                locationName: placeName,
                temperatureC: Int(round(temp)),
                highC: Int(round(highs?.first ?? temp)),
                lowC: Int(round(lows?.first ?? temp)),
                conditionKorean: desc,
                iconCode: icon,
                updatedAt: Date()
            )
            DispatchQueue.main.async {
                self.snapshot = snap
                self.lastError = nil
                self.onUpdate?(snap)
            }
        }.resume()
    }

    private static func describeWMO(_ code: Int) -> (String, String) {
        switch code {
        case 0: return ("맑음", "sun")
        case 1, 2: return ("구름 조금", "cloud")
        case 3: return ("흐림", "cloud")
        case 45, 48: return ("안개", "cloud")
        case 51, 53, 55, 56, 57: return ("이슬비", "rain")
        case 61, 63, 65, 66, 67, 80, 81, 82: return ("비", "rain")
        case 71, 73, 75, 77, 85, 86: return ("눈", "snow")
        case 95, 96, 99: return ("뇌우", "storm")
        default: return ("흐림", "cloud")
        }
    }
}
