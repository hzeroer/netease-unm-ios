//
//  UNMRuntimeDump.m
//

#import "UNMRuntimeDump.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

// Keywords that catch a client's song/privilege/playback model types.
static NSArray<NSString *> *UNMModelKeywords(void) {
    static NSArray<NSString *> *keywords = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keywords = @[ @"Song", @"Privilege", @"Track", @"Playable", @"Fee",
                      @"Audio", @"Music", @"Player", @"Priv" ];
    });
    return keywords;
}

/// True when the class comes from a bundle belonging to the host app rather than
/// from a system framework. Keeps the dump to code we can actually reason about.
static BOOL UNMClassIsFromHostApp(Class cls) {
    const char *image = class_getImageName(cls);
    if (image == NULL) return NO;
    NSString *path = @(image);
    if ([path containsString:@"/System/Library/"]) return NO;
    if ([path containsString:@"libswift"]) return NO;
    return [path containsString:@"/neteasemusic.app/"] || [path containsString:@"/Application/"];
}

static NSString *UNMDescribeClass(Class cls) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"%@", NSStringFromClass(cls)];

    Class super = class_getSuperclass(cls);
    if (super) [out appendFormat:@" : %@", NSStringFromClass(super)];

    // Properties first: these are the names a hook would target.
    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(cls, &count);
    if (props) {
        if (count > 0) {
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (unsigned int i = 0; i < count && i < 40; i++) {
                const char *name = property_getName(props[i]);
                if (name) [names addObject:@(name)];
            }
            [out appendFormat:@"\n    属性: %@", [names componentsJoinedByString:@", "]];
        }
        free(props);
    }

    // Ivars too: some models keep the interesting flag behind a plain ivar.
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    if (ivars) {
        if (ivarCount > 0) {
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (unsigned int i = 0; i < ivarCount && i < 40; i++) {
                const char *name = ivar_getName(ivars[i]);
                if (name) [names addObject:@(name)];
            }
            [out appendFormat:@"\n    变量: %@", [names componentsJoinedByString:@", "]];
        }
        free(ivars);
    }
    return out;
}

@implementation UNMRuntimeDump

/// Member names that only a playability model carries. Short ones (st, pl, dl, fl)
/// are the actual NetEase API field names, so they belong here even though they
/// also generate noise -- ranking by hit count sorts the real models to the top.
static NSArray<NSString *> *UNMPrivilegeMembers(void) {
    static NSArray<NSString *> *members = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        members = @[ @"privilege", @"privileges", @"playable", @"playflag", @"payable",
                     @"fee", @"copyright", @"copyrightid", @"songid", @"trackid",
                     @"vipflag", @"viptype", @"maxtype", @"maxbr", @"playmaxbr",
                     @"freetrialprivilege", @"freetrialinfo", @"subp", @"fl", @"cp",
                     @"st", @"pl", @"dl", @"chargeinfo", @"norightsreason" ];
    });
    return members;
}

/// Collects the members of a class, lowercased, from both properties and ivars.
static NSSet<NSString *> *UNMMembersOfClass(Class cls) {
    NSMutableSet<NSString *> *out = [NSMutableSet set];

    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(cls, &count);
    if (props) {
        for (unsigned int i = 0; i < count; i++) {
            const char *name = property_getName(props[i]);
            if (name) [out addObject:[@(name) lowercaseString]];
        }
        free(props);
    }

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    if (ivars) {
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *name = ivar_getName(ivars[i]);
            if (!name) continue;
            NSString *lower = [@(name) lowercaseString];
            // Strip the common underscore prefix and Swift storage wrappers so
            // _fee and fee both count.
            while ([lower hasPrefix:@"_"]) lower = [lower substringFromIndex:1];
            [out addObject:lower];
        }
        free(ivars);
    }
    return out;
}

