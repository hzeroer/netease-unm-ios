//
//  UNMHook.m
//

#import "UNMHook.h"
#import "UNMLog.h"

#pragma mark - Hook registry

// (class, selector) -> the implementation that was there before we replaced it.
//
// Keeping this in a table rather than in one global per hook is the whole point:
// several hooks (the class-cluster ones) may target different classes for the
// same selector, and a shared global would be silently overwritten by the last
// one installed -- turning a hook into a self-call.
static NSMutableDictionary<NSString *, NSNumber *> *gRegistry = nil;
static NSLock *gRegistryLock = nil;

static void UNMRegistryEnsure(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gRegistry = [NSMutableDictionary dictionary];
        gRegistryLock = [[NSLock alloc] init];
    });
}

static NSString *UNMRegistryKey(Class cls, SEL sel, BOOL isClassMethod) {
    return [NSString stringWithFormat:@"%c%p:%s",
            isClassMethod ? '+' : '-', (void *)cls, sel_getName(sel)];
}

static void UNMRegistryStore(Class cls, SEL sel, BOOL isClassMethod, IMP original) {
    UNMRegistryEnsure();
    if (!cls || !sel || !original) return;
    NSString *key = UNMRegistryKey(cls, sel, isClassMethod);
    [gRegistryLock lock];
    gRegistry[key] = @((unsigned long long)original);
    [gRegistryLock unlock];
}

static IMP UNMRegistryLookup(Class cls, SEL sel, BOOL isClassMethod) {
    if (!cls || !sel) return NULL;
    UNMRegistryEnsure();
    NSString *key = UNMRegistryKey(cls, sel, isClassMethod);
    [gRegistryLock lock];
    NSNumber *value = gRegistry[key];
    [gRegistryLock unlock];
    return value ? (IMP)value.unsignedLongLongValue : NULL;
}

BOOL UNMHookIsInstalled(Class cls, SEL sel, BOOL isClassMethod) {
    return UNMRegistryLookup(cls, sel, isClassMethod) != NULL;
}

IMP UNMHookOriginalForReceiver(id self_, SEL sel) {
    if (!self_ || !sel) return NULL;

    Class start = object_getClass(self_);

    if (class_isMetaClass(start)) {
        // The receiver is a Class, i.e. a class-method hook. Metaclasses are not
        // usefully walkable, so hop back to the class and walk its chain.
        Class cls = objc_getClass(class_getName(start));
        if (!cls) cls = (Class)self_;
        for (Class c = cls; c; c = class_getSuperclass(c)) {
            IMP hit = UNMRegistryLookup(c, sel, YES);
            if (hit) return hit;
        }
        return NULL;
    }

    // Instance method: walk the receiver's own class chain, so a hook installed
    // on a superclass still answers for every subclass instance.
    for (Class c = start; c; c = class_getSuperclass(c)) {
        IMP hit = UNMRegistryLookup(c, sel, NO);
        if (hit) return hit;
    }
    return NULL;
}

#pragma mark - Class lookup

Class UNMFindClass(NSString *name) {
    if (name.length == 0) return Nil;

    Class c = objc_getClass(name.UTF8String);
    if (c) return c;

    // Swift classes reachable from ObjC are usually exposed as "Module.Class".
    if ([name containsString:@"."]) {
        NSString *suffix = [@"." stringByAppendingString:[name componentsSeparatedByString:@"."].lastObject];

        unsigned int count = 0;
        Class *all = objc_copyClassList(&count);
        Class found = Nil;
        if (all) {
            for (unsigned int i = 0; i < count && !found; i++) {
                const char *cn = class_getName(all[i]);
                if (cn && strstr(cn, suffix.UTF8String)) found = all[i];
            }
            free(all);
        }
        return found;
    }
    return Nil;
}

Method UNMLookupMethod(Class cls, SEL sel, BOOL isClassMethod, Class *owner) {
    if (!cls || !sel) return NULL;
    Class cursor = isClassMethod ? object_getClass(cls) : cls;
    while (cursor) {
        Method m = class_getInstanceMethod(cursor, sel);
        if (m) {
            if (owner) *owner = cursor;
            return m;
        }
        cursor = class_getSuperclass(cursor);
    }
    return NULL;
}

BOOL UNMClassOwnsSelector(Class cls, SEL sel, BOOL isClassMethod) {
    if (!cls || !sel) return NO;
    Class target = isClassMethod ? object_getClass(cls) : cls;
    if (!target) return NO;

    unsigned int count = 0;
    Method *list = class_copyMethodList(target, &count);
    if (!list) return NO;

    BOOL owns = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(list[i]) == sel) { owns = YES; break; }
    }
    free(list);
    return owns;
}

#pragma mark - Swizzling

