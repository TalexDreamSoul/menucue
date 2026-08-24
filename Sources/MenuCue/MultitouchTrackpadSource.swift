import CoreFoundation
import Darwin
import Foundation

/// A complete immutable contact frame. A frame is emitted only after the private callback
/// buffer has been boundedly copied, so consumers never retain private framework memory.
struct TrackpadSourceFrame: Equatable {
  let deviceID: UInt64
  let isBuiltIn: Bool
  let timestamp: TimeInterval
  let frameNumber: Int32
  let contacts: [TrackpadContact]

  var trackpadFrame: TrackpadFrame {
    TrackpadFrame(
      deviceID: deviceID,
      isBuiltIn: isBuiltIn,
      timestamp: timestamp,
      frameNumber: frameNumber,
      contacts: contacts
    )
  }
}

enum MultitouchTrackpadSourceState: Equatable {
  case disabled
  case starting
  case running(deviceCount: Int)
  case unsupported(reason: String)
  case failed(reason: String)

  var deviceCount: Int {
    if case .running(let count) = self {
      return count
    }
    return 0
  }
}

enum MultitouchTrackpadInvalidationReason: Equatable {
  case deviceRemoved
  case malformedFrame
}

/// Runtime-only bridge to MultitouchSupport. This target intentionally never links the
/// private framework: all symbols are resolved only after the user enables Trackpad.
final class MultitouchTrackpadSource {
  typealias FrameHandler = (TrackpadSourceFrame) -> Void
  typealias InvalidFrameHandler = (UInt64, MultitouchTrackpadInvalidationReason) -> Void
  typealias StateHandler = (MultitouchTrackpadSourceState) -> Void

  /// MultitouchSupport contact buffers are private and version-sensitive. Current Apple
  /// Silicon observations use 96-byte records. We copy opaque records of that exact stride
  /// and decode only the fields validated below; a changed stride disables capture instead
  /// of interpreting adjacent memory as contact data.
  private static let privateContactStride = 96
  private static let maximumContactsPerFrame = 16
  fileprivate static let frameworkPath =
    "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

  private let deliveryQueue: DispatchQueue
  private let lifecycleLock = NSLock()
  private let frameHandler: FrameHandler
  private let invalidFrameHandler: InvalidFrameHandler

  private var stateHandler: StateHandler?
  private var wantsCapture = false
  private var acceptsFrames = false
  private var generation = 0
  private var callbackDevices: [UInt: SourceDeviceIdentity] = [:]
  private var symbols: MultitouchSymbols?
  private var deviceList: CFArray?
  private var registrations: [UInt64: RegisteredDevice] = [:]

  private(set) var state: MultitouchTrackpadSourceState = .disabled {
    didSet {
      guard oldValue != state else { return }
      stateHandler?(state)
    }
  }

  init(
    deliveryQueue: DispatchQueue? = nil,
    frameHandler: @escaping FrameHandler,
    invalidFrameHandler: InvalidFrameHandler? = nil,
    stateHandler: StateHandler? = nil
  ) {
    self.deliveryQueue = deliveryQueue ?? DispatchQueue(
      label: "com.tagzxia.app.menucue.trackpad.frames",
      qos: .userInteractive
    )
    self.frameHandler = frameHandler
    self.invalidFrameHandler = invalidFrameHandler ?? { _, _ in }
    self.stateHandler = stateHandler
  }

  deinit {
    stop()
  }

  func setStateHandler(_ handler: StateHandler?) {
    stateHandler = handler
  }

  /// Starts capture once. Repeating this call only reconciles the current device set.
  func start() {
    wantsCapture = true
    guard registrations.isEmpty else {
      reconcile()
      return
    }
    beginCapture(reusingLoadedSymbols: false)
  }

  /// Releases every registered callback before the device list or dlopen handle can go away.
  func stop() {
    wantsCapture = false
    notifyInvalidatedDevices(Set(registrations.keys))
    invalidateFrames()
    tearDownCapture(releaseSymbols: true)
    transition(to: .disabled)
  }

