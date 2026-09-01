//
//  ShuDongPatch.m
//  ShuDong tweak — enhancement plugin for 树洞 (co.whou.pick)
//
//  The app is a React Native app shipping a plain (non-Hermes) Metro bundle at
//  <App.app>/main.jsbundle.  Its whole UI lives in JavaScript, so hooking UIKit
//  classes buys us nothing.  Instead this dylib:
//
//    1. reads the original main.jsbundle out of the app bundle,
//    2. applies textual patches to the minified JS,
//    3. writes the result into the app's Caches directory,
//    4. redirects every API the RN bootstrap uses to locate/read the bundle
//       (NSBundle resource lookup + NSData file reads) to the patched copy.
//
//  Implemented with plain Objective-C runtime swizzling: no CydiaSubstrate /
//  ElleKit dependency, so the same dylib works when injected with TrollFools
//  and when shipped inside a regular .deb tweak.
//
//  Patches (verified against 树洞 2.2.965):
//    * hide-important-tip — drops the pinned "重要提示" row (friendId "-1")
//      from the conversation list on the home page.
//    * show-friend-id     — appends the real friend id to every name in the
//      conversation list, reusing NameText's own `appends` prop.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *const kTargetBundleId = @"co.whou.pick";
static NSString *const kJSBundleName = @"main";
static NSString *const kJSBundleExt = @"jsbundle";
static NSString *const kJSBundleFile = @"main.jsbundle";

// Bump whenever the patch table changes so cached output is regenerated.
static NSString *const kPatchVersion = @"4";

static NSString *gOriginalPath = nil;   // real main.jsbundle inside the .app
static NSString *gPatchedPath = nil;    // patched copy, nil until it exists
static NSString *gLogPath = nil;

#define SDLog(fmt, ...) NSLog(@"[ShuDong] " fmt, ##__VA_ARGS__)

typedef struct {
    const char *name;
    const char *find;
    const char *replace;
} SDPatch;

static const SDPatch kPatches[] = {
    // 1) Home page conversation list: drop the pinned "重要提示" entry.
    //
    //    UserListView.render():
    //      this.dataSource = this.dataSource.cloneWithRows(
    //          [].concat(babelHelpers.toConsumableArray(this.state.userListData)))
    //
    //    The notice is an ordinary row whose friendId is the reserved id "-1"
    //    (NameText maps "-1" -> tr("Important Tip")), so filtering the row array
    //    removes it from the list without touching anything else.
    {
        "hide-important-tip",
        "this.dataSource=this.dataSource.cloneWithRows([].concat(babelHelpers.toConsumableArray(this.state.userListData)))",
        "this.dataSource=this.dataSource.cloneWithRows([].concat(babelHelpers.toConsumableArray(this.state.userListData)).filter(function(__sd){return!__sd||\"-1\"!==__sd.friendId}))",
    },

    // 2) Conversation list rows: show the real friend id next to the name.
    //
    //    UserListView.renderRowMiddleBlock(e) renders
    //      createElement(a.NameText,{userid:e.friendId,imageFontSize:15,...})
    //
    //    NameText already supports an `appends` prop which it concatenates onto
    //    the resolved display name (render: myTextValue: this.state.name + this.appends),
    //    so we only have to pass it.
    {
        "show-friend-id",
        "a.NameText,{userid:e.friendId,imageFontSize:15,style:d.rowUserNameText,numberOfLines:1,",
        "a.NameText,{userid:e.friendId,appends:\" [\"+e.friendId+\"]\",imageFontSize:15,style:d.rowUserNameText,numberOfLines:1,",
    },
};

static const size_t kPatchCount = sizeof(kPatches) / sizeof(kPatches[0]);

#pragma mark - logging

static void sd_appendLog(NSString *line) {
    SDLog(@"%@", line);
    if (!gLogPath) {
        return;
    }
    static NSDateFormatter *fmt = nil;
    if (!fmt) {
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    }
    NSString *entry = [NSString stringWithFormat:@"%@  %@\n",
                       [fmt stringFromDate:[NSDate date]], line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [entry writeToFile:gLogPath atomically:YES
                  encoding:NSUTF8StringEncoding error:NULL];
    }
}

#pragma mark - patching