static BOOL UNMHookSwizzle(Class cls, SEL sel, IMP newIMP, IMP *oldIMP) {
    if (!cls || !sel || !newIMP) return NO;

    // Rule 1: never hook twice. The second call would record the first hook as
    // its "original" and recurse forever.
    if (UNMHookIsInstalled(cls, sel, NO)) return YES;

    // Rule 2: never hook a method into existence.
    Method m = UNMLookupMethod(cls, sel, NO, NULL);
    if (!m) return NO;

    // Same value in both branches below: for a method this class owns it is the
    // current implementation, and for an inherited one it is the parent's --
    // which is exactly what a hook must call.
    IMP previous = method_getImplementation(m);

    // Register *before* installing, so a hook that fires on another thread can
    // never find an empty slot and lose the original implementation.
    UNMRegistryStore(cls, sel, NO, previous);

    if (!class_addMethod(cls, sel, newIMP, method_getTypeEncoding(m))) {
        method_setImplementation(m, newIMP);
    }

    if (oldIMP) *oldIMP = previous;
    return YES;
}

static BOOL UNMHookSwizzleClassMethod(Class cls, SEL sel, IMP newIMP, IMP *oldIMP) {
    if (!cls || !sel || !newIMP) return NO;
    if (UNMHookIsInstalled(cls, sel, YES)) return YES;

    Class meta = object_getClass(cls);
    if (!meta) return NO;

    Method m = UNMLookupMethod(cls, sel, YES, NULL);
    if (!m) return NO;

    IMP previous = method_getImplementation(m);
    UNMRegistryStore(cls, sel, YES, previous);

    if (!class_addMethod(meta, sel, newIMP, method_getTypeEncoding(m))) {
        method_setImplementation(m, newIMP);
    }

    if (oldIMP) *oldIMP = previous;
    return YES;
}

BOOL UNMHookInst(Class cls, SEL sel, IMP newIMP, IMP *oldIMP) {
    return UNMHookSwizzle(cls, sel, newIMP, oldIMP);
}

BOOL UNMHookCls(Class cls, SEL sel, IMP newIMP, IMP *oldIMP) {
    return UNMHookSwizzleClassMethod(cls, sel, newIMP, oldIMP);
}

BOOL UNMHookByName(NSString *clsName, NSString *selName, BOOL isClassMethod,
                   IMP newIMP, IMP *oldIMP) {
    Class cls = UNMFindClass(clsName);
    if (!cls) return NO;
    SEL sel = NSSelectorFromString(selName);
    if (!UNMLookupMethod(cls, sel, isClassMethod, NULL)) return NO;
    return isClassMethod ? UNMHookCls(cls, sel, newIMP, oldIMP)
                         : UNMHookInst(cls, sel, newIMP, oldIMP);
}

BOOL UNMHookInstOnRuntimeClass(id sample, SEL sel, IMP newIMP, IMP *oldIMP) {
    if (!sample) return NO;
    return UNMHookInst(object_getClass(sample), sel, newIMP, oldIMP);
}

BOOL UNMHookClsOnRuntimeClass(id sample, SEL sel, IMP newIMP, IMP *oldIMP) {
    if (!sample) return NO;
    return UNMHookCls(object_getClass(sample), sel, newIMP, oldIMP);
}

BOOL UNMHookInstOnRuntimeClassIfOwned(id sample, SEL sel, IMP newIMP, IMP *oldIMP) {
    if (!sample) return NO;
    Class cls = object_getClass(sample);
    if (!UNMClassOwnsSelector(cls, sel, NO)) return NO;
    return UNMHookInst(cls, sel, newIMP, oldIMP);
}

BOOL UNMHookClsOnRuntimeClassIfOwned(id sample, SEL sel, IMP newIMP, IMP *oldIMP) {
    if (!sample) return NO;
    Class cls = object_getClass(sample);
    if (!UNMClassOwnsSelector(cls, sel, YES)) return NO;
    return UNMHookCls(cls, sel, newIMP, oldIMP);
}

#pragma mark - Introspection helpers

NSArray<NSString *> *UNMDumpClassesMatching(NSString *pattern) {
    NSMutableArray *out = [NSMutableArray array];
    NSError *err = nil;
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&err];
    if (!re) return out;

    unsigned int count = 0;
    Class *all = objc_copyClassList(&count);
    if (!all) return out;
    for (unsigned int i = 0; i < count; i++) {
        const char *cn = class_getName(all[i]);
        if (!cn) continue;
        NSString *name = @(cn);
        if ([re firstMatchInString:name options:0 range:NSMakeRange(0, name.length)]) {
            [out addObject:name];
        }
    }
    free(all);
    [out sortUsingSelector:@selector(compare:)];
    return out;
}

NSArray<NSString *> *UNMDumpMethods(Class cls) {
    NSMutableArray *out = [NSMutableArray array];
    if (!cls) return out;

    for (int isClass = 0; isClass <= 1; isClass++) {
        Class target = isClass ? object_getClass(cls) : cls;
        unsigned int count = 0;
        Method *list = class_copyMethodList(target, &count);
        if (!list) continue;
        for (unsigned int i = 0; i < count; i++) {
            [out addObject:[NSString stringWithFormat:@"%s%s%s",
                            isClass ? "+" : "-",
                            sel_getName(method_getName(list[i])),
                            method_getTypeEncoding(list[i])]];
        }
        free(list);
    }
    return out;
}