+ (NSString *)privilegeModelDump {
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return @"(objc_getClassList 返回 0)";

    NSUInteger capacity = (NSUInteger)total + 256;
    Class *classes = (Class *)calloc(capacity, sizeof(Class));
    if (classes == NULL) return @"(分配类列表失败)";
    total = objc_getClassList(classes, (int)capacity);

    NSArray<NSString *> *signatures = UNMPrivilegeMembers();

    // Ranked results so the cap never again fills up with irrelevant classes.
    NSMutableArray<NSArray *> *hits = [NSMutableArray array];  // @[score, name, description]

    for (int i = 0; i < total; i++) {
        Class cls = classes[i];
        if (cls == Nil) continue;
        if (!UNMClassIsFromHostApp(cls)) continue;

        NSSet<NSString *> *members = UNMMembersOfClass(cls);
        if (members.count == 0) continue;

        NSMutableArray<NSString *> *matched = [NSMutableArray array];
        for (NSString *signature in signatures) {
            if ([members containsObject:signature]) [matched addObject:signature];
        }
        if (matched.count == 0) continue;

        NSString *name = NSStringFromClass(cls);
        NSString *image = @"";
        const char *imagePath = class_getImageName(cls);
        if (imagePath) image = [@(imagePath) lastPathComponent];
        Class super = class_getSuperclass(cls);

        NSString *description = [NSString stringWithFormat:@"%@ : %@   [%@]  命中 %lu\n    命中成员: %@",
                                 name,
                                 super ? NSStringFromClass(super) : @"-",
                                 image,
                                 (unsigned long)matched.count,
                                 [matched componentsJoinedByString:@", "]];
        [hits addObject:@[ @(matched.count), name, description ]];
    }

    free(classes);

    if (hits.count == 0) {
        return @"(没有任何类的成员名匹配版权字段 —— 版权模型可能完全在 C++/Swift 内部，不暴露给 ObjC 运行时)";
    }

    [hits sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        NSUInteger sa = [a[0] unsignedIntegerValue];
        NSUInteger sb = [b[0] unsignedIntegerValue];
        if (sa != sb) return sa > sb ? NSOrderedAscending : NSOrderedDescending;
        return [a[1] compare:b[1]];
    }];

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSUInteger length = 0;
    for (NSArray *hit in hits) {
        NSString *description = hit[2];
        length += description.length;
        [lines addObject:description];
        if (lines.count >= 60 || length > 14000) {
            [lines addObject:[NSString stringWithFormat:@"… (共命中 %lu 个类，已截断)", (unsigned long)hits.count]];
            break;
        }
    }
    return [lines componentsJoinedByString:@"\n\n"];
}

+ (NSString *)detailDumpForClasses:(NSArray<NSString *> *)classNames {
    NSMutableArray<NSString *> *out = [NSMutableArray array];

    for (NSString *name in classNames) {
        Class cls = objc_getClass(name.UTF8String);
        if (cls == Nil) {
            [out addObject:[NSString stringWithFormat:@"%@ —— 未找到", name]];
            continue;
        }

        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"=== %@ ===\n", name];

        // Walk up the chain: a field may be declared on a parent.
        NSMutableArray<Class> *chain = [NSMutableArray array];
        for (Class c = cls; c != Nil && c != NSObject.class; c = class_getSuperclass(c)) {
            [chain addObject:c];
            if (chain.count > 6) break;
        }
        [s appendFormat:@"继承链: %@\n", ({
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (Class c in chain) [names addObject:NSStringFromClass(c)];
            [names componentsJoinedByString:@" ← "];
        })];

        // Properties and ivars per level, so it is clear where each lives.
        for (Class c in chain) {
            unsigned int count = 0;
            objc_property_t *props = class_copyPropertyList(c, &count);
            if (props) {
                if (count) {
                    NSMutableArray<NSString *> *names = [NSMutableArray array];
                    for (unsigned int i = 0; i < count; i++) {
                        const char *raw = property_getName(props[i]);
                        if (raw) [names addObject:@(raw)];
                    }
                    [s appendFormat:@"  %@ 属性(%u): %@\n", NSStringFromClass(c), count,
                     [names componentsJoinedByString:@", "]];
                }
                free(props);
            }
            unsigned int ivarCount = 0;
            Ivar *ivars = class_copyIvarList(c, &ivarCount);
            if (ivars) {
                if (ivarCount) {
                    NSMutableArray<NSString *> *names = [NSMutableArray array];
                    for (unsigned int i = 0; i < ivarCount; i++) {
                        const char *raw = ivar_getName(ivars[i]);
                        if (!raw) continue;
                        // Include the type encoding: it tells us how to write the value.
                        const char *type = ivar_getTypeEncoding(ivars[i]);
                        [names addObject:[NSString stringWithFormat:@"%s(%s)", raw, type ?: "?"]];
                    }
                    [s appendFormat:@"  %@ 变量(%u): %@\n", NSStringFromClass(c), ivarCount,
                     [names componentsJoinedByString:@", "]];
                }
                free(ivars);
            }
        }

        // Instance methods, split by whether they look like accessors: those are
        // the hook candidates.
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        if (methods) {
            NSMutableArray<NSString *> *accessors = [NSMutableArray array];
            NSMutableArray<NSString *> *others = [NSMutableArray array];
            for (unsigned int i = 0; i < methodCount && (accessors.count + others.count) < 200; i++) {
                SEL sel = method_getName(methods[i]);
                if (sel == NULL) continue;
                NSString *selName = NSStringFromSelector(sel);
                const char *types = method_getTypeEncoding(methods[i]);
                NSString *entry = [NSString stringWithFormat:@"%@  (%s)", selName, types ?: "?"];
                [selName hasPrefix:@"set"] || selName.length <= 24
                    ? [accessors addObject:entry]
                    : [others addObject:entry];
            }
            free(methods);
            [s appendFormat:@"  实例方法(%u): 取值/设置类 %lu 个\n    %@\n", methodCount,
             (unsigned long)accessors.count,
             [accessors componentsJoinedByString:@"\n    "]];
            if (others.count) {
                [s appendFormat:@"  其他方法 %lu 个（节选）:\n    %@\n", (unsigned long)others.count,
                 [[others subarrayWithRange:NSMakeRange(0, MIN(others.count, (NSUInteger)30))]
                     componentsJoinedByString:@"\n    "]];
            }
        }

        [out addObject:s];
    }
    return [out componentsJoinedByString:@"\n"];
}