// Applies the patch table to `src`. Returns the patched source, or nil when not
// a single patch matched (the caller then leaves the app completely untouched).
static NSString *sd_applyPatches(NSString *src) {
    NSMutableString *js = [src mutableCopy];
    NSUInteger applied = 0;

    for (size_t i = 0; i < kPatchCount; i++) {
        SDPatch p = kPatches[i];
        NSString *find = [NSString stringWithUTF8String:p.find];
        NSString *repl = [NSString stringWithUTF8String:p.replace];

        if ([js rangeOfString:repl].location != NSNotFound) {
            sd_appendLog([NSString stringWithFormat:@"patch %s: already present, skipped", p.name]);
            applied++;
            continue;
        }

        NSUInteger hits = [js replaceOccurrencesOfString:find
                                             withString:repl
                                                options:NSLiteralSearch
                                                  range:NSMakeRange(0, js.length)];
        sd_appendLog([NSString stringWithFormat:@"patch %s: %lu replacement(s)",
                      p.name, (unsigned long)hits]);
        if (hits > 0) {
            applied++;
        }
    }

    if (applied == 0) {
        sd_appendLog(@"no patch matched — the app bundle probably changed; leaving it untouched");
        return nil;
    }
    if (applied != kPatchCount) {
        sd_appendLog([NSString stringWithFormat:@"WARNING: only %lu/%lu patches applied",
                      (unsigned long)applied, (unsigned long)kPatchCount]);
    }
    return js;
}

// Builds (or reuses) the patched bundle and returns its path, or nil on failure.
static NSString *sd_preparePatchedBundle(void) {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSDictionary *attrs = [fm attributesOfItemAtPath:gOriginalPath error:NULL];
    if (!attrs) {
        sd_appendLog([NSString stringWithFormat:@"original bundle not found at %@", gOriginalPath]);
        return nil;
    }

    NSString *caches = [NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [caches stringByAppendingPathComponent:@"ShuDongTweak"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                   attributes:nil error:NULL];

    gLogPath = [dir stringByAppendingPathComponent:@"patch.log"];

    // Cache key: patch version + source size + source mtime.
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    NSTimeInterval mtime = [(NSDate *)attrs[NSFileModificationDate] timeIntervalSince1970];
    NSString *stamp = [NSString stringWithFormat:@"v%@-%llu-%.0f", kPatchVersion, size, mtime];

    NSString *out = [dir stringByAppendingPathComponent:@"main.patched.jsbundle"];
    NSString *metaPath = [dir stringByAppendingPathComponent:@"main.patched.stamp"];
    NSString *meta = [NSString stringWithContentsOfFile:metaPath
                                              encoding:NSUTF8StringEncoding error:NULL];

    if ([meta isEqualToString:stamp] && [fm fileExistsAtPath:out]) {
        sd_appendLog([NSString stringWithFormat:@"reusing cached patched bundle (%@)", stamp]);
        return out;
    }

    NSError *err = nil;
    NSString *src = [NSString stringWithContentsOfFile:gOriginalPath
                                             encoding:NSUTF8StringEncoding error:&err];
    if (!src.length) {
        sd_appendLog([NSString stringWithFormat:@"failed to read original bundle: %@", err]);
        return nil;
    }

    NSString *patched = sd_applyPatches(src);
    if (!patched) {
        return nil;
    }

    if (![patched writeToFile:out atomically:YES
                    encoding:NSUTF8StringEncoding error:&err]) {
        sd_appendLog([NSString stringWithFormat:@"failed to write patched bundle: %@", err]);
        return nil;
    }
    [stamp writeToFile:metaPath atomically:YES
              encoding:NSUTF8StringEncoding error:NULL];

    sd_appendLog([NSString stringWithFormat:@"patched bundle written: %@ (%lu -> %lu chars)",
                  out, (unsigned long)src.length, (unsigned long)patched.length]);
    return out;
}

#pragma mark - swizzle helpers

static BOOL sd_isOriginalBundlePath(NSString *path) {
    if (!gPatchedPath || path.length == 0) {
        return NO;
    }
    if ([path isEqualToString:gPatchedPath]) {
        return NO;
    }
    return [path.lastPathComponent isEqualToString:kJSBundleFile];
}

static BOOL sd_isJSBundleResource(NSString *name, NSString *ext) {
    if ([name caseInsensitiveCompare:kJSBundleName] != NSOrderedSame &&
        [name caseInsensitiveCompare:kJSBundleFile] != NSOrderedSame) {
        return NO;
    }
    NSString *e = [ext hasPrefix:@"."] ? [ext substringFromIndex:1] : ext;
    return e.length == 0 || [e caseInsensitiveCompare:kJSBundleExt] == NSOrderedSame;
}

static IMP sd_replaceMethod(Class cls, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        SDLog(@"missing method %@ on %@", NSStringFromSelector(sel), cls);
        return NULL;
    }
    return method_setImplementation(m, newImp);
}

#pragma mark - NSBundle hooks

static NSURL *(*orig_URLForResourceWithExtension)(id, SEL, NSString *, NSString *);
static NSURL *sd_URLForResourceWithExtension(id self, SEL _cmd, NSString *name, NSString *ext) {
    if (gPatchedPath && self == [NSBundle mainBundle] && sd_isJSBundleResource(name, ext)) {
        SDLog(@"URLForResource:%@ withExtension:%@ -> patched bundle", name, ext);
        return [NSURL fileURLWithPath:gPatchedPath];
    }
    return orig_URLForResourceWithExtension(self, _cmd, name, ext);
}

