// nxtch's now-playing helper.
//
// Since macOS 15.4 MediaRemote, where macOS keeps what's playing, only answers Apple's own
// programs. So nxtch doesn't read it itself: it starts /usr/bin/perl, which macOS does answer,
// and has Perl load this library. The library prints one JSON line per change on stdout: the
// song, who plays it, and its cover ("art", base64) once per new cover, "artID" after that.
// It quits within 10 s of nxtch going away.
//
// The idea of a library inside Apple's Perl comes from mediaremote-adapter by Jonas van den Berg
// (BSD-3-Clause, github.com/ungive/mediaremote-adapter). The code here is nxtch's own.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(bool));

static dispatch_queue_t q;
static GetInfoFn getInfo;
static GetClientFn getClient;
static GetPlayingFn getPlaying;
static NSString *last;
static uint64_t lastArt;
static NSString *lastArtSong;   // the song the cover was last sent with
static BOOL due;
static pid_t parent;
// Kept here, not as locals: ARC may free a local after its last use, even in a function that
// never returns. As locals, the timers and observers went quiet at once.
static dispatch_source_t safety, watch;
static NSMutableArray *observers;
static NSString *artFor;   // the song the cover retries are for
static int artTries;

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

/// Reads everything once: who is playing, whether it plays, and the song with its cover.
static void readAll(void) {
    due = NO;
    getClient(q, ^(id client) {
        NSString *bundle = [client respondsToSelector:@selector(bundleIdentifier)] ? [client performSelector:@selector(bundleIdentifier)] : nil;
        NSString *parentID = [client respondsToSelector:@selector(parentApplicationBundleIdentifier)] ? [client performSelector:@selector(parentApplicationBundleIdentifier)] : nil;
        getPlaying(q, ^(bool playing) {
            getInfo(q, ^(NSDictionary *info) {
                NSMutableDictionary *o = [NSMutableDictionary dictionaryWithObject:@(playing) forKey:@"playing"];
                if (info) {
                    o[@"title"] = str(info, @"kMRMediaRemoteNowPlayingInfoTitle");
                    o[@"artist"] = str(info, @"kMRMediaRemoteNowPlayingInfoArtist");
                    o[@"album"] = str(info, @"kMRMediaRemoteNowPlayingInfoAlbum");
                    o[@"elapsed"] = str(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime");
                    o[@"duration"] = str(info, @"kMRMediaRemoteNowPlayingInfoDuration");
                    o[@"rate"] = str(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate");
                    id ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                    if ([ts isKindOfClass:NSDate.class]) o[@"timestamp"] = @([ts timeIntervalSince1970]);
                    id art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    if ([art isKindOfClass:NSData.class] && [art length] > 0 && [art length] < (8 << 20)) {
                        uint64_t h = fnv(art);
                        o[@"artID"] = [NSString stringWithFormat:@"%016llx", h];
                        // The image itself once per cover and song; after that, its id. A new song
                        // gets it again even when the cover is the same (an album), since nxtch
                        // drops the old cover when the song changes.
                        NSString *song = [NSString stringWithFormat:@"%@\n%@", str(info, @"kMRMediaRemoteNowPlayingInfoTitle") ?: @"", str(info, @"kMRMediaRemoteNowPlayingInfoArtist") ?: @""];
                        if (h != lastArt || ![song isEqualToString:lastArtSong]) {
                            lastArt = h;
                            lastArtSong = song;
                            o[@"art"] = [art base64EncodedStringWithOptions:0];
                        }
                    }
                }
                if (bundle) o[@"bundle"] = bundle;
                if (parentID) o[@"parent"] = parentID;
                if (!o[@"artID"]) { lastArt = 0; lastArtSong = nil; }   // nxtch forgets it too
                emit(o);
                // macOS loads covers lazily: the first answer for a song often has none. Ask
                // again a few times, 0.3, 0.6, 1.2 and 2.4 s later.
                NSString *song = [NSString stringWithFormat:@"%@\n%@", o[@"title"] ?: @"", o[@"artist"] ?: @""];
                if (![song isEqualToString:artFor]) { artFor = song; artTries = 0; }
                if (o[@"title"] && !o[@"artID"] && artTries < 4) {
                    int64_t ms = 300LL << artTries++;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), q, ^{ if (!due) readAll(); });
                }
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
        if (!reg || !getInfo || !getClient || !getPlaying) { fprintf(stderr, "MediaRemote functions missing\n"); exit(1); }

        q = dispatch_queue_create("nxtch.nowplaying", DISPATCH_QUEUE_SERIAL);
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