+ (NSString *)keyModelDetailDump {
    // Ordered by how central each class is: the song, its privilege, and the
    // model that carries the play URL. The rest are the per-feature privilege
    // variants, listed in case the main path turns out to route through one.
    static NSArray<NSString *> *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[ @"NMSong",
                   @"NMSongPrivilege",
                   @"NMSongUrlInfo",
                   @"NMSongCacheUrlInfo",
                   @"NMSongFile",
                   @"NMSongFreeTrialPrivilege",
                   @"NMSongTSTrialInfo",
                   @"NMMVPrivilege",
                   @"NMListenTogetherSongPrivilege",
                   @"NMDjProgramPrivilege",
                   @"NMDiscJockeySongModel",
                   @"NMLKSimpleSongDto" ];
    });
    return [self detailDumpForClasses:names];
}

+ (NSString *)modelDump {
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return @"(objc_getClassList 返回 0)";

    // A little headroom: classes can be registered concurrently.
    NSUInteger capacity = (NSUInteger)total + 256;
    Class *classes = (Class *)calloc(capacity, sizeof(Class));
    if (classes == NULL) return @"(分配类列表失败)";
    total = objc_getClassList(classes, (int)capacity);

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSUInteger totalLength = 0;
    NSArray<NSString *> *keywords = UNMModelKeywords();

    for (int i = 0; i < total; i++) {
        Class cls = classes[i];
        if (cls == Nil) continue;

        const char *rawName = class_getName(cls);
        if (rawName == NULL) continue;
        NSString *name = @(rawName);
        if (name.length == 0) continue;

        BOOL keywordHit = NO;
        for (NSString *keyword in keywords) {
            if ([name containsString:keyword]) { keywordHit = YES; break; }
        }
        if (!keywordHit) continue;
        if (!UNMClassIsFromHostApp(cls)) continue;

        NSString *described = UNMDescribeClass(cls);
        totalLength += described.length;
        [lines addObject:described];

        // Bound the output: the report travels through a chat window.
        if (lines.count >= 70 || totalLength > 12000) {
            [lines addObject:@"… (已截断)"];
            break;
        }
    }

    free(classes);
    if (lines.count == 0) {
        return @"(没有找到 App 自带的 歌曲/版权/播放 相关类 —— 可能是类名不含这些关键词)";
    }
    return [lines componentsJoinedByString:@"\n\n"];
}

+ (NSString *)imageDump {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count && lines.count < 120; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name == NULL) continue;
        NSString *path = @(name);
        // Only the interesting ones: anything that is not a system framework.
        if ([path containsString:@"/System/Library/"] && ![path containsString:@"libSystem"]) continue;
        [lines addObject:[path lastPathComponent]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

@end
