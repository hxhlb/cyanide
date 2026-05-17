//
//  nano_registry.m
//

#import "nano_registry.h"
#import "remote_objc.h"
#import "../LogTextView.h"
#import "../TaskRop/RemoteCall.h"
#import "../kexploit/krw.h"
#import "../kexploit/kutils.h"
#import "../kexploit/offsets.h"
#import "../kexploit/persistence.h"
#import "../utils/sandbox.h"

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <errno.h>
#import <notify.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString * const kNanoRegistryPlistPath =
    @"/var/mobile/Library/Preferences/com.apple.NanoRegistry.plist";

static NSString * const kKeyMax        = @"maxPairingCompatibilityVersion";
static NSString * const kKeyMin        = @"minPairingCompatibilityVersion";
static NSString * const kKeyMinChipID  = @"minPairingCompatibilityVersionWithChipID";
static NSString * const kKeyMinQuick   = @"minQuickSwitchCompatibilityVersion";

// Notify token NRPairingCompatibilityVersionInfo registers for so it picks up
// new values without a respring. Posting it on its own doesn't refresh
// cfprefsd's cache, so callers still need a respring/reboot in practice —
// the post just lets us announce intent.
static const char *kNanoRegistryChangeNotification =
    "com.apple.nanoregistry.pairingcompatibilityversion";

// Try to land /private/var rw access for the app, mirroring what
// darksword_ota does. Order: existing sandbox → launchd-issued file token →
// patch_sandbox_ext → borrow extensions from known-good donors.
static bool nano_registry_prepare_sandbox(void)
{
    if (check_sandbox_var_rw() == 0) {
        return true;
    }

    if (krw_persistence_consume_launchd_root_file_token() &&
        check_sandbox_var_rw() == 0) {
        printf("[NANO] sandbox ok via launchd root file token\n");
        return true;
    }

    if (patch_sandbox_ext() == 0 && check_sandbox_var_rw() == 0) {
        printf("[NANO] sandbox ok via patch_sandbox_ext\n");
        return true;
    }

    static const char *donors[] = {
        "cfprefsd",
        "sysdiagnosed",
        "softwareupdateservicesd",
        "mobile_installation_proxy",
        "installd",
        NULL,
    };

    for (int i = 0; donors[i]; i++) {
        if (borrow_sandbox_ext(donors[i]) == 0 && check_sandbox_var_rw() == 0) {
            printf("[NANO] sandbox ok via borrow_sandbox_ext(%s)\n", donors[i]);
            return true;
        }
    }

    printf("[NANO] could not unlock /private/var rw access\n");
    return false;
}

static NSMutableDictionary *nano_registry_read_plist(BOOL *outExisted)
{
    if (outExisted) *outExisted = NO;

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:kNanoRegistryPlistPath
                                          options:0
                                            error:&readError];
    if (data.length == 0) {
        if (readError && [readError.domain isEqualToString:NSCocoaErrorDomain] &&
            readError.code == NSFileReadNoSuchFileError) {
            return [NSMutableDictionary dictionary];
        }
        printf("[NANO] read %s failed: %s\n",
               kNanoRegistryPlistPath.UTF8String,
               readError ? readError.description.UTF8String : "empty file");
        return nil;
    }

    if (outExisted) *outExisted = YES;

    NSError *parseError = nil;
    id obj = [NSPropertyListSerialization
        propertyListWithData:data
                     options:NSPropertyListMutableContainersAndLeaves
                      format:NULL
                       error:&parseError];
    if (![obj isKindOfClass:NSMutableDictionary.class]) {
        printf("[NANO] parse %s failed: %s\n",
               kNanoRegistryPlistPath.UTF8String,
               parseError ? parseError.description.UTF8String : "not a dictionary");
        return nil;
    }
    return (NSMutableDictionary *)obj;
}

