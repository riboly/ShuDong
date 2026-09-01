//
//  ShuDongPatch.m
//  ShuDong tweak — enhancement plugin for 树洞 (co.whou.pick)
//
//  树洞 is a React Native app with a plain (non-Hermes) Metro bundle, and it
//  ships its own hot-update mechanism: the JS it actually runs is the
//  downloaded bundle at <Documents>/dbundle/__hvdown__ whenever that file
//  exists, falling back to <App.app>/main.jsbundle only otherwise.  Patching
//  just the bundled copy therefore changes nothing on a device that has ever
//  taken an update — which is exactly why the previous revision loaded,
//  patched and hooked correctly yet had no visible effect.
//
//  So this dylib handles both sources:
//
//    * <Documents>/dbundle/__hvdown__ (and __hvdown_old__) live in the app's
//      own container and are writable, so they are patched in place from the
//      dylib constructor, i.e. before React Native ever opens them.  This works
//      no matter which API the RN bootstrap uses (NSData, NSFileHandle, fopen,
//      mmap, ...).  The untouched original is kept beside them as
//      <name>.sdorig and the modification date is restored afterwards.
//    * <App.app>/main.jsbundle sits in the read-only app bundle, so a patched
//      copy is written into Caches and every API RN uses to locate or read the
//      bundle is redirected to that copy.
//
//  Implemented with plain Objective-C runtime swizzling: no CydiaSubstrate /
//  ElleKit link dependency, so the same dylib works when injected with
//  TrollFools and when shipped inside a regular .deb tweak.
//
//  Patches (verified against both the bundled 2.2.965 JS and the current
//  hot-updated bundle):
//    * hide-important-tip — drops the pinned "重要提示" row (friendId "-1")
//      from the conversation list on the home page.
//    * remove-friend-id   — removes the optional real friend id suffix from
//      conversation-list names while keeping the full id on profile screens.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *const kTargetBundleId = @"co.whou.pick";
static NSString *const kJSBundleName = @"main";
static NSString *const kJSBundleExt = @"jsbundle";
static NSString *const kJSBundleFile = @"main.jsbundle";
static NSString *const kBackupSuffix = @".sdorig";

// Bump whenever the patch table changes so cached output is regenerated.
static NSString *const kPatchVersion = @"8";

// Hot-update bundles inside the app container, newest-first.  Relative to
// <Documents>.  __hvdown_old__ is the rollback copy the app keeps around.
static NSString *const kHotBundlePaths[] = {
    @"dbundle/__hvdown__",
    @"dbundle/__hvdown_old__",
};
static const size_t kHotBundleCount =
    sizeof(kHotBundlePaths) / sizeof(kHotBundlePaths[0]);

