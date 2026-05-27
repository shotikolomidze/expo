#pragma once

#include <memory>
#include <jsi/jsi.h>

namespace expo {

/**
 Base class for `jsi::NativeState` instances that need to round-trip through
 a managed-language wrapper (Swift today, Kotlin/JVM later). Holds an opaque
 context pointer and a destructor callback that runs when the underlying
 shared_ptr is released. The context pointer is opaque to C++ — only the
 producer of the instance interprets it.
 */
class NativeState : public facebook::jsi::NativeState {
public:
  using Context = void *;
  using ContextDeallocator = void (*)(Context);

  explicit NativeState(Context context = nullptr, ContextDeallocator contextDeallocator = nullptr)
    : _context(context), _contextDeallocator(contextDeallocator) {}

  ~NativeState() override {
    if (_contextDeallocator) {
      _contextDeallocator(_context);
    }
  }

  inline Context getContext() const {
    return _context;
  }

private:
  Context _context;
  ContextDeallocator _contextDeallocator;
};

/**
 Concrete `shared_ptr<jsi::NativeState>` specialization, exposed at namespace
 scope so Swift/C++ interop can import it as `expo.NativeStateShared` —
 interop does not support class templates directly, but a fully-specialized
 typedef is fine.
 */
using NativeStateShared = std::shared_ptr<facebook::jsi::NativeState>;

/**
 Concrete `weak_ptr<jsi::NativeState>` specialization. Same rationale as
 `NativeStateShared`. Lets Swift hold a non-owning reference to a pointee
 whose lifetime is otherwise managed by JSI's slot(s).
 */
using NativeStateWeak = std::weak_ptr<facebook::jsi::NativeState>;

} // namespace expo