static NSString *(*orig_pathForResourceOfType)(id, SEL, NSString *, NSString *);
static NSString *sd_pathForResourceOfType(id self, SEL _cmd, NSString *name, NSString *ext) {
    if (gPatchedPath && self == [NSBundle mainBundle] && sd_isJSBundleResource(name, ext)) {
        SDLog(@"pathForResource:%@ ofType:%@ -> patched bundle", name, ext);
        return gPatchedPath;
    }
    return orig_pathForResourceOfType(self, _cmd, name, ext);
}

static NSURL *(*orig_URLForResourceWithExtensionSubdir)(id, SEL, NSString *, NSString *, NSString *);
static NSURL *sd_URLForResourceWithExtensionSubdir(id self, SEL _cmd, NSString *name,
                                                   NSString *ext, NSString *subdir) {
    if (gPatchedPath && self == [NSBundle mainBundle] && sd_isJSBundleResource(name, ext)) {
        SDLog(@"URLForResource:%@ withExtension:%@ subdirectory:%@ -> patched bundle",
              name, ext, subdir);
        return [NSURL fileURLWithPath:gPatchedPath];
    }
    return orig_URLForResourceWithExtensionSubdir(self, _cmd, name, ext, subdir);
}

static NSString *(*orig_pathForResourceOfTypeInDir)(id, SEL, NSString *, NSString *, NSString *);
static NSString *sd_pathForResourceOfTypeInDir(id self, SEL _cmd, NSString *name,
                                               NSString *ext, NSString *dir) {
    if (gPatchedPath && self == [NSBundle mainBundle] && sd_isJSBundleResource(name, ext)) {
        SDLog(@"pathForResource:%@ ofType:%@ inDirectory:%@ -> patched bundle", name, ext, dir);
        return gPatchedPath;
    }
    return orig_pathForResourceOfTypeInDir(self, _cmd, name, ext, dir);
}

#pragma mark - NSData hooks (fallback when the app builds the path itself)

static NSData *(*orig_dataWithContentsOfFile)(id, SEL, NSString *);
static NSData *sd_dataWithContentsOfFile(id self, SEL _cmd, NSString *path) {
    if (sd_isOriginalBundlePath(path)) {
        SDLog(@"dataWithContentsOfFile: -> patched bundle");
        return orig_dataWithContentsOfFile(self, _cmd, gPatchedPath);
    }
    return orig_dataWithContentsOfFile(self, _cmd, path);
}

static NSData *(*orig_dataWithContentsOfFileOptionsError)(id, SEL, NSString *,
                                                          NSDataReadingOptions, NSError **);
static NSData *sd_dataWithContentsOfFileOptionsError(id self, SEL _cmd, NSString *path,
                                                     NSDataReadingOptions opts, NSError **err) {
    if (sd_isOriginalBundlePath(path)) {
        SDLog(@"dataWithContentsOfFile:options:error: -> patched bundle");
        return orig_dataWithContentsOfFileOptionsError(self, _cmd, gPatchedPath, opts, err);
    }
    return orig_dataWithContentsOfFileOptionsError(self, _cmd, path, opts, err);
}

static NSData *(*orig_dataWithContentsOfURL)(id, SEL, NSURL *);
static NSData *sd_dataWithContentsOfURL(id self, SEL _cmd, NSURL *url) {
    if (url.isFileURL && sd_isOriginalBundlePath(url.path)) {
        SDLog(@"dataWithContentsOfURL: -> patched bundle");
        return orig_dataWithContentsOfURL(self, _cmd, [NSURL fileURLWithPath:gPatchedPath]);
    }
    return orig_dataWithContentsOfURL(self, _cmd, url);
}

static NSData *(*orig_dataWithContentsOfURLOptionsError)(id, SEL, NSURL *,
                                                         NSDataReadingOptions, NSError **);
static NSData *sd_dataWithContentsOfURLOptionsError(id self, SEL _cmd, NSURL *url,
                                                    NSDataReadingOptions opts, NSError **err) {
    if (url.isFileURL && sd_isOriginalBundlePath(url.path)) {
        SDLog(@"dataWithContentsOfURL:options:error: -> patched bundle");
        return orig_dataWithContentsOfURLOptionsError(
            self, _cmd, [NSURL fileURLWithPath:gPatchedPath], opts, err);
    }
    return orig_dataWithContentsOfURLOptionsError(self, _cmd, url, opts, err);
}

