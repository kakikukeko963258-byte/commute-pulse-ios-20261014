import Foundation
import CoreLocation
import CoreMotion
import CommuteCore

@MainActor final class SensorClient: NSObject, CLLocationManagerDelegate {
    private let location = CLLocationManager()
    // Instantiate Motion managers only after the user starts real measurement.
    private var activity: CMMotionActivityManager?
    private var motion: CMMotionManager?
    private var evidence: MotionEvidence = .unknown
    private var accelerationWindow: [Double] = []
    private(set) var accelerationRMS = 0.0
    private(set) var running = false
    var onObservation: ((TravelObservation) -> Void)?
    var onStatus: ((String) -> Void)?

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = 20
        location.activityType = .otherNavigation
        location.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        running = true
        location.requestWhenInUseAuthorization()
        startAuthorizedLocation()
        if CMMotionActivityManager.isActivityAvailable() {
            let manager = activity ?? CMMotionActivityManager()
            activity = manager
            manager.startActivityUpdates(to: .main) { [weak self] event in
                guard let event else { return }
                Task { @MainActor in
                    guard let self, self.running else { return }
                    self.evidence = event.walking || event.running ? .pedestrian
                        : event.cycling ? .cycling : event.automotive ? .automotive
                        : event.stationary ? .stationary : .unknown
                }
            }
        }
        let accelerometer = motion ?? CMMotionManager()
        motion = accelerometer
        if accelerometer.isAccelerometerAvailable {
            accelerometer.accelerometerUpdateInterval = 0.2
            accelerometer.startAccelerometerUpdates(to: .main) { [weak self] sample, _ in
                guard let sample else { return }
                let a = sample.acceleration
                let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
                Task { @MainActor in self?.recordAcceleration(magnitude) }
            }
        }
    }

    private func recordAcceleration(_ magnitude: Double) {
        guard running else { return }
        accelerationWindow.append(magnitude)
        if accelerationWindow.count > 25 { accelerationWindow.removeFirst() }
        let mean = accelerationWindow.reduce(0, +) / Double(accelerationWindow.count)
        accelerationRMS = sqrt(accelerationWindow.reduce(0) { $0 + pow($1 - mean, 2) }
                               / Double(accelerationWindow.count))
    }

    /// User requests this separately after the in-use permission.
    func requestBackgroundAuthorization() { location.requestAlwaysAuthorization() }

    func stop() {
        guard running else { return }
        running = false
        location.stopUpdatingLocation()
        activity?.stopActivityUpdates()
        motion?.stopAccelerometerUpdates()
        accelerationWindow.removeAll()
        evidence = .unknown
        accelerationRMS = 0
    }

    private func startAuthorizedLocation() {
        guard running else { return }
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            location.allowsBackgroundLocationUpdates = true
            location.showsBackgroundLocationIndicator = true
            location.startUpdatingLocation()
            onStatus?("位置計測中・加速度は端末内で集計")
        case .denied, .restricted:
            onStatus?("位置情報を利用できません。既にある候補は予定時刻で推定します。")
            emitMissingLocation()
        default: onStatus?("位置情報の許可待ち")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.startAuthorizedLocation() }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let observations = locations.filter { abs($0.timestamp.timeIntervalSinceNow) < 120 }.map { fix in
            TravelObservation(timestamp: fix.timestamp,
                coordinate: Coordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude),
                horizontalAccuracy: fix.horizontalAccuracy >= 0 ? fix.horizontalAccuracy : nil,
                speedMetersPerSecond: fix.speed >= 0 ? fix.speed : nil,
                courseDegrees: fix.course >= 0 ? fix.course : nil)
        }
        Task { @MainActor [weak self] in
            guard let self, self.running else { return }
            for var observation in observations {
                observation.motion = self.evidence
                self.onObservation?(observation)
            }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard self?.running == true else { return }
            self?.onStatus?("GPS取得待ち・予定時刻に基づく推定")
            self?.emitMissingLocation()
        }
    }
    private func emitMissingLocation() {
        onObservation?(TravelObservation(timestamp: .now, motion: evidence))
    }
}
