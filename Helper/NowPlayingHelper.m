// nxtch's now-playing helper.
//
// Since macOS 15.4 MediaRemote, where macOS keeps what's playing, only answers Apple's own
// programs. So nxtch doesn't read it itself: it starts /usr/bin/perl, which macOS does answer,
// and has Perl load this library. The library prints one JSON line per change on stdout: the
// song macOS picked and who plays it, then under "apps" every app's own song and cover ("art",
// base64, once per new cover and song; "artID" after that).
// It quits within 10 s of nxtch going away.
//
// The idea of a library inside Apple's Perl comes from mediaremote-adapter by Jonas van den Berg
// (BSD-3-Clause, github.com/ungive/mediaremote-adapter). The code here is nxtch's own.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>

typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef void (*GetClientsFn)(dispatch_queue_t, void (^)(NSArray *));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(bool));
typedef id (*GetOriginFn)(void);

static dispatch_queue_t q;
static GetInfoFn getInfo;
static GetClientFn getClient;
static GetClientsFn getClients;
static GetPlayingFn getPlaying;
static GetOriginFn localOrigin;
static NSString *last;
/// Per app: the cover id and song it was last sent with. The image goes once per cover and song,
/// then only its id. A new song gets it again even with the same cover (an album), since nxtch
/// drops a cover when the song changes.
static NSMutableDictionary<NSString *, NSString *> *sentArt;
/// Per app: the song its cover was last fetched for, and that cover's id. A cover is only fetched
/// again when the song changes (or there was none): fetching it on every look was most of the cost.
static NSMutableDictionary<NSString *, NSArray *> *knownArt;
static BOOL due;
static pid_t parent;
// Kept here, not as locals: ARC may free a local after its last use, even in a function that
// never returns. As locals, the timers and observers went quiet at once.
static dispatch_source_t safety, watch, others;
static NSMutableArray *observers;
static NSString *artFor;   // the songs the cover retries are for
static int artTries;

static void soon(void);