static NSFileHandle *(*orig_fileHandleForReadingFromURL)(id, SEL, NSURL *, NSError **);
static NSFileHandle *sd_fileHandleForReadingFromURL(id self, SEL _cmd, NSURL *url, NSError **err) {
    if (url.isFileURL && sd_isOriginalBundlePath(url.path)) {
        SDLog(@"fileHandleForReadingFromURL: -> patched bundle");
        return orig_fileHandleForReadingFromURL(
            self, _cmd, [NSURL fileURLWithPath:gPatchedPath], err);
    }
    return orig_fileHandleForReadingFromURL(self, _cmd, url, err);
}

static NSString *(*orig_stringWithContentsOfFileEncodingError)(id, SEL, NSString *,
                                                               NSStringEncoding, NSError **);
static NSString *sd_stringWithContentsOfFileEncodingError(id self, SEL _cmd, NSString *path,
                                                          NSStringEncoding enc, NSError **err) {
    if (sd_isOriginalBundlePath(path)) {
        SDLog(@"stringWithContentsOfFile:encoding:error: -> patched bundle");
        return orig_stringWithContentsOfFileEncodingError(self, _cmd, gPatchedPath, enc, err);
    }
    return orig_stringWithContentsOfFileEncodingError(self, _cmd, path, enc, err);
}

#pragma mark - install

static IMP sd_replaceClassMethod(Class cls, SEL sel, IMP newImp) {
    return sd_replaceMethod(object_getClass(cls), sel, newImp);
}

static void sd_installHooks(void) {
    orig_URLForResourceWithExtension = (void *)sd_replaceMethod(
        [NSBundle class], @selector(URLForResource:withExtension:),
        (IMP)sd_URLForResourceWithExtension);

    orig_pathForResourceOfType = (void *)sd_replaceMethod(
        [NSBundle class], @selector(pathForResource:ofType:),
        (IMP)sd_pathForResourceOfType);

    orig_URLForResourceWithExtensionSubdir = (void *)sd_replaceMethod(
        [NSBundle class], @selector(URLForResource:withExtension:subdirectory:),
        (IMP)sd_URLForResourceWithExtensionSubdir);

    orig_pathForResourceOfTypeInDir = (void *)sd_replaceMethod(
        [NSBundle class], @selector(pathForResource:ofType:inDirectory:),
        (IMP)sd_pathForResourceOfTypeInDir);

    orig_dataWithContentsOfFile = (void *)sd_replaceClassMethod(
        [NSData class], @selector(dataWithContentsOfFile:),
        (IMP)sd_dataWithContentsOfFile);

    orig_dataWithContentsOfFileOptionsError = (void *)sd_replaceClassMethod(
        [NSData class], @selector(dataWithContentsOfFile:options:error:),
        (IMP)sd_dataWithContentsOfFileOptionsError);

    orig_dataWithContentsOfURL = (void *)sd_replaceClassMethod(
        [NSData class], @selector(dataWithContentsOfURL:),
        (IMP)sd_dataWithContentsOfURL);

    orig_dataWithContentsOfURLOptionsError = (void *)sd_replaceClassMethod(
        [NSData class], @selector(dataWithContentsOfURL:options:error:),
        (IMP)sd_dataWithContentsOfURLOptionsError);

    orig_fileHandleForReadingFromURL = (void *)sd_replaceClassMethod(
        [NSFileHandle class], @selector(fileHandleForReadingFromURL:error:),
        (IMP)sd_fileHandleForReadingFromURL);

    orig_stringWithContentsOfFileEncodingError = (void *)sd_replaceClassMethod(
        [NSString class], @selector(stringWithContentsOfFile:encoding:error:),
        (IMP)sd_stringWithContentsOfFileEncodingError);
}

__attribute__((constructor)) static void sd_init(void) {
    @autoreleasepool {
        NSBundle *main = [NSBundle mainBundle];
        NSString *bid = main.bundleIdentifier ?: @"";

        if (![bid isEqualToString:kTargetBundleId]) {
            SDLog(@"not %@ (running in %@), doing nothing", kTargetBundleId, bid);
            return;
        }

        // Resolve the real bundle path before any hook is installed.
        gOriginalPath = [main.resourcePath stringByAppendingPathComponent:kJSBundleFile];
        if (![[NSFileManager defaultManager] fileExistsAtPath:gOriginalPath]) {
            gOriginalPath = [main pathForResource:kJSBundleName ofType:kJSBundleExt];
        }

        NSString *patched = sd_preparePatchedBundle();
        if (!patched) {
            sd_appendLog(@"giving up, app runs unmodified");
            return;
        }
        gPatchedPath = patched;

        sd_installHooks();
        sd_appendLog([NSString stringWithFormat:@"hooks installed, serving %@", gPatchedPath]);
    }
}