static bool nano_registry_write_plist(NSDictionary *plist)
{
    NSError *serializeError = nil;
    NSData *outData = [NSPropertyListSerialization
        dataWithPropertyList:plist
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:&serializeError];
    if (outData.length == 0) {
        printf("[NANO] serialize failed: %s\n",
               serializeError ? serializeError.description.UTF8String : "empty");
        return false;
    }

    struct stat existing = {0};
    BOOL hadExisting = (stat(kNanoRegistryPlistPath.UTF8String, &existing) == 0);

    NSError *writeError = nil;
    BOOL ok = [outData writeToFile:kNanoRegistryPlistPath
                           options:NSDataWritingAtomic
                             error:&writeError];
    if (!ok) {
        printf("[NANO] write %s failed: %s\n",
               kNanoRegistryPlistPath.UTF8String,
               writeError ? writeError.description.UTF8String : "unknown");
        return false;
    }

    if (hadExisting) {
        if (chown(kNanoRegistryPlistPath.UTF8String, existing.st_uid, existing.st_gid) != 0) {
            printf("[NANO] chown restore errno=%d\n", errno);
        }
        if (chmod(kNanoRegistryPlistPath.UTF8String, existing.st_mode & 07777) != 0) {
            printf("[NANO] chmod restore errno=%d\n", errno);
        }
    } else {
        chmod(kNanoRegistryPlistPath.UTF8String, 0644);
    }

    int notifyRet = notify_post(kNanoRegistryChangeNotification);
    printf("[NANO] wrote %lu bytes to %s; notify_post(%s) ret=%d\n",
           (unsigned long)outData.length,
           kNanoRegistryPlistPath.UTF8String,
           kNanoRegistryChangeNotification,
           notifyRet);
    return true;
}

bool nano_registry_load(nano_registry_values *out_values, bool *out_present)
{
    if (!out_values) return false;
    if (out_present) *out_present = false;

    BOOL existed = NO;
    NSMutableDictionary *plist = nano_registry_read_plist(&existed);
    if (!plist) {
        return existed ? false : true;
    }

    bool anyKey = false;
    id v;
    if ((v = plist[kKeyMax])       && [v respondsToSelector:@selector(intValue)]) { out_values->max_pairing         = [v intValue]; anyKey = true; }
    if ((v = plist[kKeyMin])       && [v respondsToSelector:@selector(intValue)]) { out_values->min_pairing         = [v intValue]; anyKey = true; }
    if ((v = plist[kKeyMinChipID]) && [v respondsToSelector:@selector(intValue)]) { out_values->min_pairing_chip_id = [v intValue]; anyKey = true; }
    if ((v = plist[kKeyMinQuick])  && [v respondsToSelector:@selector(intValue)]) { out_values->min_quick_switch    = [v intValue]; anyKey = true; }

    if (out_present) *out_present = anyKey;
    return true;
}

bool nano_registry_apply(const nano_registry_values *values)
{
    if (!values) return false;

    if (values->min_pairing > values->max_pairing
        || values->min_pairing_chip_id > values->max_pairing
        || values->min_quick_switch > values->max_pairing) {
        printf("[NANO] refuse apply: min* (%d/%d/%d) must be <= max (%d)\n",
               values->min_pairing, values->min_pairing_chip_id,
               values->min_quick_switch, values->max_pairing);
        return false;
    }

    if (!nano_registry_prepare_sandbox()) return false;

    BOOL existed = NO;
    NSMutableDictionary *plist = nano_registry_read_plist(&existed);
    if (!plist) {
        printf("[NANO] apply aborted: plist unreadable\n");
        return false;
    }

    plist[kKeyMax]       = @(values->max_pairing);
    plist[kKeyMin]       = @(values->min_pairing);
    plist[kKeyMinChipID] = @(values->min_pairing_chip_id);
    plist[kKeyMinQuick]  = @(values->min_quick_switch);

    if (!nano_registry_write_plist(plist)) return false;

    log_user("[NANO] Wrote pairing gates: max=%d min=%d minChip=%d minQuick=%d. Respring/reboot to apply.\n",
             values->max_pairing,
             values->min_pairing,
             values->min_pairing_chip_id,
             values->min_quick_switch);
    return true;
}

