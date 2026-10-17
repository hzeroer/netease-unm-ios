//
//  UNMMatcher.m
//

#import "UNMMatcher.h"
#import "UNMConfig.h"
#import "UNMLog.h"
#import "UNMUtil.h"

@implementation UNMSongMeta

- (BOOL)usable {
    return self.name.length > 0;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<meta %lld %@ - %@ dur=%.0f>",
            self.songID, [self.artists componentsJoinedByString:@"/"], self.name, self.duration];
}

@end

/// Dice coefficient over character bigrams. Works for CJK and for Latin text
/// without needing a tokenizer, which matters because we cannot rely on the
/// app's locale or on ICU word segmentation.
static double UNMDiceSimilarity(NSString *a, NSString *b) {
    if (a.length == 0 || b.length == 0) return 0.0;
    if ([a isEqualToString:b]) return 1.0;

    if (a.length < 2 || b.length < 2) {
        return [a isEqualToString:b] ? 1.0 : 0.0;
    }

    NSMutableDictionary<NSString *, NSNumber *> *grams = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i + 1 < a.length; i++) {
        NSString *g = [a substringWithRange:NSMakeRange(i, 2)];
        grams[g] = @(grams[g].integerValue + 1);
    }

    NSUInteger hits = 0;
    for (NSUInteger i = 0; i + 1 < b.length; i++) {
        NSString *g = [b substringWithRange:NSMakeRange(i, 2)];
        NSInteger left = grams[g].integerValue;
        if (left > 0) {
            hits++;
            grams[g] = @(left - 1);
        }
    }

    double denom = (double)(a.length - 1) + (double)(b.length - 1);
    return denom > 0 ? (2.0 * (double)hits) / denom : 0.0;
}

static double UNMTitleScore(NSString *candidateTitle, NSString *targetTitle) {
    NSString *c = UNMNormalizeTitle(candidateTitle);
    NSString *t = UNMNormalizeTitle(targetTitle);
    if (c.length == 0 || t.length == 0) return 0.0;
    if ([c isEqualToString:t]) return 1.0;

    // A source title often carries extra decoration ("xxx (电影版)"), so a
    // containment match is still a strong signal.
    if ([c containsString:t] || [t containsString:c]) {
        double shorter = (double)MIN(c.length, t.length);
        double longer = (double)MAX(c.length, t.length);
        return 0.68 + 0.28 * (shorter / longer);
    }

    double dice = UNMDiceSimilarity(c, t);
    // Dice on the compact key is conservative; scale it into the same range as
    // the containment case so the weights below stay meaningful.
    return MIN(0.95, dice * 0.95);
}

static double UNMArtistScore(NSArray<NSString *> *candidateArtists, NSArray<NSString *> *targetArtists) {
    if (targetArtists.count == 0 || candidateArtists.count == 0) return 0.5;  // neutral

    double best = 0.0;
    for (NSString *t in targetArtists) {
        NSString *tn = UNMNormalizeTitle(t);
        if (tn.length == 0) continue;
        for (NSString *c in candidateArtists) {
            NSString *cn = UNMNormalizeTitle(c);
            if (cn.length == 0) continue;
            if ([cn isEqualToString:tn]) return 1.0;
            if ([cn containsString:tn] || [tn containsString:cn]) {
                best = MAX(best, 0.85);
                continue;
            }
            best = MAX(best, UNMDiceSimilarity(cn, tn));
        }
    }
    return best;
}

static double UNMDurationScore(double candidate, double target, double tolerance) {
    if (candidate <= 0 || target <= 0) return 0.5;   // neutral
    double diff = fabs(candidate - target);
    if (diff <= tolerance) return 1.0;
    if (diff <= tolerance * 4.0) return MAX(0.0, 1.0 - (diff - tolerance) / (tolerance * 3.0));
    return 0.0;
}

@implementation UNMMatcher

/// Markers that mean "this is not the studio recording".
///
/// A live take has the same title and artist as the original, so title and artist
/// alone cannot tell them apart -- and when the duration is unknown there is
/// nothing else to go on, which is how a live version ends up winning. These are
/// penalised rather than rejected: if a song genuinely only exists as a live
/// recording, playing that is still better than playing nothing.
static NSArray<NSString *> *UNMVariantMarkers(void) {
    static NSArray<NSString *> *markers = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        markers = @[ @"live", @"演唱会", @"现场", @"現場", @"remix", @"伴奏",
                     @"instrumental", @"karaoke", @"karaok", @"cover", @"翻唱",
                     @"不插电", @"acoustic", @"unplugged", @"demo", @"试听版",
                     @"铃声", @"纯音乐", @"钢琴版", @"吉他版", @"女声版", @"男声版",
                     @"升调", @"降调", @"加快", @"慢速", @"dj版", @"mashup",
                     @"串烧", @"片段", @"清唱", @"和声版", @"重制", @"新版", @"版)" ];
    });
    return markers;
}