// Original path -> patched path, for sources we cannot rewrite in place.
static NSMutableDictionary<NSString *, NSString *> *gRedirects = nil;
static NSString *gMainPatchedPath = nil;  // patched copy of main.jsbundle
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

    // 2) Conversation list rows: remove the optional real friend id suffix.
    //
    //    UserListView.renderRowMiddleBlock(e) renders
    //      createElement(a.NameText,{userid:e.friendId,imageFontSize:15,...})
    //
    //    This reverses the earlier show-friend-id patch when upgrading an
    //    already-patched hot-update bundle.
    {
        "remove-friend-id",
        "a.NameText,{userid:e.friendId,appends:\" [\"+e.friendId+\"]\",imageFontSize:15,style:d.rowUserNameText,numberOfLines:1,",
        "a.NameText,{userid:e.friendId,imageFontSize:15,style:d.rowUserNameText,numberOfLines:1,",
    },

    // 3) Friend profile: show the complete id (the stock UI truncates it to
    // six characters).  The value row itself copies the id when tapped.
    {
        "profile-full-friend-id",
        "{type:\"btn\",label:(0,s.tr)(\"\\u7528\\u6237ID\"),value:t.slice(0,6)}",
        "{type:\"btn\",label:(0,s.tr)(\"\\u7528\\u6237ID\"),value:t,onPress:function(){a.Clipboard.setString(t),e.tip(\"ID已复制\")}}",
    },

    // Upgrade path from v7, which added a separate copy button.
    {
        "profile-copy-button-migration",
        "{type:\"btn\",label:(0,s.tr)(\"\\u7528\\u6237ID\"),value:t},{type:\"pbtn\",style:{marginTop:5},color:s.theme.deepGreen2Trans6,textColor:s.theme.white,text:\"\\u590d\\u5236ID\",onPress:function(){e.emit(\"sdCopyFriendId\",t)}}",
        "{type:\"btn\",label:(0,s.tr)(\"\\u7528\\u6237ID\"),value:t,onPress:function(){a.Clipboard.setString(t),e.tip(\"ID已复制\")}}",
    },

    // 4) Settings page: insert an Add Chat button before notification
    // settings.  The callback opens a two-field dialog and calls the helper
    // inserted below, which uses the app's own sendShareReply pipeline.
    {
        "settings-add-chat-button",
        "{type:\"bar\"},e.showCmdBall||e.pkgvv===e.version||e.isTempUserid()?{type:\"btn\",label:(0,s.tr)(\"Add Friends\"),value:\" \",onPress:function(){return e.addNewFriendDiag()}}:null",
        "{type:\"bar\"},{type:\"pbtn\",style:{marginTop:8},color:s.theme.deepGreen2Trans6,textColor:s.theme.white,text:\"添加聊天\",onPress:function(){return e.sdAddChatDiag()}},e.showCmdBall||e.pkgvv===e.version||e.isTempUserid()?{type:\"btn\",label:(0,s.tr)(\"Add Friends\"),value:\" \",onPress:function(){return e.addNewFriendDiag()}}:null",
    },

    // 5) Settings page: expose this account's chat id directly below the
    // account row.  Tapping the value writes it to the native clipboard.
    {
        "settings-own-chat-id",
        "{type:\"btn\",name:\"Account\",label:(0,s.tr)(\"Account ID\"),value:i?\" \":e.account,onPress:function(n,r){t===e.userid&&e.setAccount(n)}},{type:\"bar\"},",
        "{type:\"btn\",name:\"Account\",label:(0,s.tr)(\"Account ID\"),value:i?\" \":e.account,onPress:function(n,r){t===e.userid&&e.setAccount(n)}},{type:\"btn\",name:\"ChatId\",label:\"聊天ID\",value:e.userid,onPress:function(){a.Clipboard.setString(e.userid),e.tip(\"ID已复制\") }},{type:\"bar\"},",
    },

    // Upgrade path from v7 settings row, which used the event bridge.
    {
        "settings-chat-copy-migration",
        "{type:\"btn\",name:\"Account\",label:(0,s.tr)(\"Account ID\"),value:i?\" \":e.account,onPress:function(n,r){t===e.userid&&e.setAccount(n)}},{type:\"btn\",name:\"ChatId\",label:\"聊天ID\",value:e.userid,onPress:function(){e.emit(\"sdCopyFriendId\",e.userid)}},{type:\"bar\"},",
        "{type:\"btn\",name:\"Account\",label:(0,s.tr)(\"Account ID\"),value:i?\" \":e.account,onPress:function(n,r){t===e.userid&&e.setAccount(n)}},{type:\"btn\",name:\"ChatId\",label:\"聊天ID\",value:e.userid,onPress:function(){a.Clipboard.setString(e.userid),e.tip(\"ID已复制\") }},{type:\"bar\"},",
    },

    // 8) Direct text sender and its two-input dialog.  This mirrors the
    // parameters used by InteractView for a normal one-to-one conversation.
    {
        "direct-chat-helper",
        "e.sendBottleReply=function(t,n,r,i,o){",
        "e.sendDirectText=function(t,n){return new Promise(function(r,i){t=(t||\"\").trim(),n=(n||\"\").trim();if(!t||!n)return void i(\"empty\");var o=e.getChatSession(t,e.userid),a=e.getFid(t,e.userid,o);Promise.all([e.getRelationShip(t),e.getProfileK(t,\"forbid\"),e.getMsgscnt(t,e.userid),e.isPeopleApproved(t)]).then(function(i){var s=i[0]||{},u=i[1]||e.CONS_FORBID_NORMAL,d=i[2],c=i[3];if(e.isUserForbided(u))throw\"forbidden\";if(s.blocked)throw\"blocked\";var f=s.isFriend?1:0,l=s.isStared?1:0,h=s.isFollowed?1:0,m=s.isCut,v=e.getNewMsgId(t,o);return e.sendShareReply(\"newMsg\",{shareId:t,msgid:v,msgscnt:d,fromId:e.userid,toId:t,chatSession:o,shareFrom:t,friendId:t,type:e.CONS_MSG_TYPE_TEXT,data:n,category:2,ftype:1,fid:a,seqi:0,atime:0,isFriend:f,userid:l?e.userid:\"3:\"+e.userid,isPraised:0,isStared:l,utab:h?1:2,isApproved:!!c,isCut:m})}).then(r,i)})},e.sdAddChatDiag=function(){var t=e; e.diag({header:\"添加聊天\",content:\"输入好友真实ID和消息内容\",textInputs:[{placeholder:\"好友真实ID\",value:\"\",maxLength:80},{placeholder:\"消息内容\",value:\"\",maxLength:2500}],buttons:[{text:(0,s.tr)(\"Cancel\"),onPress:function(){return e.closeDiag()}},{text:\"发送\",onPress:function(n){if(!n.isProgressing){var i=(n.state.textInputs[0].value||\"\").trim(),o=(n.state.textInputs[1].value||\"\").trim();if(i&&o)return n.progressing(!0),void t.sendDirectText(i,o).then(function(){n.progressing(!1),t.closeDiag(function(){t.tip(\"消息已发送\")})})[\"catch\"](function(e){n.progressing(!1),n.setState({infoTip:\"发送失败: \"+e})});n.setState({infoTip:\"请输入好友真实ID和消息内容\"})}}}]})},e.sendBottleReply=function(t,n,r,i,o){",
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

// Logs `line` only the first time it is seen, so hooks on hot paths cannot
// flood patch.log.
static void sd_appendLogOnce(NSString *line) {
    static NSMutableSet *seen = nil;
    if (!seen) {
        seen = [NSMutableSet set];
    }
    @synchronized (seen) {
        if ([seen containsObject:line]) {
            return;
        }
        [seen addObject:line];
    }
    sd_appendLog(line);
}

#pragma mark - patching

// Applies the patch table to `src`.  Returns the patched source, or nil when not
// a single patch matched (the caller then leaves that file completely alone).
// *outChanged tells the caller whether anything was actually rewritten, so an
// already-patched file is not needlessly written back to disk.
static NSString *sd_applyPatches(NSString *src, NSString *label, BOOL *outChanged) {
    NSMutableString *js = [src mutableCopy];
    NSUInteger applied = 0;
    NSUInteger changed = 0;

    for (size_t i = 0; i < kPatchCount; i++) {
        SDPatch p = kPatches[i];
        NSString *find = [NSString stringWithUTF8String:p.find];
        NSString *repl = [NSString stringWithUTF8String:p.replace];

        if ([js rangeOfString:repl].location != NSNotFound) {
            sd_appendLog([NSString stringWithFormat:@"%@: patch %s already present",
                          label, p.name]);
            applied++;
            continue;
        }

        NSUInteger hits = [js replaceOccurrencesOfString:find
                                             withString:repl
                                                options:NSLiteralSearch
                                                  range:NSMakeRange(0, js.length)];
        sd_appendLog([NSString stringWithFormat:@"%@: patch %s -> %lu replacement(s)",
                      label, p.name, (unsigned long)hits]);
        if (hits > 0) {
            applied++;
            changed += hits;
        }
    }

    if (applied == 0) {
        sd_appendLog([NSString stringWithFormat:
            @"%@: no patch matched — JS changed, leaving this file untouched", label]);
        return nil;
    }
    if (applied != kPatchCount) {
        sd_appendLog([NSString stringWithFormat:@"%@: WARNING only %lu/%lu patches applied",
                      label, (unsigned long)applied, (unsigned long)kPatchCount]);
    }
    if (outChanged) {
        *outChanged = (changed > 0);
    }
    return js;
}

// Rewrites a writable bundle (the hot-update copies in <Documents>) in place.
// Keeps <path>.sdorig as a pristine backup and restores the modification date
// so the app cannot tell the file was touched.  Returns YES when the file on
// disk now carries our patches.
static BOOL sd_patchInPlace(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *label = path.lastPathComponent;

    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
    if (!attrs) {
        return NO;
    }

    NSError *err = nil;
    NSString *src = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding error:&err];
    if (!src.length) {
        sd_appendLog([NSString stringWithFormat:@"%@: unreadable (%@)", label, err]);
        return NO;
    }

    BOOL changed = NO;
    NSString *patched = sd_applyPatches(src, label, &changed);
    if (!patched) {
        return NO;
    }
    if (!changed) {
        sd_appendLog([NSString stringWithFormat:@"%@: already patched on disk, nothing to do",
                      label]);
        return YES;
    }

    NSString *backup = [path stringByAppendingString:kBackupSuffix];
    if (![fm fileExistsAtPath:backup]) {
        if ([fm copyItemAtPath:path toPath:backup error:&err]) {
            sd_appendLog([NSString stringWithFormat:@"%@: original backed up to %@",
                          label, backup.lastPathComponent]);
        } else {
            sd_appendLog([NSString stringWithFormat:@"%@: backup failed (%@), aborting",
                          label, err]);
            return NO;
        }
    }

    if (![patched writeToFile:path atomically:YES
                    encoding:NSUTF8StringEncoding error:&err]) {
        sd_appendLog([NSString stringWithFormat:@"%@: in-place write failed (%@)", label, err]);
        return NO;
    }

    // Put the original mtime and permissions back: atomic writes create a new
    // inode, and the app keys its update bookkeeping off this file.
    NSMutableDictionary *restore = [NSMutableDictionary dictionary];
    if (attrs[NSFileModificationDate]) {
        restore[NSFileModificationDate] = attrs[NSFileModificationDate];
    }
    if (attrs[NSFilePosixPermissions]) {
        restore[NSFilePosixPermissions] = attrs[NSFilePosixPermissions];
    }
    [fm setAttributes:restore ofItemAtPath:path error:NULL];

    sd_appendLog([NSString stringWithFormat:@"%@: patched in place (%lu -> %lu chars)",
                  label, (unsigned long)src.length, (unsigned long)patched.length]);
    return YES;
}

