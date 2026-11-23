import CoreMotion
import Foundation

/// Reads today's live step count and walking distance directly from the iPhone motion coprocessor.
/// Works on Free Personal Apple ID (SideStore) with zero HealthKit entitlement required.
public final class PedometerService: ObservableObject {
    @Published public private(set) var todaySteps: Int = 0
    @Published public private(set) var todayDistanceMeters: Double = 0
    @Published public private(set) var isAvailable: Bool = CMPedometer.isStepCountingAvailable()

    public var onUpdate: (() -> Void)?

    private let pedometer = CMPedometer()

    public init() {}

    deinit {
        pedometer.stopUpdates()
    }

    public func start() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        let startOfDay = Calendar.current.startOfDay(for: Date())

        pedometer.queryPedometerData(from: startOfDay, to: Date()) { [weak self] data, _ in
            guard let self, let data else { return }
            DispatchQueue.main.async {
                self.todaySteps = data.numberOfSteps.intValue
                self.todayDistanceMeters = data.distance?.doubleValue ?? 0
                self.onUpdate?()
            }
        }

        pedometer.startUpdates(from: startOfDay) { [weak self] data, _ in
            guard let self, let data else { return }
            DispatchQueue.main.async {
                self.todaySteps = data.numberOfSteps.intValue
                self.todayDistanceMeters = data.distance?.doubleValue ?? 0
                self.onUpdate?()
            }
        }
    }

    public var formattedDistanceKm: String {
        String(format: "%.1fkm", todayDistanceMeters / 1000.0)
    }
}