/// Is this character an ASCII letter or digit?
///
/// Deliberately ASCII-only. `NSCharacterSet letterCharacterSet` also contains CJK
/// characters, and using it here made "稻香 (Remix摇滚版)" fail the word-boundary
/// test: the character after "Remix" is 摇, which counts as a letter, so the marker
/// was rejected and a remix was classified as a studio recording -- which is exactly
/// how a remix ended up being delivered for the studio track.
static BOOL UNMIsASCIIAlnum(unichar c) {
    if (c >= 128) return NO;
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

/// Does the title contain this marker as a standalone token?
///
/// A plain substring test would fire on "Alive" for the marker "live" and punish a
/// perfectly good match. ASCII markers therefore must not be embedded in a longer
/// ASCII word; CJK ones have no word boundaries and are matched as substrings.
static BOOL UNMContainsMarker(NSString *haystack, NSString *marker) {
    if (haystack.length == 0 || marker.length == 0) return NO;

    NSRange search = NSMakeRange(0, haystack.length);
    while (search.length > 0) {
        NSRange found = [haystack rangeOfString:marker options:0 range:search];
        if (found.location == NSNotFound) return NO;

        unichar first = [marker characterAtIndex:0];
        if (first >= 128) return YES;   // CJK: substring is enough

        BOOL leftOK = (found.location == 0) ||
            !UNMIsASCIIAlnum([haystack characterAtIndex:found.location - 1]);
        NSUInteger end = NSMaxRange(found);
        BOOL rightOK = (end >= haystack.length) ||
            !UNMIsASCIIAlnum([haystack characterAtIndex:end]);
        if (leftOK && rightOK) return YES;

        NSUInteger next = found.location + 1;
        if (next >= haystack.length) return NO;
        search = NSMakeRange(next, haystack.length - next);
    }
    return NO;
}

/// Does this text look like a live recording?
///
/// The title is not enough on its own: a concert album's tracks are often titled
/// plainly ("晴天") and only the album says what they are. Missing that is how the
/// penalty ended up replacing live recordings with studio versions for anyone
/// listening to a live album.
static BOOL UNMLooksLive(NSString *text) {
    NSString *lower = [text lowercaseString];
    if (lower.length == 0) return NO;
    static NSArray<NSString *> *markers = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        markers = @[ @"live", @"演唱会", @"現場", @"现场", @"concert",
                     @"unplugged", @"不插电" ];
    });
    for (NSString *marker in markers) {
        if (UNMContainsMarker(lower, marker)) return YES;
    }
    return NO;
}

/// Which kind of recording this is.
///
/// Comparing families is what makes this work in both directions: a live request
/// must not be answered with a remix, and a studio request must not be answered
/// with a live take. Penalising "live" alone only covered one of those, which is
/// how a live 稻香 ended up replaced by a remix of it.
typedef NS_ENUM(NSInteger, UNMVariantFamily) {
    UNMVariantFamilyStudio = 0,
    UNMVariantFamilyLive,
    UNMVariantFamilyRemix,
    UNMVariantFamilyInstrumental,
    UNMVariantFamilyCover,
    UNMVariantFamilyAcoustic,
};

static UNMVariantFamily UNMFamilyOf(NSString *title, NSString *album) {
    NSString *t = [title lowercaseString] ?: @"";
    NSString *a = [album lowercaseString] ?: @"";
    NSString *both = [NSString stringWithFormat:@"%@ %@", t, a];

    NSArray<NSString *> *instrumental = @[ @"伴奏", @"instrumental", @"karaoke", @"纯音乐", @"off vocal" ];
    for (NSString *m in instrumental) if (UNMContainsMarker(both, m)) return UNMVariantFamilyInstrumental;

    NSArray<NSString *> *remix = @[ @"remix", @"dj版", @"mashup", @"串烧", @"加快", @"慢速", @"升调", @"降调" ];
    for (NSString *m in remix) if (UNMContainsMarker(both, m)) return UNMVariantFamilyRemix;

    NSArray<NSString *> *cover = @[ @"翻唱", @"cover", @"女声版", @"男声版", @"钢琴版", @"吉他版" ];
    for (NSString *m in cover) if (UNMContainsMarker(both, m)) return UNMVariantFamilyCover;

    if (UNMLooksLive(both)) return UNMVariantFamilyLive;
    if (UNMContainsMarker(both, @"不插电") || UNMContainsMarker(both, @"acoustic") ||
        UNMContainsMarker(both, @"unplugged")) return UNMVariantFamilyAcoustic;

    return UNMVariantFamilyStudio;
}

/// 1.0 when the candidate is the same kind of recording as the target, else lower.
///
/// Which live take is correct is decided separately by the album; this only rules
/// out the wrong *kind*.
static double UNMVariantPenalty(NSString *candidateTitle, NSString *candidateAlbum,
                                NSString *targetTitle, NSString *targetAlbum) {
    if (candidateTitle.length == 0 && candidateAlbum.length == 0) return 1.0;

    UNMVariantFamily candidate = UNMFamilyOf(candidateTitle, candidateAlbum);
    UNMVariantFamily target = UNMFamilyOf(targetTitle, targetAlbum);

    // Same family, or the candidate is a plain studio recording: nothing to say.
    if (candidate == target) return 1.0;
    if (candidate == UNMVariantFamilyStudio) return 1.0;

    // A different kind of recording than the one being asked for.
    return 0.45;
}