static NSString *sd_tweakCachesDir(void) {
    NSString *caches = [NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [caches stringByAppendingPathComponent:@"ShuDongTweak"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES
                                              attributes:nil error:NULL];
    return dir;
}

// Builds (or reuses) a patched copy of a read-only source and registers a
// redirect for it.  Returns the patched path, or nil on failure.
static NSString *sd_preparePatchedCopy(NSString *origPath, NSString *outName) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *label = origPath.lastPathComponent;

    NSDictionary *attrs = [fm attributesOfItemAtPath:origPath error:NULL];
    if (!attrs) {
        sd_appendLog([NSString stringWithFormat:@"%@: not found at %@", label, origPath]);
        return nil;
    }

    NSString *dir = sd_tweakCachesDir();
    NSString *out = [dir stringByAppendingPathComponent:outName];
    NSString *stampPath = [out stringByAppendingPathExtension:@"stamp"];

    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    NSTimeInterval mtime = [(NSDate *)attrs[NSFileModificationDate] timeIntervalSince1970];
    NSString *stamp = [NSString stringWithFormat:@"v%@-%llu-%.0f", kPatchVersion, size, mtime];
    NSString *have = [NSString stringWithContentsOfFile:stampPath
                                              encoding:NSUTF8StringEncoding error:NULL];

    if ([have isEqualToString:stamp] && [fm fileExistsAtPath:out]) {
        sd_appendLog([NSString stringWithFormat:@"%@: reusing cached patched copy (%@)",
                      label, stamp]);
        gRedirects[origPath] = out;
        return out;
    }

    NSError *err = nil;
    NSString *src = [NSString stringWithContentsOfFile:origPath
                                             encoding:NSUTF8StringEncoding error:&err];
    if (!src.length) {
        sd_appendLog([NSString stringWithFormat:@"%@: unreadable (%@)", label, err]);
        return nil;
    }

    NSString *patched = sd_applyPatches(src, label, NULL);
    if (!patched) {
        return nil;
    }
    if (![patched writeToFile:out atomically:YES
                    encoding:NSUTF8StringEncoding error:&err]) {
        sd_appendLog([NSString stringWithFormat:@"%@: write failed (%@)", label, err]);
        return nil;
    }
    [stamp writeToFile:stampPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    sd_appendLog([NSString stringWithFormat:@"%@: patched copy written to %@ (%lu -> %lu chars)",
                  label, out, (unsigned long)src.length, (unsigned long)patched.length]);
    gRedirects[origPath] = out;
    return out;
}

#pragma mark - swizzle helpers

// Returns the patched replacement for `path`, or nil when the path is none of
// our business.  Matching is by full path first (exact redirect) and then by
// file name, so a container path we did not enumerate still resolves.
static NSString *sd_redirectForPath(NSString *path) {
    if (path.length == 0 || gRedirects.count == 0) {
        return nil;
    }
    NSString *hit = gRedirects[path];
    if (hit) {
        return [hit isEqualToString:path] ? nil : hit;
    }
    if (gMainPatchedPath && [path.lastPathComponent isEqualToString:kJSBundleFile] &&
        ![path isEqualToString:gMainPatchedPath]) {
        return gMainPatchedPath;
    }
    return nil;
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
        sd_appendLog([NSString stringWithFormat:@"missing method %@ on %@",
                      NSStringFromSelector(sel), cls]);
        return NULL;
    }
    return method_setImplementation(m, newImp);
}

