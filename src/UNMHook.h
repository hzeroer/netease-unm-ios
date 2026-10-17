//
//  UNMHook.h
//  Micro ObjC runtime swizzler.
//
//  Deliberately depends on nothing but libobjc, so the resulting dylib can be
//  injected into a jailed (non-jailbroken) app through TrollStore / TrollFools.
//  It must NOT link against substrate / libhooker / Orion.
//
//  Two safety rules are enforced here, both learned the hard way:
//
//  1. A method that does not exist is never hooked into existence. Guessing a
//     type encoding and having no original implementation to chain to is a
//     reliable way to take the host app down.
//
//  2. The same (class, selector) is hooked at most once, and the "original" for
//     a hook is looked up from the *receiver* at call time. Hooking the same
//     class+selector twice would otherwise capture the first hook as the second
//     one's original -- and a hook that calls itself recurses until the thread
//     stack overflows.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// Look up a class by name. Also tries the Swift-mangled forms so that a Swift
/// class "Foo.Bar" can be found from ObjC.
FOUNDATION_EXPORT Class _Nullable UNMFindClass(NSString *name);

/// Replace an instance method implementation.
///
/// Returns NO, changing nothing, when the method does not exist. Calling it
/// twice for the same class and selector is a no-op the second time, so an
/// installer that tries several candidate classes can never double-hook one.
FOUNDATION_EXPORT BOOL UNMHookInst(Class cls, SEL sel, IMP newIMP, IMP _Nullable * _Nullable oldIMP);

/// Replace a class method implementation. Same refusal and idempotence rules.
FOUNDATION_EXPORT BOOL UNMHookCls(Class cls, SEL sel, IMP newIMP, IMP _Nullable * _Nullable oldIMP);

/// Convenience: hook by class name / selector name (colons included).
FOUNDATION_EXPORT BOOL UNMHookByName(NSString *clsName,
                                     NSString *selName,
                                     BOOL isClassMethod,
                                     IMP newIMP,
                                     IMP _Nullable * _Nullable oldIMP);

/// The implementation a hook should call to reach the *real* behaviour for the
/// receiver it was invoked on.
///
/// Walks the receiver's class chain looking for a class that was hooked with
/// `sel` and returns the original IMP recorded at that moment. Because the value
/// comes from the registry rather than from a shared global, it can never end up
/// pointing at another hook of ours.
///
/// Pass the hook's own `self` and `_cmd`.
FOUNDATION_EXPORT IMP _Nullable UNMHookOriginalForReceiver(id self_, SEL sel);

/// YES when (class, selector) has already been hooked.
FOUNDATION_EXPORT BOOL UNMHookIsInstalled(Class cls, SEL sel, BOOL isClassMethod);

/// Method lookup that also walks up the class chain, returning the class that
/// actually owns the implementation.
FOUNDATION_EXPORT Method _Nullable UNMLookupMethod(Class cls, SEL sel, BOOL isClassMethod, Class _Nullable * _Nullable owner);

/// YES when `cls` itself implements the selector, rather than inheriting it.
FOUNDATION_EXPORT BOOL UNMClassOwnsSelector(Class cls, SEL sel, BOOL isClassMethod);

/// Hook the runtime class of a live instance, but only when that class really
/// implements the method itself.
///
/// This is the guard that makes hooking a class cluster safe. Adding a copy of an
/// *inherited* method to a subclass, after its superclass has already been
/// hooked, would capture our own replacement as the "original" -- and the hook
/// would then call itself forever. Combined with the registry above, an
/// installer can try the public class and every sampled concrete class in turn
/// and still end up with each method hooked exactly once.
FOUNDATION_EXPORT BOOL UNMHookInstOnRuntimeClassIfOwned(id _Nullable sample, SEL sel, IMP newIMP, IMP _Nullable * _Nullable oldIMP);
FOUNDATION_EXPORT BOOL UNMHookClsOnRuntimeClassIfOwned(id _Nullable sample, SEL sel, IMP newIMP, IMP _Nullable * _Nullable oldIMP);

/// Hook the runtime class of a live instance, adding a copy of the method there
/// if the class only inherits it. This covers instances of that concrete class
/// even when the method lives on a superclass, which is what a class cluster
/// needs. Because the registry is keyed per class, this is still safe to combine
/// with a hook on the public class -- but do not hook the same selector twice on
/// purpose unless you have thought about which receivers each copy serves.
FOUNDATION_EXPORT BOOL UNMHookInstOnRuntimeClass(id _Nullable sample, SEL sel, IMP newIMP, IMP _Nullable * _Nullable oldIMP);
FOUNDATION_EXPORT BOOL UNMHookClsOnRuntimeClass(id _Nullable sample, SEL sel, IMP newIMP, IMP _Nullable * _Nullable oldIMP);

/// Dump every loaded class whose name matches the given regex (NSRegularExpression
/// syntax). Used by discovery mode to pin down an app's private API classes.
FOUNDATION_EXPORT NSArray<NSString *> *UNMDumpClassesMatching(NSString *regexPattern);

/// Dump every method of a class in "[-]name(typeEncoding)" form.
FOUNDATION_EXPORT NSArray<NSString *> *UNMDumpMethods(Class cls);

NS_ASSUME_NONNULL_END