  /// Re-enumerates devices. Identical stable device IDs keep their existing callbacks;
  /// a changed set is atomically stopped and rebuilt to avoid duplicate callbacks.
  func reconcile(force: Bool = false) {
    guard wantsCapture else { return }
    guard let symbols else {
      beginCapture(reusingLoadedSymbols: false)
      return
    }

    guard let discovery = discoverDevices(using: symbols) else {
      notifyInvalidatedDevices(Set(registrations.keys))
      invalidateFrames()
      tearDownCapture(releaseSymbols: false)
      transition(to: .unsupported(reason: "No compatible trackpad was found."))
      return
    }

    let discoveredDevices = Dictionary(
      uniqueKeysWithValues: discovery.devices.map { ($0.id, $0) }
    )
    let activeIDs = Set(registrations.keys)
    let topologyUnchanged = !force
      && activeIDs == Set(discoveredDevices.keys)
      && activeIDs.allSatisfy { deviceID in
        guard let active = registrations[deviceID], let discovered = discoveredDevices[deviceID] else {
          return false
        }
        return active.device == discovered.device && active.isBuiltIn == discovered.isBuiltIn
      }
    guard !topologyUnchanged else {
      // `discovery.list` is independently retained by Create; letting it go here keeps
      // the list retained by the active callback registrations alive and avoids restarts.
      transition(to: .running(deviceCount: registrations.count))
      return
    }

    notifyInvalidatedDevices(activeIDs)
    invalidateFrames()
    tearDownCapture(releaseSymbols: false)
    beginCapture(with: discovery, using: symbols)
  }

  private func notifyInvalidatedDevices(_ deviceIDs: Set<UInt64>) {
    guard !deviceIDs.isEmpty else { return }
    deliveryQueue.async { [weak self] in
      guard let self else { return }
      for deviceID in deviceIDs {
        self.invalidFrameHandler(deviceID, .deviceRemoved)
      }
    }
  }

  /// A user-visible retry is also the safe recovery path after a wake or symbol failure.
  func retry() {
    guard wantsCapture else { return }
    notifyInvalidatedDevices(Set(registrations.keys))
    invalidateFrames()
    tearDownCapture(releaseSymbols: true)
    beginCapture(reusingLoadedSymbols: false)
  }

  private func beginCapture(reusingLoadedSymbols: Bool) {
    transition(to: .starting)
    guard MemoryLayout<MTPrivateContactStorage>.stride == Self.privateContactStride else {
      transition(to: .unsupported(reason: "The trackpad contact layout is unsupported on this Mac."))
      return
    }

    let symbols: MultitouchSymbols
    if reusingLoadedSymbols, let existing = self.symbols {
      symbols = existing
    } else {
      guard let loaded = MultitouchSymbols.load() else {
        transition(to: .unsupported(reason: "Raw trackpad input is unavailable on this macOS version."))
        return
      }
      self.symbols = loaded
      symbols = loaded
    }

    guard let discovery = discoverDevices(using: symbols) else {
      transition(to: .unsupported(reason: "No compatible trackpad was found."))
      return
    }
    beginCapture(with: discovery, using: symbols)
  }

  private func beginCapture(
    with discovery: DeviceDiscovery,
    using symbols: MultitouchSymbols
  ) {
    transition(to: .starting)

    var registered: [DeviceDescriptor] = []
    var started: [DeviceDescriptor] = []
    for descriptor in discovery.devices {
      symbols.registerCallback(descriptor.device, multitouchFrameCallback)
      registered.append(descriptor)
      symbols.start(descriptor.device, 0)
      started.append(descriptor)
    }

    guard !started.isEmpty else {
      cleanUp(registered: registered, started: started, using: symbols)
      transition(to: .unsupported(reason: "No compatible trackpad was found."))
      return
    }

    deviceList = discovery.list
    registrations = Dictionary(
      uniqueKeysWithValues: started.map { descriptor in
        (descriptor.id, RegisteredDevice(device: descriptor.device, isBuiltIn: descriptor.isBuiltIn))
      }
    )
    let callbackDevices = Dictionary(
      uniqueKeysWithValues: started.map {
        (UInt(bitPattern: $0.device), SourceDeviceIdentity(id: $0.id, isBuiltIn: $0.isBuiltIn))
      }
    )
    MultitouchCallbackRegistry.install(
      source: self,
      deviceAddresses: Set(callbackDevices.keys)
    )
    beginAcceptingFrames(callbackDevices: callbackDevices)
    transition(to: .running(deviceCount: registrations.count))
  }

  private func cleanUp(
    registered: [DeviceDescriptor],
    started: [DeviceDescriptor],
    using symbols: MultitouchSymbols
  ) {
    for descriptor in started.reversed() {
      _ = symbols.stop(descriptor.device, 0)
    }
    for descriptor in registered.reversed() {
      _ = symbols.unregisterCallback(descriptor.device, multitouchFrameCallback)
    }
  }