bool nano_registry_clear(void)
{
    if (!nano_registry_prepare_sandbox()) return false;

    BOOL existed = NO;
    NSMutableDictionary *plist = nano_registry_read_plist(&existed);
    if (!plist) {
        if (!existed) {
            log_user("[NANO] No override to clear (plist absent).\n");
            return true;
        }
        return false;
    }

    int removed = 0;
    for (NSString *key in @[kKeyMax, kKeyMin, kKeyMinChipID, kKeyMinQuick]) {
        if (plist[key]) { [plist removeObjectForKey:key]; removed++; }
    }

    if (removed == 0) {
        log_user("[NANO] No override keys present; nothing to clear.\n");
        return true;
    }

    if (!nano_registry_write_plist(plist)) return false;
    log_user("[NANO] Cleared %d override key(s). Respring/reboot to apply.\n", removed);
    return true;
}

// --- cfprefsd cache reset via launchd ----------------------------------------
//
// Earlier attempts:
//   1) Inject into cfprefsd and call CFPreferencesSetValue — fails because
//      that's the *client*-side API; from inside cfprefsd it's an RPC to
//      itself that no-ops (Synchronize returned 0 / FALSE).
//   2) Inject into nanoregistryd (the natural CFPreferences client for this
//      domain) and call SetValue from there — nanoregistryd is hardened
//      enough that our EXC_GUARD/thread-hijack flow crashed it.
//
// What actually works: just kill cfprefsd. launchd has it under KeepAlive
// and will respawn it. The new cfprefsd starts with an empty cache, and on
// the very first CFPreferencesCopyValue from any process it reads our plist
// file fresh from /var/mobile/Library/Preferences/com.apple.NanoRegistry.plist.
// From that point our override values are in cfprefsd's cache, so any later
// SetValue on the same domain serializes a cache that *includes* our keys
// back to disk — they no longer get wiped.
//
// We need launchd to issue the kill because cfprefsd runs as root and we're
// uid 501. init_remote_call("launchd", ...) still works after KRW recovery.

// sysctl(KERN_PROC_ALL) is denied to non-privileged apps even after our
// sandbox patch, so we walk the kernel proc list via KRW instead. The uid
// lives inside struct ucred at an offset that varies by iOS version. We
// avoid hardcoding by probing: read our own ucred and scan small offsets
// for a 32-bit value matching geteuid(). The matching offset is cr_uid.
static int32_t nano_probe_ucred_uid_offset(uint64_t my_proc)
{
    if (!my_proc) return -1;
    uint64_t p_proc_ro = kread64(my_proc + off_proc_p_proc_ro);
    if (!is_kaddr_valid(p_proc_ro)) return -1;
    uint64_t ucred = kread64(p_proc_ro + off_proc_ro_p_ucred);
    if (!is_kaddr_valid(ucred)) return -1;

    uid_t expected = geteuid();
    // Plausible offsets for cr_uid in struct ucred across xnu revisions.
    // First field is typically TAILQ_ENTRY or cr_ref; posix_cred begins
    // somewhere in [0x08, 0x20]. cr_uid is the first uid_t in posix_cred.
    static const int32_t kCandidates[] = {
        0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20, 0x24, 0x28, -1,
    };
    for (int i = 0; kCandidates[i] >= 0; i++) {
        uint32_t v = kread32(ucred + (uint64_t)kCandidates[i]);
        if (v == expected) {
            return kCandidates[i];
        }
    }
    return -1;
}

static uint32_t nano_proc_uid(uint64_t proc, int32_t cr_uid_offset)
{
    uint64_t p_proc_ro = kread64(proc + off_proc_p_proc_ro);
    if (!is_kaddr_valid(p_proc_ro)) return UINT32_MAX;
    uint64_t ucred = kread64(p_proc_ro + off_proc_ro_p_ucred);
    if (!is_kaddr_valid(ucred)) return UINT32_MAX;
    return kread32(ucred + (uint64_t)cr_uid_offset);
}