static IMP sd_replaceClassMethod(Class cls, SEL sel, IMP newImp) {
    return sd_replaceMethod(object_getClass(cls), sel, newImp);
}

#pragma mark - NSBundle hooks

static NSURL *(*orig_URLForResourceWithExtension)(id, SEL, NSString *, NSString *);
static NSURL *sd_URLForResourceWithExtension(id self, SEL _cmd, NSString *name, NSString *ext) {
    if (gMainPatchedPath && self == [NSBundle mainBundle] && sd_isJSBundleResource(name, ext)) {
        sd_appendLogOnce(@"hook: URLForResource:withExtension: -> patched main.jsbundle");
        return [NSURL fileURLWithPath:gMainPatchedPath];
    }
    return orig_URLForResourceWithExtension(self, _cmd, name, ext);
}

static NSString *(*orig_pathForResourceOfType)(id, SEL, NSString *, NSString *);
static NSString *sd_pathForResourceOfType(id self, SEL _cmd, NSString *name, NSString *ext) {
    if (gMainPatchedPath && self == [NSBundle mainBundle] && sd_isJSBundleResource(name, ext)) {
        sd_appendLogOnce(@"hook: pathForResource:ofType: -> patched main.jsbundle");
        return gMainPatchedPath;
    }
    return orig_pathForResourceOfType(self, _cmd, name, ext);
}