  private func tearDownCapture(releaseSymbols: Bool) {
    guard let symbols else {
      deviceList = nil
      registrations.removeAll()
      return
    }

    let activeRegistrations = registrations
    MultitouchCallbackRegistry.remove(
      source: self,
      deviceAddresses: Set(activeRegistrations.values.map { UInt(bitPattern: $0.device) })
    )
    for registration in activeRegistrations.values {
      _ = symbols.stop(registration.device, 0)
    }
    for registration in activeRegistrations.values {
      _ = symbols.unregisterCallback(registration.device, multitouchFrameCallback)
    }
    registrations.removeAll()
    deviceList = nil
    if releaseSymbols {
      self.symbols = nil
    }
  }

  private func discoverDevices(using symbols: MultitouchSymbols) -> DeviceDiscovery? {
    guard let list = symbols.createDeviceList()?.takeRetainedValue() else { return nil }

    var seenIDs = Set<UInt64>()
    var devices: [DeviceDescriptor] = []
    let count = CFArrayGetCount(list)
    for index in 0..<count {
      guard let opaqueDevice = CFArrayGetValueAtIndex(list, index) else { continue }
      let device = UnsafeMutableRawPointer(mutating: opaqueDevice)
      var deviceID: UInt64 = 0
      let status = symbols.deviceID(device, &deviceID)
      if status != 0 || deviceID == 0 {
        deviceID = UInt64(UInt(bitPattern: device))
      }
      guard seenIDs.insert(deviceID).inserted else { continue }

      devices.append(
        DeviceDescriptor(
          id: deviceID,
          device: device,
          isBuiltIn: symbols.isBuiltIn(device)
        )
      )
    }

    guard !devices.isEmpty else { return nil }
    return DeviceDiscovery(list: list, devices: devices)
  }

  fileprivate func receive(
    device: MTDevice?,
    rawContacts: UnsafeMutableRawPointer?,
    contactCount: Int32,
    timestamp: Double,
    frameNumber: Int32
  ) {
    guard let device else { return }

    let currentGeneration: Int
    let sourceDevice: SourceDeviceIdentity?
    lifecycleLock.lock()
    currentGeneration = generation
    let canAccept = acceptsFrames
    sourceDevice = callbackDevices[UInt(bitPattern: device)]
    lifecycleLock.unlock()
    guard canAccept, let sourceDevice else { return }

    guard timestamp.isFinite, contactCount >= 0,
      contactCount <= Int32(Self.maximumContactsPerFrame)
    else {
      discardMalformedFrame(deviceID: sourceDevice.id)
      return
    }
    guard let contacts = copyContacts(rawContacts, count: Int(contactCount)) else {
      discardMalformedFrame(deviceID: sourceDevice.id)
      return
    }
    let frame = TrackpadSourceFrame(
      deviceID: sourceDevice.id,
      isBuiltIn: sourceDevice.isBuiltIn,
      timestamp: timestamp,
      frameNumber: frameNumber,
      contacts: contacts
    )

    deliveryQueue.async { [weak self] in
      guard let self, self.isCurrent(generation: currentGeneration) else { return }
      self.frameHandler(frame)
    }
  }

  private func discardMalformedFrame(deviceID: UInt64) {
    let invalidGeneration: Int
    lifecycleLock.lock()
    generation &+= 1
    invalidGeneration = generation
    lifecycleLock.unlock()
    deliveryQueue.async { [weak self] in
      guard let self, self.isCurrent(generation: invalidGeneration) else { return }
      self.invalidFrameHandler(deviceID, .malformedFrame)
    }
  }

  private func copyContacts(
    _ rawContacts: UnsafeMutableRawPointer?,
    count: Int
  ) -> [TrackpadContact]? {
    guard count == 0 || rawContacts != nil else { return nil }
    guard count <= Self.maximumContactsPerFrame else { return nil }
    guard count > 0 else { return [] }

    let source = UnsafeRawPointer(rawContacts!)
    var contacts: [TrackpadContact] = []
    contacts.reserveCapacity(count)
    for index in 0..<count {
      let record = source.advanced(by: index * Self.privateContactStride)
      guard let contact = MTPrivateContactStorage.decode(record) else {
        // An unknown state cannot safely be treated as a lift or active touch. Drop the
        // whole frame so it cannot complete a gesture against stale contacts.
        return nil
      }
      contacts.append(contact)
    }
    return contacts
  }