static uint64_t fnv(NSData *d) {
    uint64_t h = 1469598103934665603ULL;
    const uint8_t *p = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

static id str(NSDictionary *info, NSString *key) {
    id v = info[key];
    return [v isKindOfClass:NSString.class] || [v isKindOfClass:NSNumber.class] ? v : nil;
}

static id call(id obj, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    return [obj respondsToSelector:s] ? ((id (*)(id, SEL))objc_msgSend)(obj, s) : nil;
}

static void emit(NSDictionary *o) {
    NSData *j = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
    if (!j) return;
    NSString *s = [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding];
    if ([s isEqualToString:last]) return;
    last = s;
    fwrite(j.bytes, 1, j.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

/// The song fields nxtch reads, from a MediaRemote info dictionary.
static void song(NSMutableDictionary *o, NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class]) return;
    o[@"title"] = str(info, @"kMRMediaRemoteNowPlayingInfoTitle");
    o[@"artist"] = str(info, @"kMRMediaRemoteNowPlayingInfoArtist");
    o[@"album"] = str(info, @"kMRMediaRemoteNowPlayingInfoAlbum");
    o[@"elapsed"] = str(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime");
    o[@"duration"] = str(info, @"kMRMediaRemoteNowPlayingInfoDuration");
    o[@"rate"] = str(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate");
    id ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([ts isKindOfClass:NSDate.class]) o[@"timestamp"] = @([ts timeIntervalSince1970]);
}

/// Adds the cover to an app's entry: its id always, the image only when nxtch hasn't got it.
static void cover(NSMutableDictionary *e, NSString *bundle, NSData *art) {
    if (![art isKindOfClass:NSData.class] || art.length == 0 || art.length >= (8 << 20)) {
        [sentArt removeObjectForKey:bundle];   // nxtch forgets it too
        return;
    }
    NSString *artID = [NSString stringWithFormat:@"%016llx", fnv(art)];
    e[@"artID"] = artID;
    NSString *key = [NSString stringWithFormat:@"%@\n%@\n%@", artID, e[@"title"] ?: @"", e[@"artist"] ?: @""];
    if (![sentArt[bundle] isEqualToString:key]) {
        sentArt[bundle] = key;
        e[@"art"] = [art base64EncodedStringWithOptions:0];
    }
}

/// Every app macOS keeps a now-playing entry for, each with its own song and cover. macOS's own
/// pick is only one of them: Firefox starting a video takes it from Spotify, but Spotify's song
/// is still here.
static void readApps(void (^done)(NSArray *)) {
    getClients(q, ^(NSArray *clients) {
        NSMutableArray *apps = [NSMutableArray array];
        // One for the loop itself, so an answer that comes back at once can't finish early.
        __block NSInteger pending = 1;
        __block BOOL finished = NO;
        void (^finish)(void) = ^{ if (!finished) { finished = YES; done(apps); } };
        // An app slow to answer doesn't hold up the rest for more than 1 s. Its song still goes
        // out if that much came; a cover that came too late is fetched again on a later look.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), q, finish);
        id origin = localOrigin();
        Class pathClass = NSClassFromString(@"MRPlayerPath"), requestClass = NSClassFromString(@"MRNowPlayingRequest");
        if (!origin || !pathClass || !requestClass) { finish(); return; }
        for (id client in clients) {
            NSString *bundle = call(client, @"bundleIdentifier");
            if (![bundle isKindOfClass:NSString.class]) continue;
            id path = ((id (*)(id, SEL, id, id, id))objc_msgSend)([pathClass alloc], NSSelectorFromString(@"initWithOrigin:client:player:"), origin, client, nil);
            id request = ((id (*)(id, SEL, id))objc_msgSend)([requestClass alloc], NSSelectorFromString(@"initWithPlayerPath:"), path);
            if (!request) continue;
            NSMutableDictionary *e = [NSMutableDictionary dictionaryWithObject:bundle forKey:@"bundle"];
            NSString *parentID = call(client, @"parentApplicationBundleIdentifier");
            if ([parentID isKindOfClass:NSString.class]) e[@"parent"] = parentID;
            pending++;
            ((void (*)(id, SEL, id, id))objc_msgSend)(request, NSSelectorFromString(@"requestNowPlayingInfoOnQueue:completion:"), q, ^(id info, id error) {
                song(e, info);
                e[@"playing"] = [e[@"rate"] doubleValue] > 0 ? @YES : @NO;
                NSString *songKey = [NSString stringWithFormat:@"%@\n%@\n%@", e[@"title"] ?: @"", e[@"artist"] ?: @"", e[@"album"] ?: @""];
                NSArray *known = knownArt[bundle];
                if (finished) return;
                if (!e[@"title"]) { if (--pending == 0) finish(); return; }
                [apps addObject:e];   // the song now; its cover joins it below if it's quick
                if ([known[0] isEqualToString:songKey] && sentArt[bundle]) {
                    e[@"artID"] = known[1];   // same song, cover already with nxtch
                    if (--pending == 0) finish();
                    return;
                }
                ((void (*)(id, SEL, id, id))objc_msgSend)(request, NSSelectorFromString(@"requestNowPlayingItemArtworkOnQueue:completion:"), q, ^(id artwork, id error) {
                    NSData *art = call(artwork, @"imageData");
                    if (!art && [info isKindOfClass:NSDictionary.class]) art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    if (finished) return;
                    cover(e, bundle, art);
                    if (e[@"artID"]) knownArt[bundle] = @[ songKey, e[@"artID"] ]; else [knownArt removeObjectForKey:bundle];
                    if (--pending == 0) finish();
                });
            });
        }
        if (--pending == 0) finish();
    });
}

/// Reads everything once: macOS's pick (who, whether it plays, the song), then every app.
static void readAll(void) {
    due = NO;
    getClient(q, ^(id client) {
        NSString *bundle = call(client, @"bundleIdentifier");
        NSString *parentID = call(client, @"parentApplicationBundleIdentifier");
        getPlaying(q, ^(bool playing) {
            getInfo(q, ^(NSDictionary *info) {
                NSMutableDictionary *o = [NSMutableDictionary dictionaryWithObject:@(playing) forKey:@"playing"];
                song(o, info);
                if ([bundle isKindOfClass:NSString.class]) o[@"bundle"] = bundle;
                if ([parentID isKindOfClass:NSString.class]) o[@"parent"] = parentID;
                readApps(^(NSArray *apps) {
                    o[@"apps"] = apps;
                    // An app left out of this read (it quit, or answered too late) is dropped by
                    // nxtch, cover and all: forget it was sent, so it's sent again when it's back.
                    NSMutableSet *present = [NSMutableSet set];
                    for (NSDictionary *e in apps) [present addObject:e[@"bundle"]];
                    for (NSString *b in sentArt.allKeys) if (![present containsObject:b]) { [sentArt removeObjectForKey:b]; [knownArt removeObjectForKey:b]; }
                    emit(o);
                    // macOS loads covers lazily: the first answer for a song often has none. Ask
                    // again a few times, 0.3, 0.6, 1.2 and 2.4 s later, while a playing app's
                    // song still has none (Firefox never sends one: it costs these four reads).
                    NSMutableArray *missing = [NSMutableArray array];
                    for (NSDictionary *e in apps)
                        if ([e[@"playing"] boolValue] && !e[@"artID"]) [missing addObject:[NSString stringWithFormat:@"%@ %@", e[@"bundle"], e[@"title"]]];
                    NSString *songs = [missing componentsJoinedByString:@"\n"];
                    if (![songs isEqualToString:artFor]) { artFor = songs; artTries = 0; }
                    if (missing.count && artTries < 4) {
                        int64_t ms = 300LL << artTries++;
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), q, ^{ if (!due) readAll(); });
                    }
                    // macOS only announces changes for its own pick. Another app's song change is
                    // only seen by asking: every 1.5 s while one plays, every 5 s while one is
                    // paused (it could start again), never while macOS's pick is the only one.
                    BOOL otherPlaying = NO, otherSong = NO;
                    for (NSDictionary *e in apps) {
                        if ([e[@"bundle"] isEqual:bundle]) continue;
                        otherSong = YES;
                        if ([e[@"playing"] boolValue]) otherPlaying = YES;
                    }
                    int64_t every = otherPlaying ? 1500 : otherSong ? 5000 : 3600000;
                    dispatch_source_set_timer(others, dispatch_time(DISPATCH_TIME_NOW, every * NSEC_PER_MSEC), every * NSEC_PER_MSEC, every * NSEC_PER_MSEC / 10);
                });
            });
        });
    });
}

/// Changes come in bursts; one read 200 ms after the first.
static void soon(void) {
    if (due) return;
    due = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), q, ^{ readAll(); });
}