static NSURL *(*orig_URLForResourceWithExtensionSubdir)(id, SEL, NSString *, NSString *, NSString *);
static NSURL *sd_URLForResourceWithExtensionSubdir(id self, SEL _cmd, NSString *name,
                                                   NSString *ext, NSString *subdir) {
    if (gMainPatchedPath && self == [NSBundle mainBundle] && sd_isJSBundleResource(name, ext)) {
        sd_appendLogOnce(@"hook: URLForResource:withExtension:subdirectory: -> patched main.jsbundle");
        return [NSURL fileURLWithPath:gMainPatchedPath];
    }
    return orig_URLForResourceWithExtensionSubdir(self, _cmd, name, ext, subdir);
}

static NSString *(*orig_pathForResourceOfTypeInDir)(id, SEL, NSString *, NSString *, NSString *);
static NSString *sd_pathForResourceOfTypeInDir(id self, SEL _cmd, NSString *name,
                                               NSString *ext, NSString *dir) {
    if (gMainPatchedPath && self == [NSBundle mainBundle] && sd_isJSBundleResource(name, ext)) {
        sd_appendLogOnce(@"hook: pathForResource:ofType:inDirectory: -> patched main.jsbundle");
        return gMainPatchedPath;
    }
    return orig_pathForResourceOfTypeInDir(self, _cmd, name, ext, dir);
}