  private func beginAcceptingFrames(callbackDevices: [UInt: SourceDeviceIdentity]) {
    lifecycleLock.lock()
    generation &+= 1
    self.callbackDevices = callbackDevices
    acceptsFrames = true
    lifecycleLock.unlock()
  }

  private func invalidateFrames() {
    lifecycleLock.lock()
    generation &+= 1
    acceptsFrames = false
    callbackDevices.removeAll()
    lifecycleLock.unlock()
  }

  private func isCurrent(generation expectedGeneration: Int) -> Bool {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    return acceptsFrames && generation == expectedGeneration
  }

  private func transition(to nextState: MultitouchTrackpadSourceState) {
    state = nextState
  }
}

private struct MTPrivateContactStorage {
  // Keeping twelve 64-bit words makes the private record stride explicit and stable in
  // Swift. Individual fields are loaded unaligned at observed ABI offsets below.
  private var word0: UInt64 = 0
  private var word1: UInt64 = 0
  private var word2: UInt64 = 0
  private var word3: UInt64 = 0
  private var word4: UInt64 = 0
  private var word5: UInt64 = 0
  private var word6: UInt64 = 0
  private var word7: UInt64 = 0
  private var word8: UInt64 = 0
  private var word9: UInt64 = 0
  private var word10: UInt64 = 0
  private var word11: UInt64 = 0

  static func decode(_ record: UnsafeRawPointer) -> TrackpadContact? {
    let id = record.loadUnaligned(fromByteOffset: 16, as: Int32.self)
    let rawState = record.loadUnaligned(fromByteOffset: 20, as: Int32.self)
    guard let state = TrackpadContactState(rawValue: rawState), state != .unknown else {
      return nil
    }

    let x = Double(record.loadUnaligned(fromByteOffset: 32, as: Float.self))
    let y = Double(record.loadUnaligned(fromByteOffset: 36, as: Float.self))
    let velocityX = Double(record.loadUnaligned(fromByteOffset: 40, as: Float.self))
    let velocityY = Double(record.loadUnaligned(fromByteOffset: 44, as: Float.self))
    let size = Double(record.loadUnaligned(fromByteOffset: 48, as: Float.self))
    let majorAxis = Double(record.loadUnaligned(fromByteOffset: 60, as: Float.self))
    let minorAxis = Double(record.loadUnaligned(fromByteOffset: 64, as: Float.self))
    let density = Double(record.loadUnaligned(fromByteOffset: 92, as: Float.self))

    guard x.isFinite, y.isFinite, velocityX.isFinite, velocityY.isFinite,
      size.isFinite, majorAxis.isFinite, minorAxis.isFinite, density.isFinite
    else { return nil }

    return TrackpadContact(
      id: id,
      state: state,
      position: TrackpadPoint(x: x, y: y),
      velocity: TrackpadPoint(x: velocityX, y: velocityY),
      size: size,
      density: density,
      majorAxis: majorAxis,
      minorAxis: minorAxis
    )
  }

}
private typealias MTDevice = UnsafeMutableRawPointer
private typealias MTFrameCallback = @convention(c) (
  MTDevice?,
  UnsafeMutableRawPointer?,
  Int32,
  Double,
  Int32
) -> Int32
private typealias MTDeviceCreateList = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterContactFrameCallback = @convention(c) (MTDevice, MTFrameCallback) -> Void
private typealias MTUnregisterContactFrameCallback = @convention(c) (MTDevice, MTFrameCallback) -> Void
private typealias MTDeviceStart = @convention(c) (MTDevice, Int32) -> Void
private typealias MTDeviceStop = @convention(c) (MTDevice, Int32) -> Void
private typealias MTDeviceGetDeviceID = @convention(c) (MTDevice, UnsafeMutablePointer<UInt64>) -> Int32
private typealias MTDeviceIsBuiltIn = @convention(c) (MTDevice) -> Bool

private final class MultitouchSymbols {
  let handle: UnsafeMutableRawPointer
  let createDeviceList: MTDeviceCreateList
  let registerCallback: MTRegisterContactFrameCallback
  let unregisterCallback: MTUnregisterContactFrameCallback
  let start: MTDeviceStart
  let stop: MTDeviceStop
  let deviceID: MTDeviceGetDeviceID
  let isBuiltIn: MTDeviceIsBuiltIn