+ (double)scoreCandidate:(UNMCandidate *)candidate against:(UNMSongMeta *)meta {
    if (!candidate || !meta) return 0.0;

    double title = UNMTitleScore(candidate.title, meta.name);
    double artist = UNMArtistScore(UNMSplitArtists(candidate.artist), meta.artists);
    double duration = UNMDurationScore(candidate.duration, meta.duration,
                                       [UNMMatcher durationTolerance]);

    BOOL haveDuration = candidate.duration > 0 && meta.duration > 0;
    double score;
    if (haveDuration) {
        score = 0.60 * title + 0.30 * artist + 0.10 * duration;
    } else {
        score = 0.66 * title + 0.34 * artist;
    }

    // Album agreement is a cheap tie-breaker -- except for live recordings, where
    // it is the only thing separating one tour's take from another's.
    double albumScore = -1;
    if (meta.album.length && candidate.album.length) {
        albumScore = UNMDiceSimilarity(UNMNormalizeTitle(candidate.album),
                                       UNMNormalizeTitle(meta.album));
        if (albumScore > 0.7) score += 0.03;
    }

    BOOL targetLive = UNMLooksLive(meta.name) || UNMLooksLive(meta.album);
    if (targetLive && albumScore >= 0) {
        if (albumScore > 0.7) {
            // Same concert: this is the recording being asked for.
            score += 0.15;
        } else if (UNMLooksLive(candidate.album) && albumScore < 0.45) {
            // A different tour. Same song, different performance -- clearly wrong.
            score *= 0.6;
        }
    }

    // Push live takes, remixes and covers below the clean recording -- but not when
    // the song being replaced is itself a live recording.
    score *= UNMVariantPenalty(candidate.title, candidate.album, meta.name, meta.album);

    // An exact title match is worth a nudge: it is what distinguishes the single
    // from a "<title> (Live)" sibling when durations are unknown.
    if (UNMNormalizeTitle(candidate.title).length &&
        [UNMNormalizeTitle(candidate.title) isEqualToString:UNMNormalizeTitle(meta.name)]) {
        score += 0.04;
    }

    candidate.score = MIN(1.0, score);
    return candidate.score;
}

+ (BOOL)isFamilyCompatible:(UNMCandidate *)candidate withTarget:(UNMSongMeta *)meta {
    if (candidate == nil || meta == nil) return NO;

    UNMVariantFamily c = UNMFamilyOf(candidate.title, candidate.album);
    UNMVariantFamily t = UNMFamilyOf(meta.name, meta.album);

    if (c == t) return YES;
    // A plain studio recording is always an acceptable answer.
    if (c == UNMVariantFamilyStudio) return YES;
    return NO;
}

+ (double)durationTolerance {
    double tol = [UNMConfig shared].matchDurationTolerance;
    return tol > 0 ? tol : 6.0;
}

+ (UNMCandidate *)best:(NSArray<UNMCandidate *> *)candidates
             forTarget:(UNMSongMeta *)meta
             threshold:(double)threshold {
    UNMCandidate *best = nil;
    double bestScore = threshold;
    BOOL strict = [UNMConfig shared].rejectVariants;

    for (UNMCandidate *c in candidates) {
        if (![c isKindOfClass:UNMCandidate.class]) continue;
        if (c.title.length == 0 || c.mediaId.length == 0) continue;

        // Hard refusal, not a penalty: a remix of the right song is still the wrong
        // recording. Scoring it down only worked while the correct version was both
        // present and resolvable; the moment it was not, the remix took its place.
        if (strict && ![self isFamilyCompatible:c withTarget:meta]) {
            UNMLogD(@"[match] 跳过变体《%@》/%@", c.title ?: @"?", c.album ?: @"?");
            continue;
        }

        double s = [self scoreCandidate:c against:meta];
        if (s >= bestScore) {
            bestScore = s;
            best = c;
        }
    }
    return best;
}

+ (NSString *)searchKeywordForMeta:(UNMSongMeta *)meta {
    if (!meta) return @"";
    NSString *artist = meta.artists.firstObject ?: @"";

    // Punctuation and brackets confuse the plain-text search endpoints, so send
    // the de-decorated title for the query and keep the original for scoring.
    NSString *clean = UNMNormalizeTitle(meta.name);
    NSString *title = clean.length >= 2 ? clean : meta.name;

    // De-decorated CJK titles lose their spacing; the sources handle a bare
    // concatenation fine, and a pure-Latin title needs a separating space.
    BOOL needsSpace = [title rangeOfCharacterFromSet:[NSCharacterSet alphanumericCharacterSet]].location != NSNotFound;
    if (!needsSpace) return title;

    if (artist.length) return [NSString stringWithFormat:@"%@ %@", title, UNMNormalizeTitle(artist)];
    return title;
}

@end