#pragma mark - file read hooks (used when the app builds the path itself)

static NSData *(*orig_dataWithContentsOfFile)(id, SEL, NSString *);
static NSData *sd_dataWithContentsOfFile(id self, SEL _cmd, NSString *path) {
    NSString *to = sd_redirectForPath(path);
    if (to) {
        sd_appendLogOnce([NSString stringWithFormat:@"hook: dataWithContentsOfFile: %@ -> %@",
                          path.lastPathComponent, to.lastPathComponent]);
        return orig_dataWithContentsOfFile(self, _cmd, to);
    }
    return orig_dataWithContentsOfFile(self, _cmd, path);
}

static NSData *(*orig_dataWithContentsOfFileOptionsError)(id, SEL, NSString *,
                                                          NSDataReadingOptions, NSError **);
static NSData *sd_dataWithContentsOfFileOptionsError(id self, SEL _cmd, NSString *path,
                                                     NSDataReadingOptions opts, NSError **err) {
    NSString *to = sd_redirectForPath(path);
    if (to) {
        sd_appendLogOnce([NSString stringWithFormat:
            @"hook: dataWithContentsOfFile:options: %@ -> %@",
            path.lastPathComponent, to.lastPathComponent]);
        return orig_dataWithContentsOfFileOptionsError(self, _cmd, to, opts, err);
    }
    return orig_dataWithContentsOfFileOptionsError(self, _cmd, path, opts, err);
}

static NSData *(*orig_dataWithContentsOfURL)(id, SEL, NSURL *);
static NSData *sd_dataWithContentsOfURL(id self, SEL _cmd, NSURL *url) {
    NSString *to = url.isFileURL ? sd_redirectForPath(url.path) : nil;
    if (to) {
        sd_appendLogOnce([NSString stringWithFormat:@"hook: dataWithContentsOfURL: %@ -> %@",
                          url.lastPathComponent, to.lastPathComponent]);
        return orig_dataWithContentsOfURL(self, _cmd, [NSURL fileURLWithPath:to]);
    }
    return orig_dataWithContentsOfURL(self, _cmd, url);
}

static NSData *(*orig_dataWithContentsOfURLOptionsError)(id, SEL, NSURL *,
                                                         NSDataReadingOptions, NSError **);
static NSData *sd_dataWithContentsOfURLOptionsError(id self, SEL _cmd, NSURL *url,
                                                    NSDataReadingOptions opts, NSError **err) {
    NSString *to = url.isFileURL ? sd_redirectForPath(url.path) : nil;
    if (to) {
        sd_appendLogOnce([NSString stringWithFormat:
            @"hook: dataWithContentsOfURL:options: %@ -> %@",
            url.lastPathComponent, to.lastPathComponent]);
        return orig_dataWithContentsOfURLOptionsError(
            self, _cmd, [NSURL fileURLWithPath:to], opts, err);
    }
    return orig_dataWithContentsOfURLOptionsError(self, _cmd, url, opts, err);
}