  private init(
    handle: UnsafeMutableRawPointer,
    createDeviceList: @escaping MTDeviceCreateList,
    registerCallback: @escaping MTRegisterContactFrameCallback,
    unregisterCallback: @escaping MTUnregisterContactFrameCallback,
    start: @escaping MTDeviceStart,
    stop: @escaping MTDeviceStop,
    deviceID: @escaping MTDeviceGetDeviceID,
    isBuiltIn: @escaping MTDeviceIsBuiltIn
  ) {
    self.handle = handle
    self.createDeviceList = createDeviceList
    self.registerCallback = registerCallback
    self.unregisterCallback = unregisterCallback
    self.start = start
    self.stop = stop
    self.deviceID = deviceID
    self.isBuiltIn = isBuiltIn
  }

  deinit {
    dlclose(handle)
  }

  static func load() -> MultitouchSymbols? {
    guard let handle = dlopen(MultitouchTrackpadSource.frameworkPath, RTLD_LAZY | RTLD_LOCAL) else {
      return nil
    }

    guard
      let createDeviceList: MTDeviceCreateList = symbol("MTDeviceCreateList", from: handle),
      let registerCallback: MTRegisterContactFrameCallback = symbol(
        "MTRegisterContactFrameCallback", from: handle),
      let unregisterCallback: MTUnregisterContactFrameCallback = symbol(
        "MTUnregisterContactFrameCallback", from: handle),
      let start: MTDeviceStart = symbol("MTDeviceStart", from: handle),
      let stop: MTDeviceStop = symbol("MTDeviceStop", from: handle),
      let deviceID: MTDeviceGetDeviceID = symbol("MTDeviceGetDeviceID", from: handle),
      let isBuiltIn: MTDeviceIsBuiltIn = symbol("MTDeviceIsBuiltIn", from: handle)
    else {
      dlclose(handle)
      return nil
    }

    return MultitouchSymbols(
      handle: handle,
      createDeviceList: createDeviceList,
      registerCallback: registerCallback,
      unregisterCallback: unregisterCallback,
      start: start,
      stop: stop,
      deviceID: deviceID,
      isBuiltIn: isBuiltIn
    )
  }

  private static func symbol<T>(_ name: String, from handle: UnsafeMutableRawPointer) -> T? {
    guard let address = dlsym(handle, name) else { return nil }
    return unsafeBitCast(address, to: T.self)
  }
}

private struct DeviceDescriptor {
  let id: UInt64
  let device: MTDevice
  let isBuiltIn: Bool
}

private struct SourceDeviceIdentity {
  let id: UInt64
  let isBuiltIn: Bool
}

private struct RegisteredDevice {
  let device: MTDevice
  let isBuiltIn: Bool
}

private struct DeviceDiscovery {
  let list: CFArray
  let devices: [DeviceDescriptor]
}

private final class WeakMultitouchSource {
  weak var value: MultitouchTrackpadSource?

  init(_ value: MultitouchTrackpadSource) {
    self.value = value
  }
}

private enum MultitouchCallbackRegistry {
  private static let lock = NSLock()
  private static var sources: [UInt: WeakMultitouchSource] = [:]

  static func install(source: MultitouchTrackpadSource, deviceAddresses: Set<UInt>) {
    lock.lock()
    defer { lock.unlock() }
    for address in deviceAddresses {
      sources[address] = WeakMultitouchSource(source)
    }
  }

  static func remove(source: MultitouchTrackpadSource, deviceAddresses: Set<UInt>) {
    lock.lock()
    defer { lock.unlock() }
    for address in deviceAddresses where sources[address]?.value === source {
      sources.removeValue(forKey: address)
    }
  }

  static func deliver(
    device: MTDevice?,
    rawContacts: UnsafeMutableRawPointer?,
    contactCount: Int32,
    timestamp: Double,
    frameNumber: Int32
  ) {
    guard let device else { return }
    let address = UInt(bitPattern: device)
    lock.lock()
    let source = sources[address]?.value
    if source == nil {
      sources.removeValue(forKey: address)
    }
    lock.unlock()
    source?.receive(
      device: device,
      rawContacts: rawContacts,
      contactCount: contactCount,
      timestamp: timestamp,
      frameNumber: frameNumber
    )
  }
}

private let multitouchFrameCallback: MTFrameCallback = {
  device,
  rawContacts,
  contactCount,
  timestamp,
  frameNumber in
  MultitouchCallbackRegistry.deliver(
    device: device,
    rawContacts: rawContacts,
    contactCount: contactCount,
    timestamp: timestamp,
    frameNumber: frameNumber
  )
  return 0
}