// Walk the proc list and collect pids whose p_name matches any of the given
// names. Returns the number collected (capped at out_capacity).
static int nano_collect_pids_by_names(const char * const *target_names,
                                      int target_name_count,
                                      pid_t *out, int out_capacity)
{
    __block int n = 0;
    uint64_t self_proc = proc_self();
    int32_t uid_off = nano_probe_ucred_uid_offset(self_proc);
    if (uid_off >= 0) {
        printf("[NANO-PUSH] probed ucred cr_uid offset = 0x%x\n", uid_off);
    }

    void (^consider)(uint64_t) = ^(uint64_t proc) {
        if (n >= out_capacity) return;
        char *name = proc_get_p_name(proc);
        if (!name) return;
        bool matched = false;
        for (int i = 0; i < target_name_count; i++) {
            if (strcmp(name, target_names[i]) == 0) { matched = true; break; }
        }
        if (!matched) return;
        pid_t pid = (pid_t)kread32(proc + off_proc_p_pid);
        for (int j = 0; j < n; j++) {
            if (out[j] == pid) return;
        }
        uint32_t uid = (uid_off >= 0) ? nano_proc_uid(proc, uid_off) : UINT32_MAX;
        log_user("[NANO-PUSH] %s pid=%d uid=%u proc=0x%llx\n", name, pid, uid, proc);
        out[n++] = pid;
    };

    uint64_t proc = self_proc;
    for (int i = 0; i < 4096 && is_kaddr_valid(proc) && n < out_capacity; i++) {
        consider(proc);
        uint64_t next = kread64(proc + off_proc_p_list_le_next);
        if (!is_kaddr_valid(next) || next == proc) break;
        proc = next;
    }
    proc = self_proc;
    for (int i = 0; i < 4096 && is_kaddr_valid(proc) && n < out_capacity; i++) {
        consider(proc);
        uint64_t prev = kread64(proc + off_proc_p_list_le_prev);
        if (!is_kaddr_valid(prev) || prev == proc) break;
        proc = prev;
    }
    return n;
}

bool nano_registry_push_to_cfprefsd(const nano_registry_values *values, bool apply)
{
    // values/apply are unused for the kill path — kept in the signature so the
    // function shape doesn't change for callers.
    (void)values;
    (void)apply;

    // Kill cfprefsd so its stale in-memory cache is discarded and the next
    // read reloads our plist from disk. Also kill nanoregistryd so its
    // dispatch_once-cached copy of the four compat values is reset — when
    // launchd respawns it, it pulls the (now correct) values from cfprefsd
    // on its first read. Both daemons are launchd-managed with KeepAlive, so
    // launchd auto-respawns them within a few hundred ms.
    static const char *targets[] = { "cfprefsd", "nanoregistryd" };
    pid_t pids[16] = {0};
    int n = nano_collect_pids_by_names(targets, 2, pids, 16);
    if (n == 0) {
        log_user("[NANO-PUSH] no cfprefsd/nanoregistryd procs found; cache cannot be reset.\n");
        return false;
    }

    // Need launchd to issue the kills — cfprefsd runs as root, we're uid 501.
    if (init_remote_call("launchd", false) != 0) {
        log_user("[NANO-PUSH] init_remote_call(launchd) failed; cannot reset cfprefsd cache.\n");
        return false;
    }

    int killed = 0;
    for (int i = 0; i < n; i++) {
        uint64_t ret = do_remote_call_stable(R_TIMEOUT, "kill",
                                             (uint64_t)pids[i], (uint64_t)SIGKILL,
                                             0, 0, 0, 0, 0, 0);
        BOOL ok = ((int64_t)ret == 0);
        log_user("[NANO-PUSH] launchd->kill(%d, SIGKILL) ret=%lld %s\n",
                 pids[i], (int64_t)ret, ok ? "ok" : "FAILED");
        if (ok) killed++;
    }

    destroy_remote_call();

    if (killed > 0) {
        log_user("[NANO-PUSH] killed %d cache-holding proc(s); launchd KeepAlive will respawn them. "
                 "Override will be live as soon as nanoregistryd reads cfprefsd's freshly-loaded plist.\n",
                 killed);
        // Give launchd time to respawn before we move on.
        usleep(500000);
        int notifyRet = notify_post("com.apple.nanoregistry.pairingcompatibilityversion");
        printf("[NANO-PUSH] notify_post ret=%d\n", notifyRet);
    }

    return killed > 0;
}