static NSFileHandle *(*orig_fileHandleForReadingFromURL)(id, SEL, NSURL *, NSError **);
static NSFileHandle *sd_fileHandleForReadingFromURL(id self, SEL _cmd, NSURL *url, NSError **err) {
    NSString *to = url.isFileURL ? sd_redirectForPath(url.path) : nil;
    if (to) {
        sd_appendLogOnce([NSString stringWithFormat:@"hook: fileHandleForReadingFromURL: %@ -> %@",
                          url.lastPathComponent, to.lastPathComponent]);
        return orig_fileHandleForReadingFromURL(self, _cmd, [NSURL fileURLWithPath:to], err);
    }
    return orig_fileHandleForReadingFromURL(self, _cmd, url, err);
}

static NSFileHandle *(*orig_fileHandleForReadingAtPath)(id, SEL, NSString *);
static NSFileHandle *sd_fileHandleForReadingAtPath(id self, SEL _cmd, NSString *path) {
    NSString *to = sd_redirectForPath(path);
    if (to) {
        sd_appendLogOnce([NSString stringWithFormat:@"hook: fileHandleForReadingAtPath: %@ -> %@",
                          path.lastPathComponent, to.lastPathComponent]);
        return orig_fileHandleForReadingAtPath(self, _cmd, to);
    }
    return orig_fileHandleForReadingAtPath(self, _cmd, path);
}

static NSString *(*orig_stringWithContentsOfFileEncodingError)(id, SEL, NSString *,
                                                               NSStringEncoding, NSError **);
static NSString *sd_stringWithContentsOfFileEncodingError(id self, SEL _cmd, NSString *path,
                                                          NSStringEncoding enc, NSError **err) {
    NSString *to = sd_redirectForPath(path);
    if (to) {
        sd_appendLogOnce([NSString stringWithFormat:
            @"hook: stringWithContentsOfFile:encoding: %@ -> %@",
            path.lastPathComponent, to.lastPathComponent]);
        return orig_stringWithContentsOfFileEncodingError(self, _cmd, to, enc, err);
    }
    return orig_stringWithContentsOfFileEncodingError(self, _cmd, path, enc, err);
}

#pragma mark - install

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

    orig_fileHandleForReadingAtPath = (void *)sd_replaceClassMethod(
        [NSFileHandle class], @selector(fileHandleForReadingAtPath:),
        (IMP)sd_fileHandleForReadingAtPath);

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

        gRedirects = [NSMutableDictionary dictionary];
        gLogPath = [sd_tweakCachesDir() stringByAppendingPathComponent:@"patch.log"];
        sd_appendLog([NSString stringWithFormat:@"--- v%@ launch, home=%@",
                      kPatchVersion, NSHomeDirectory()]);

        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *docs = [NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSUInteger live = 0;

        // 1) The hot-updated bundles the app actually runs.  Writable, so patch
        //    them on disk before React Native gets a chance to read them.
        for (size_t i = 0; i < kHotBundleCount; i++) {
            NSString *path = [docs stringByAppendingPathComponent:kHotBundlePaths[i]];
            if (![fm fileExistsAtPath:path]) {
                continue;
            }
            if (sd_patchInPlace(path)) {
                live++;
                continue;
            }
            // Read-only or write refused: fall back to serving a patched copy.
            NSString *outName = [NSString stringWithFormat:@"%@.patched.js",
                                 path.lastPathComponent];
            if (sd_preparePatchedCopy(path, outName)) {
                live++;
            }
        }

        // 2) The bundled fallback inside the read-only .app.
        NSString *bundled = [main.resourcePath stringByAppendingPathComponent:kJSBundleFile];
        if (![fm fileExistsAtPath:bundled]) {
            bundled = [main pathForResource:kJSBundleName ofType:kJSBundleExt];
        }
        if (bundled.length) {
            gMainPatchedPath = sd_preparePatchedCopy(bundled, @"main.patched.jsbundle");
            if (gMainPatchedPath) {
                live++;
            }
        }

        if (live == 0) {
            sd_appendLog(@"nothing patched, app runs unmodified");
            return;
        }

        sd_installHooks();
        sd_appendLog([NSString stringWithFormat:@"ready: %lu source(s) patched, %lu redirect(s)",
                      (unsigned long)live, (unsigned long)gRedirects.count]);
    }
}