extern void nxtch_now_playing(void) {
    @autoreleasepool {
        parent = getppid();
        CFBundleRef mr = CFBundleCreate(NULL, (__bridge CFURLRef)[NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"]);
        if (!mr) { fprintf(stderr, "no MediaRemote\n"); exit(1); }
        RegisterFn reg = CFBundleGetFunctionPointerForName(mr, CFSTR("MRMediaRemoteRegisterForNowPlayingNotifications"));
        getInfo = CFBundleGetFunctionPointerForName(mr, CFSTR("MRMediaRemoteGetNowPlayingInfo"));
        getClient = CFBundleGetFunctionPointerForName(mr, CFSTR("MRMediaRemoteGetNowPlayingClient"));
        getPlaying = CFBundleGetFunctionPointerForName(mr, CFSTR("MRMediaRemoteGetNowPlayingApplicationIsPlaying"));
        getClients = CFBundleGetFunctionPointerForName(mr, CFSTR("MRMediaRemoteGetNowPlayingClients"));
        localOrigin = CFBundleGetFunctionPointerForName(mr, CFSTR("MRMediaRemoteGetLocalOrigin"));
        if (!reg || !getInfo || !getClient || !getPlaying || !getClients || !localOrigin) { fprintf(stderr, "MediaRemote functions missing\n"); exit(1); }

        q = dispatch_queue_create("nxtch.nowplaying", DISPATCH_QUEUE_SERIAL);
        sentArt = [NSMutableDictionary dictionary];
        knownArt = [NSMutableDictionary dictionary];
        others = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(others, DISPATCH_TIME_FOREVER, 0, 0);
        dispatch_source_set_event_handler(others, ^{ soon(); });
        dispatch_resume(others);
        observers = [NSMutableArray array];
        for (NSString *name in @[ @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                                  @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                                  @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification" ]) {
            [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                usingBlock:^(NSNotification *n) { dispatch_async(q, ^{ soon(); }); }]];
        }
        reg(q);

        // A full read every 60 s in case a notice is missed, and a check every 10 s that nxtch
        // is still there: if it went away, so does this.
        safety = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(safety, DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(safety, ^{ readAll(); });
        dispatch_resume(safety);
        watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(watch, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(watch, ^{ if (getppid() != parent) exit(0); });
        dispatch_resume(watch);

        CFRunLoopRun();
    }
}
