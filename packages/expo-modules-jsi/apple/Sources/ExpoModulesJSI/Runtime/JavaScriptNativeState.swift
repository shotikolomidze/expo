internal import ExpoModulesJSI_Cxx
internal import jsi

/// Base class for JS object's native state.
open class JavaScriptNativeState {
  /// Public-facing factory: builds a heap-allocated `expo::NativeStateShared`
  /// wrapping a `jsi::NativeState` subclass that derives from `expo::NativeState`.
  /// The factory is invoked lazily by `acquireShared` — i.e. only when the wrapper
  /// is about to be attached to a JS object. Lazy invocation matters because the
  /// factory's pointee may carry side-effecting destructors (e.g. SharedObject's
  /// releaser) that must not fire until JSI has taken ownership.
  ///
  /// Each invocation gets a fresh Swift context (a retained `Unmanaged` pointer to
  /// the wrapper) plus a deallocator that releases that pointer when the C++
  /// pointee dies. Both must be forwarded to the produced pointee.
  public typealias Factory = (
    _ context: UnsafeMutableRawPointer,
    _ deallocator: @convention(c) (UnsafeMutableRawPointer?) -> Void
  ) -> UnsafeMutableRawPointer

  /// Internal factory shape used by `acquireShared`. Returns the shared_ptr by value
  /// so the default `init()` can use a built-in materialization without going through
  /// a heap allocation; `init(adoptingFactory:)` adapts the user-supplied `Factory`
  /// to this shape by consuming the heap pointer.
  private typealias InternalFactory = (
    _ context: UnsafeMutableRawPointer,
    _ deallocator: @convention(c) (UnsafeMutableRawPointer?) -> Void
  ) -> expo.NativeStateShared

  /// Non-owning reference to the underlying C++ `expo::NativeState`. `nil` until
  /// the first `setNativeState` call materializes a pointee, and stays populated
  /// afterward (though its contents may expire when the last JSI slot drops the
  /// strong ref). `acquireShared()` transparently re-allocates if expired.
  internal private(set) var weakPointee: WeakPointer? = nil

  private let factory: InternalFactory

  public typealias Deallocator = (_ nativeState: JavaScriptNativeState) -> Void
  private var deallocator: Deallocator? = nil

  public init() {
    self.factory = { context, contextDeallocator in
      return expo.makeExpoNativeStateShared(context, contextDeallocator)
    }
  }

  /// Builds the underlying native state via a custom factory. See `Factory` for
  /// the lazy-invocation contract.
  public init(factory: @escaping Factory) {
    self.factory = { context, contextDeallocator in
      let pointer = factory(context, contextDeallocator)
      let typed = pointer.assumingMemoryBound(to: expo.NativeStateShared.self)
      let shared = typed.move()
      typed.deallocate()
      return shared
    }
  }

  /// Returns a `shared_ptr` to the underlying `expo::NativeState`, materializing
  /// one lazily if there's no live pointee. Called by `JavaScriptObject.setNativeState`
  /// to obtain the value to pass to JSI.
  internal func acquireShared() -> expo.NativeStateShared {
    if let alive = weakPointee?.lock() {
      return alive
    }
    let context = Unmanaged.passRetained(self).toOpaque()
    let shared = factory(context, JavaScriptNativeState.contextDeallocator)
    self.weakPointee = WeakPointer(shared)
    return shared
  }

  private static let contextDeallocator: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else {
      return
    }
    let unmanagedContext = Unmanaged<JavaScriptNativeState>.fromOpaque(context)
    let nativeState = unmanagedContext.takeUnretainedValue()

    nativeState.deallocator?(nativeState)
    unmanagedContext.release()
  }

  /// Sets a deallocator, a closure that is invoked when the underlying C++ pointee
  /// dies, i.e. when this native state is no longer attached to any JS object.
  /// Replaces any previously set deallocator. The same closure is used across
  /// generations if the wrapper is reattached after a release.
  public func setDeallocator(_ deallocator: @escaping Deallocator) {
    self.deallocator = deallocator
  }

  /// Turns given C++ `expo.NativeState` pointer into its Swift counterpart.
  /// May return `nil` if the native state has no Swift context (e.g. one produced
  /// by C++ code that didn't bake in a Swift back-pointer) or if the context's
  /// actual Swift type doesn't match `Self`.
  internal static func from(cxx nativeState: UnsafeMutablePointer<expo.NativeState>) -> Self? {
    guard let context = nativeState.pointee.getContext() else {
      return nil
    }
    let value = Unmanaged<JavaScriptNativeState>.fromOpaque(context).takeUnretainedValue()
    return value as? Self
  }

  // MARK: - WeakPointer

  /// Non-owning wrapper around `expo::NativeStateWeak`. `lock()` returns a strong
  /// `shared_ptr` if the pointee is still alive, or `nil` if the last JSI slot has
  /// already dropped it.
  public struct WeakPointer {
    internal let inner: expo.NativeStateWeak

    internal init(_ shared: borrowing expo.NativeStateShared) {
      self.inner = expo.makeNativeStateWeak(shared)
    }

    internal func lock() -> expo.NativeStateShared? {
      let strong = inner.lock()
      return strong.__convertToBool() ? strong : nil
    }
  }
}
