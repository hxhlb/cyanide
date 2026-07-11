//
//  ipadecryptor.m
//  Cyanide local IPA decryptor (installed apps only).
//
//  FairPlay memory dump adapted from lara/kexploit/decrypt.m (neonmodder123)
//  onto Cyanide KRW / vm_map_remote_page primitives.
//  No App Store login/download — decrypt already-installed user apps only.
//

#import "ipadecryptor.h"
#import "../../LogTextView.h"
#import "../../kexploit/kutils.h"
#import "../../kexploit/krw.h"
#import "../../kexploit/offsets.h"
#import "../../kexploit/kexploit_opa334.h"
#import "../../TaskRop/VM.h"
#import "../../utils/sandbox.h"

#import <Foundation/Foundation.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <libkern/OSByteOrder.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <copyfile.h>
#import <fcntl.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <zlib.h>

// iOS SDK does not ship libproc.h; the symbols exist in libsystem.
#ifndef PROC_ALL_PIDS
#define PROC_ALL_PIDS 1
#endif
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN)
#endif
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

extern kern_return_t mach_vm_deallocate(task_t task, mach_vm_address_t addr, mach_vm_size_t size);

// Declared in TaskRop/VM.m but not all are re-exported from VM.h yet.
void vm_map_iterate_entries(uint64_t vm_map_ptr, void (^itBlock)(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop));

static NSString * const kIPADecryptorKeyBundleID = @"bundleID";
static NSString * const kIPADecryptorKeyName = @"name";
static NSString * const kIPADecryptorKeyBundlePath = @"bundlePath";

typedef struct {
    bool isMachO;
    bool hasEncryptionInfo;
    uint32_t cryptid;
    uint32_t cryptoff;
    uint32_t cryptsize;
    uint32_t archCount;
} IPADecryptorMachOInfo;

static NSString *ipadec_nonempty_string(id value)
{
    return [value isKindOfClass:NSString.class] && [(NSString *)value length] > 0
        ? (NSString *)value
        : nil;
}

static id ipadec_perform0(id target, SEL selector)
{
    if (!target || !selector || ![target respondsToSelector:selector]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [target performSelector:selector];
#pragma clang diagnostic pop
}

static NSString *ipadec_bundle_path_from_proxy(id proxy)
{
    NSURL *bundleURL = ipadec_perform0(proxy, @selector(bundleURL));
    if ([bundleURL isKindOfClass:NSURL.class] && bundleURL.path.length > 0) {
        return bundleURL.path;
    }

    NSURL *containerURL = ipadec_perform0(proxy, @selector(bundleContainerURL));
    if ([containerURL isKindOfClass:NSURL.class] && containerURL.path.length > 0) {
        return containerURL.path;
    }
    return nil;
}

static NSMutableDictionary<NSString *, NSString *> *ipadec_app_entry(NSString *bundleID,
                                                                     NSString *name,
                                                                     NSString *bundlePath)
{
    if (bundleID.length == 0 || bundlePath.length == 0) return nil;
    NSMutableDictionary<NSString *, NSString *> *entry = [NSMutableDictionary dictionary];
    entry[kIPADecryptorKeyBundleID] = bundleID;
    entry[kIPADecryptorKeyName] = name.length > 0 ? name : bundleID;
    entry[kIPADecryptorKeyBundlePath] = bundlePath;
    return entry;
}

static NSMutableDictionary<NSString *, NSString *> *ipadec_launch_entry(NSString *bundleID,
                                                                        NSString *name,
                                                                        NSString *bundlePath)
{
    if (bundleID.length == 0) return nil;
    NSMutableDictionary<NSString *, NSString *> *entry = [NSMutableDictionary dictionary];
    entry[kIPADecryptorKeyBundleID] = bundleID;
    entry[kIPADecryptorKeyName] = name.length > 0 ? name : bundleID;
    entry[kIPADecryptorKeyBundlePath] = bundlePath.length > 0 ? bundlePath : @"";
    return entry;
}

static BOOL ipadec_bundle_path_is_user_app(NSString *bundlePath)
{
    return [bundlePath rangeOfString:@"/Bundle/Application/"].location != NSNotFound ||
           [bundlePath rangeOfString:@"/Containers/Bundle/Application/"].location != NSNotFound;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *ipadec_apps_from_launchservices(BOOL includeSystemApps)
{
    dlopen("/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = ipadec_perform0(workspaceClass, @selector(defaultWorkspace));
    NSArray *proxies = ipadec_perform0(workspace, @selector(allApplications));
    if (![proxies isKindOfClass:NSArray.class]) return @[];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id proxy in proxies) {
        NSString *bundleID = ipadec_nonempty_string(ipadec_perform0(proxy, @selector(bundleIdentifier)));
        if (bundleID.length == 0 || [seen containsObject:bundleID]) continue;

        NSString *bundlePath = ipadec_bundle_path_from_proxy(proxy);
        if (bundlePath.length == 0 && !includeSystemApps) continue;

        // IPA decryption is only meaningful for user-installed app bundles.
        // MWLite can opt into system apps because it only needs launchable apps.
        if (!includeSystemApps && !ipadec_bundle_path_is_user_app(bundlePath)) {
            continue;
        }

        NSString *name = ipadec_nonempty_string(ipadec_perform0(proxy, @selector(localizedName)));
        if (name.length == 0) name = ipadec_nonempty_string(ipadec_perform0(proxy, @selector(itemName)));
        NSMutableDictionary *entry = includeSystemApps
            ? ipadec_launch_entry(bundleID, name, bundlePath)
            : ipadec_app_entry(bundleID, name, bundlePath);
        if (!entry) continue;
        [out addObject:entry];
        [seen addObject:bundleID];
    }
    return out;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *ipadec_apps_from_bundle_scan(void)
{
    NSArray<NSString *> *roots = @[
        @"/private/var/containers/Bundle/Application",
        @"/var/containers/Bundle/Application",
    ];
    NSFileManager *fm = NSFileManager.defaultManager;

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *root in roots) {
        NSArray<NSString *> *containers = [fm contentsOfDirectoryAtPath:root error:nil];
        if (containers.count == 0) continue;
        for (NSString *container in containers) {
            NSString *containerPath = [root stringByAppendingPathComponent:container];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:containerPath isDirectory:&isDir] || !isDir) continue;
            NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:containerPath error:nil];
            for (NSString *item in items) {
                if (![item.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
                NSString *bundlePath = [containerPath stringByAppendingPathComponent:item];
                NSString *infoPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                NSString *bundleID = ipadec_nonempty_string(info[@"CFBundleIdentifier"]);
                if (bundleID.length == 0 || [seen containsObject:bundleID]) continue;
                NSString *name = ipadec_nonempty_string(info[@"CFBundleDisplayName"])
                    ?: ipadec_nonempty_string(info[@"CFBundleName"])
                    ?: bundleID;
                NSMutableDictionary *entry = ipadec_app_entry(bundleID, name, bundlePath);
                if (entry) {
                    [out addObject:entry];
                    [seen addObject:bundleID];
                }
            }
        }
    }
    return out;
}

NSArray<NSDictionary<NSString *, NSString *> *> *ipadecryptor_installed_apps_with_system_apps(BOOL includeSystemApps)
{
    NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *byBundle = [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, NSString *> *entry in ipadec_apps_from_launchservices(includeSystemApps)) {
        NSString *bundleID = entry[kIPADecryptorKeyBundleID];
        if (bundleID.length > 0) byBundle[bundleID] = entry;
    }
    if (includeSystemApps) {
        NSArray<NSDictionary<NSString *, NSString *> *> *fallbackSystemApps = @[
            @{ kIPADecryptorKeyBundleID: @"com.apple.mobilesafari", kIPADecryptorKeyName: @"Safari", kIPADecryptorKeyBundlePath: @"" },
            @{ kIPADecryptorKeyBundleID: @"com.apple.mobilephone", kIPADecryptorKeyName: @"Phone", kIPADecryptorKeyBundlePath: @"" },
            @{ kIPADecryptorKeyBundleID: @"com.apple.MobileSMS", kIPADecryptorKeyName: @"Messages", kIPADecryptorKeyBundlePath: @"" },
            @{ kIPADecryptorKeyBundleID: @"com.apple.Preferences", kIPADecryptorKeyName: @"Settings", kIPADecryptorKeyBundlePath: @"" },
            @{ kIPADecryptorKeyBundleID: @"com.apple.mobileslideshow", kIPADecryptorKeyName: @"Photos", kIPADecryptorKeyBundlePath: @"" },
            @{ kIPADecryptorKeyBundleID: @"com.apple.camera", kIPADecryptorKeyName: @"Camera", kIPADecryptorKeyBundlePath: @"" },
            @{ kIPADecryptorKeyBundleID: @"com.apple.mobilemail", kIPADecryptorKeyName: @"Mail", kIPADecryptorKeyBundlePath: @"" },
            @{ kIPADecryptorKeyBundleID: @"com.apple.mobilecal", kIPADecryptorKeyName: @"Calendar", kIPADecryptorKeyBundlePath: @"" },
            @{ kIPADecryptorKeyBundleID: @"com.apple.reminders", kIPADecryptorKeyName: @"Reminders", kIPADecryptorKeyBundlePath: @"" },
            @{ kIPADecryptorKeyBundleID: @"com.apple.mobilenotes", kIPADecryptorKeyName: @"Notes", kIPADecryptorKeyBundlePath: @"" },
            @{ kIPADecryptorKeyBundleID: @"com.apple.Maps", kIPADecryptorKeyName: @"Maps", kIPADecryptorKeyBundlePath: @"" },
            @{ kIPADecryptorKeyBundleID: @"com.apple.Music", kIPADecryptorKeyName: @"Music", kIPADecryptorKeyBundlePath: @"" },
        ];
        for (NSDictionary<NSString *, NSString *> *entry in fallbackSystemApps) {
            NSString *bundleID = entry[kIPADecryptorKeyBundleID];
            if (bundleID.length > 0 && !byBundle[bundleID]) byBundle[bundleID] = entry;
        }
    }
    for (NSDictionary<NSString *, NSString *> *entry in ipadec_apps_from_bundle_scan()) {
        NSString *bundleID = entry[kIPADecryptorKeyBundleID];
        if (bundleID.length > 0 && !byBundle[bundleID]) byBundle[bundleID] = entry;
    }

    NSArray *sorted = [byBundle.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *an = a[kIPADecryptorKeyName] ?: a[kIPADecryptorKeyBundleID] ?: @"";
        NSString *bn = b[kIPADecryptorKeyName] ?: b[kIPADecryptorKeyBundleID] ?: @"";
        NSComparisonResult r = [an localizedCaseInsensitiveCompare:bn];
        if (r != NSOrderedSame) return r;
        return [(a[kIPADecryptorKeyBundleID] ?: @"") compare:(b[kIPADecryptorKeyBundleID] ?: @"")];
    }];
    return sorted ?: @[];
}

NSArray<NSDictionary<NSString *, NSString *> *> *ipadecryptor_installed_apps(void)
{
    return ipadecryptor_installed_apps_with_system_apps(NO);
}

// Defined with the dump helpers further below.
static bool ipadec_ensure_sandbox_for_dump(void);

bool ipadecryptor_prepare_for_app_enumeration(void)
{
    // Listing user apps needs either LS path access or a /var scan.
    // KRW alone is not enough — widen sandbox when primitives are live.
    if (!kexploit_krw_ready()) {
        log_user("[IPADEC] prepare_for_app_enumeration: KRW not ready\n");
        return false;
    }
    return ipadec_ensure_sandbox_for_dump();
}

static NSDictionary<NSString *, NSString *> *ipadec_lookup_app(NSString *bundleID)
{
    if (bundleID.length == 0) return nil;
    for (NSDictionary<NSString *, NSString *> *entry in ipadecryptor_installed_apps()) {
        if ([entry[kIPADecryptorKeyBundleID] isEqualToString:bundleID]) return entry;
    }
    return nil;
}

NSString *ipadecryptor_display_name_for_bundle(NSString *bundleID)
{
    NSDictionary *entry = ipadec_lookup_app(bundleID);
    NSString *name = entry[kIPADecryptorKeyName];
    if (name.length > 0 && bundleID.length > 0) {
        return [NSString stringWithFormat:@"%@ (%@)", name, bundleID];
    }
    return bundleID.length > 0 ? bundleID : @"None selected";
}

NSString *ipadecryptor_default_output_directory(void)
{
    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                    NSUserDomainMask,
                                                                    YES);
    NSString *base = docs.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [base stringByAppendingPathComponent:@"DecryptedIPAs"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    return dir;
}

static NSString *ipadec_executable_path_for_bundle(NSString *bundlePath)
{
    if (bundlePath.length == 0) return nil;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *exec = ipadec_nonempty_string(info[@"CFBundleExecutable"]);
    if (exec.length == 0) {
        exec = bundlePath.lastPathComponent.stringByDeletingPathExtension;
    }
    return exec.length > 0 ? [bundlePath stringByAppendingPathComponent:exec] : nil;
}

static BOOL ipadec_macho_info_at_offset(const uint8_t *bytes,
                                        NSUInteger length,
                                        NSUInteger offset,
                                        IPADecryptorMachOInfo *info)
{
    if (!bytes || !info || offset + sizeof(uint32_t) > length) return NO;
    uint32_t magic = 0;
    memcpy(&magic, bytes + offset, sizeof(magic));
    BOOL is64 = (magic == MH_MAGIC_64 || magic == MH_CIGAM_64);
    BOOL is32 = (magic == MH_MAGIC || magic == MH_CIGAM);
    if (!is64 && !is32) return NO;

    BOOL swap = (magic == MH_CIGAM || magic == MH_CIGAM_64);
    uint32_t ncmds = 0;
    uint32_t sizeofcmds = 0;
    NSUInteger cursor = 0;
    if (is64) {
        if (offset + sizeof(struct mach_header_64) > length) return NO;
        struct mach_header_64 header;
        memcpy(&header, bytes + offset, sizeof(header));
        ncmds = swap ? OSSwapInt32(header.ncmds) : header.ncmds;
        sizeofcmds = swap ? OSSwapInt32(header.sizeofcmds) : header.sizeofcmds;
        cursor = offset + sizeof(struct mach_header_64);
    } else {
        if (offset + sizeof(struct mach_header) > length) return NO;
        struct mach_header header;
        memcpy(&header, bytes + offset, sizeof(header));
        ncmds = swap ? OSSwapInt32(header.ncmds) : header.ncmds;
        sizeofcmds = swap ? OSSwapInt32(header.sizeofcmds) : header.sizeofcmds;
        cursor = offset + sizeof(struct mach_header);
    }

    if (cursor + sizeofcmds > length) return NO;
    info->isMachO = true;
    info->archCount++;

    for (uint32_t i = 0; i < ncmds; i++) {
        if (cursor + sizeof(struct load_command) > length) return NO;
        struct load_command lc;
        memcpy(&lc, bytes + cursor, sizeof(lc));
        uint32_t cmd = swap ? OSSwapInt32(lc.cmd) : lc.cmd;
        uint32_t cmdsize = swap ? OSSwapInt32(lc.cmdsize) : lc.cmdsize;
        if (cmdsize < sizeof(struct load_command) || cursor + cmdsize > length) return NO;

        if (cmd == LC_ENCRYPTION_INFO || cmd == LC_ENCRYPTION_INFO_64) {
            if (cursor + sizeof(struct encryption_info_command) <= length) {
                struct encryption_info_command enc;
                memcpy(&enc, bytes + cursor, sizeof(enc));
                uint32_t cryptid = swap ? OSSwapInt32(enc.cryptid) : enc.cryptid;
                uint32_t cryptoff = swap ? OSSwapInt32(enc.cryptoff) : enc.cryptoff;
                uint32_t cryptsize = swap ? OSSwapInt32(enc.cryptsize) : enc.cryptsize;
                info->hasEncryptionInfo = true;
                if (cryptid != 0 || info->cryptsize == 0) {
                    info->cryptid = cryptid;
                    info->cryptoff = cryptoff;
                    info->cryptsize = cryptsize;
                }
            }
        }
        cursor += cmdsize;
    }
    return YES;
}

static IPADecryptorMachOInfo ipadec_macho_info_for_file(NSString *path)
{
    IPADecryptorMachOInfo info = {0};
    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:nil];
    if (data.length < sizeof(uint32_t)) return info;

    const uint8_t *bytes = data.bytes;
    uint32_t magic = 0;
    memcpy(&magic, bytes, sizeof(magic));

    if (magic == FAT_CIGAM || magic == FAT_MAGIC) {
        if (data.length < sizeof(struct fat_header)) return info;
        struct fat_header header;
        memcpy(&header, bytes, sizeof(header));
        BOOL swap = (magic == FAT_CIGAM);
        uint32_t nfat = swap ? OSSwapBigToHostInt32(header.nfat_arch) : header.nfat_arch;
        NSUInteger cursor = sizeof(struct fat_header);
        for (uint32_t i = 0; i < nfat; i++) {
            if (cursor + sizeof(struct fat_arch) > data.length) break;
            struct fat_arch arch;
            memcpy(&arch, bytes + cursor, sizeof(arch));
            uint32_t off = swap ? OSSwapBigToHostInt32(arch.offset) : arch.offset;
            (void)ipadec_macho_info_at_offset(bytes, data.length, off, &info);
            cursor += sizeof(struct fat_arch);
        }
        return info;
    }

    if (magic == FAT_CIGAM_64 || magic == FAT_MAGIC_64) {
        if (data.length < sizeof(struct fat_header)) return info;
        struct fat_header header;
        memcpy(&header, bytes, sizeof(header));
        BOOL swap = (magic == FAT_CIGAM_64);
        uint32_t nfat = swap ? OSSwapBigToHostInt32(header.nfat_arch) : header.nfat_arch;
        NSUInteger cursor = sizeof(struct fat_header);
        for (uint32_t i = 0; i < nfat; i++) {
            if (cursor + sizeof(struct fat_arch_64) > data.length) break;
            struct fat_arch_64 arch;
            memcpy(&arch, bytes + cursor, sizeof(arch));
            uint64_t off = swap ? OSSwapBigToHostInt64(arch.offset) : arch.offset;
            if (off <= NSUIntegerMax) {
                (void)ipadec_macho_info_at_offset(bytes, data.length, (NSUInteger)off, &info);
            }
            cursor += sizeof(struct fat_arch_64);
        }
        return info;
    }

    (void)ipadec_macho_info_at_offset(bytes, data.length, 0, &info);
    return info;
}

static BOOL ipadec_file_exists(NSString *path)
{
    BOOL isDir = NO;
    return path.length > 0 &&
           [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] &&
           !isDir;
}


static NSString *ipadec_macho_summary(IPADecryptorMachOInfo info)
{
    if (!info.isMachO) return @"not a Mach-O";
    if (!info.hasEncryptionInfo) {
        return [NSString stringWithFormat:@"Mach-O (%u arch), no LC_ENCRYPTION_INFO",
                                          info.archCount];
    }
    return [NSString stringWithFormat:@"Mach-O (%u arch), cryptid=%u cryptoff=0x%x cryptsize=0x%x",
                                      info.archCount,
                                      info.cryptid,
                                      info.cryptoff,
                                      info.cryptsize];
}

// MARK: - FairPlay dump (lara decrypt.m → Cyanide KRW)

typedef struct {
    uint32_t cryptid;
    uint32_t cryptoff;
    uint32_t cryptsize;
    uint64_t text_vmaddr;
    uint64_t text_fileoff;
    uint64_t text_filesize;
    uint64_t binary_size;
    bool is_64;
    uint32_t ncmds;
    uint8_t uuid[16];
    bool has_uuid;
} IPADecDumpCtx;

static bool ipadec_ensure_sandbox_for_dump(void)
{
    if (check_sandbox_var_rw() == 0) return true;
    if (patch_sandbox_ext() == 0 && check_sandbox_var_rw() == 0) {
        log_user("[IPADEC] sandbox ok via patch_sandbox_ext\n");
        return true;
    }
    static const char *kDonors[] = {
        "sysdiagnosed", "installd", "nehelper", "mobile_installation_proxy", NULL
    };
    for (int i = 0; kDonors[i]; i++) {
        if (borrow_sandbox_ext(kDonors[i]) == 0 && check_sandbox_var_rw() == 0) {
            log_user("[IPADEC] sandbox ok via borrow_sandbox_ext(%s)\n", kDonors[i]);
            return true;
        }
    }
    log_user("[IPADEC] WARNING: /private/var RW not confirmed; copy may fail on some paths\n");
    return false;
}

static int ipadec_launch_app(const char *bundleID)
{
    if (!bundleID || !bundleID[0]) return -1;
    Class cls = objc_getClass("LSApplicationWorkspace");
    if (!cls) {
        log_user("[IPADEC] LSApplicationWorkspace not found\n");
        return -1;
    }
    id ws = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("defaultWorkspace"));
    if (!ws) {
        log_user("[IPADEC] defaultWorkspace returned nil\n");
        return -1;
    }
    NSString *bid = [[NSString alloc] initWithUTF8String:bundleID];
    BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, sel_registerName("openApplicationWithBundleID:"), bid);
    if (!ok) {
        log_user("[IPADEC] openApplicationWithBundleID failed for %s\n", bundleID);
        return -1;
    }
    return 0;
}

// Normalize paths for comparison (/var vs /private/var).
static NSString *ipadec_normalize_path(NSString *path)
{
    if (path.length == 0) return @"";
    NSString *s = path.stringByStandardizingPath;
    // Prefer not resolving final symlink (exec may be a symlink); only tidy components.
    if ([s hasPrefix:@"/var/"] || [s isEqualToString:@"/var"]) {
        s = [@"/private" stringByAppendingString:s];
    } else if ([s hasPrefix:@"/private/var/"]) {
        // already canonical form used by many tools
    }
    // Also produce a /var form for dual compare in match helper.
    return s;
}

static NSString *ipadec_path_var_form(NSString *path)
{
    NSString *s = ipadec_normalize_path(path);
    if ([s hasPrefix:@"/private/var/"]) {
        return [s substringFromIndex:[@"/private" length]];
    }
    return s;
}

// Optional: userspace path for a pid. Often empty under iOS sandbox for other apps.
static NSString *ipadec_pid_executable_path(pid_t pid)
{
    if (pid <= 0) return nil;
    char buf[PROC_PIDPATHINFO_MAXSIZE];
    memset(buf, 0, sizeof(buf));
    int n = proc_pidpath(pid, buf, sizeof(buf));
    if (n <= 0 || buf[0] == '\0') return nil;
    return [NSString stringWithUTF8String:buf];
}

static BOOL ipadec_exec_paths_match(NSString *expected, NSString *actual)
{
    if (expected.length == 0 || actual.length == 0) return NO;
    NSString *a1 = ipadec_normalize_path(expected);
    NSString *b1 = ipadec_normalize_path(actual);
    if ([a1 isEqualToString:b1]) return YES;
    NSString *a2 = ipadec_path_var_form(expected);
    NSString *b2 = ipadec_path_var_form(actual);
    if ([a2 isEqualToString:b2] || [a1 isEqualToString:b2] || [a2 isEqualToString:b1]) return YES;

    // Match trailing Bundle/Application/<UUID>/<App>.app/<Exec> (3–4 components).
    NSArray<NSString *> *ap = a1.pathComponents;
    NSArray<NSString *> *bp = b1.pathComponents;
    if (ap.count >= 3 && bp.count >= 3) {
        NSUInteger n = MIN(4, MIN(ap.count, bp.count));
        BOOL tailMatch = YES;
        for (NSUInteger i = 0; i < n; i++) {
            if (![ap[ap.count - 1 - i] isEqualToString:bp[bp.count - 1 - i]]) {
                tailMatch = NO;
                break;
            }
        }
        if (tailMatch) return YES;
    }
    return NO;
}

static BOOL ipadec_p_name_matches_exec(const char *p_name, NSString *execName)
{
    if (!p_name || !p_name[0] || execName.length == 0) return NO;
    if (strcmp(p_name, execName.UTF8String) == 0) return YES;
    // lara: truncate at first '.' and retry (some short names).
    NSString *shortName = execName;
    NSRange dot = [execName rangeOfString:@"."];
    if (dot.location != NSNotFound && dot.location > 0) {
        shortName = [execName substringToIndex:dot.location];
        if (strcmp(p_name, shortName.UTF8String) == 0) return YES;
    }
    return NO;
}

// Walk kernel proc list (requires KRW). Returns candidates with matching p_name.
// Prefer path-confirmed hits; fall back to name-only (UUID gate protects dump).
static pid_t ipadec_find_pid_for_exec_path(NSString *execPath)
{
    if (execPath.length == 0) return -1;
    if (!kexploit_krw_ready()) {
        log_user("[IPADEC] KRW not ready for proc walk\n");
        return -1;
    }

    NSString *execName = execPath.lastPathComponent;
    if (execName.length == 0) return -1;

    __block pid_t pathMatched = -1;
    __block pid_t nameOnly = -1;
    __block int nameHits = 0;
    __block int pathRejected = 0;

    void (^consider)(uint64_t) = ^(uint64_t proc) {
        if (pathMatched > 0) return;
        if (!is_kaddr_valid(proc)) return;
        char *p_name = proc_get_p_name(proc);
        if (!ipadec_p_name_matches_exec(p_name, execName)) return;

        pid_t pid = (pid_t)kread32(proc + off_proc_p_pid);
        if (pid <= 0) return;

        NSString *livePath = ipadec_pid_executable_path(pid);
        if (livePath.length > 0) {
            if (ipadec_exec_paths_match(execPath, livePath)) {
                pathMatched = pid;
                log_user("[IPADEC] pid %d path-confirmed: %s\n",
                         (int)pid, livePath.UTF8String);
            } else {
                pathRejected++;
                log_user("[IPADEC] pid %d name=%s path-mismatch want=%s got=%s\n",
                         (int)pid, p_name,
                         execPath.UTF8String ?: "(nil)",
                         livePath.UTF8String);
            }
            return;
        }

        // proc_pidpath often empty for other apps on iOS — keep as name candidate.
        nameHits++;
        if (nameOnly <= 0) nameOnly = pid;
        log_user("[IPADEC] pid %d name-only candidate (no proc_pidpath): %s\n",
                 (int)pid, p_name);
    };

    // Walk forward + backward from self (same pattern as proc_find_by_name).
    uint64_t proc = proc_self();
    for (int i = 0; i < 4096 && is_kaddr_valid(proc); i++) {
        consider(proc);
        if (pathMatched > 0) break;
        uint64_t next = kread64(proc + off_proc_p_list_le_next);
        if (!is_kaddr_valid(next) || next == proc) break;
        proc = next;
    }
    if (pathMatched <= 0) {
        proc = proc_self();
        for (int i = 0; i < 4096 && is_kaddr_valid(proc); i++) {
            consider(proc);
            if (pathMatched > 0) break;
            uint64_t prev = kread64(proc + off_proc_p_list_le_prev);
            if (!is_kaddr_valid(prev) || prev == proc) break;
            proc = prev;
        }
    }

    if (pathMatched > 0) return pathMatched;

    if (nameOnly > 0) {
        // Safe enough with LC_UUID image gate: wrong same-name process fails dump.
        log_user("[IPADEC] using name-only pid %d for %s (path unavailable; UUID gate will verify image) nameHits=%d pathRejected=%d\n",
                 (int)nameOnly, execName.UTF8String, nameHits, pathRejected);
        return nameOnly;
    }

    // Last resort: userspace list + path (rarely works for other apps).
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes > 0) {
        pid_t *pids = (pid_t *)calloc(1, (size_t)bytes);
        if (pids) {
            int got = proc_listpids(PROC_ALL_PIDS, 0, pids, bytes);
            int count = got > 0 ? (got / (int)sizeof(pid_t)) : 0;
            for (int i = 0; i < count; i++) {
                pid_t pid = pids[i];
                if (pid <= 0) continue;
                NSString *path = ipadec_pid_executable_path(pid);
                if (path.length == 0) continue;
                if (ipadec_exec_paths_match(execPath, path)) {
                    free(pids);
                    log_user("[IPADEC] matched pid %d via proc_listpids path=%s\n",
                             (int)pid, path.UTF8String);
                    return pid;
                }
            }
            free(pids);
        }
    }

    log_user("[IPADEC] no live process for exec %s (path=%s)\n",
             execName.UTF8String, execPath.UTF8String ?: "(nil)");
    return -1;
}

static pid_t ipadec_ensure_target_running(NSString *bundleID, NSString *execPath)
{
    pid_t pid = ipadec_find_pid_for_exec_path(execPath);
    if (pid > 0) return pid;

    log_user("[IPADEC] process not running for %s; launching %s\n",
             execPath.lastPathComponent.UTF8String ?: "(nil)",
             bundleID.UTF8String);
    if (ipadec_launch_app(bundleID.UTF8String) != 0) {
        return -1;
    }

    // Give the target time to map its main image, then try to return to Cyanide
    // (same timing pattern as lara DecryptView).
    usleep(2500 * 1000);
    NSString *selfBID = NSBundle.mainBundle.bundleIdentifier;
    if (selfBID.length > 0) {
        (void)ipadec_launch_app(selfBID.UTF8String);
        usleep(500 * 1000);
    }

    for (int attempt = 0; attempt < 30; attempt++) {
        pid = ipadec_find_pid_for_exec_path(execPath);
        if (pid > 0) return pid;
        usleep(250 * 1000);
    }
    return -1;
}

static int ipadec_read_file(const char *path, uint8_t **out, uint64_t *out_size)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    off_t fsz = lseek(fd, 0, SEEK_END);
    if (fsz <= 0) {
        close(fd);
        return -1;
    }
    lseek(fd, 0, SEEK_SET);
    uint8_t *buf = (uint8_t *)malloc((size_t)fsz);
    if (!buf) {
        close(fd);
        return -1;
    }
    ssize_t n = read(fd, buf, (size_t)fsz);
    close(fd);
    if (n != fsz) {
        free(buf);
        return -1;
    }
    *out = buf;
    *out_size = (uint64_t)fsz;
    return 0;
}

static int ipadec_write_file(const char *path, const uint8_t *data, uint64_t size)
{
    // Preserve existing mode when overwriting (copy already set +x on binaries).
    mode_t mode = 0644;
    struct stat st;
    BOOL had = (path && stat(path, &st) == 0);
    if (had) mode = st.st_mode & 07777;

    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode ? mode : 0644);
    if (fd < 0) {
        log_user("[IPADEC] open for write failed: %s\n", path);
        return -1;
    }
    if (had) {
        (void)fchmod(fd, mode);
    }
    ssize_t n = write(fd, data, (size_t)size);
    close(fd);
    if (n != (ssize_t)size) {
        log_user("[IPADEC] write failed: %s\n", path);
        return -1;
    }
    return 0;
}

static int ipadec_parse_macho_dump(uint8_t *buf, uint64_t size, IPADecDumpCtx *ctx)
{
    memset(ctx, 0, sizeof(*ctx));
    if (!buf || size < 4) return -1;
    uint32_t magic = *(uint32_t *)buf;

    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        if (size < sizeof(struct fat_header)) return -1;
        struct fat_header *fh = (struct fat_header *)buf;
        uint32_t narch = OSSwapBigToHostInt32(fh->nfat_arch);
        if (narch == 0 || narch > 64) return -1;
        uint64_t archs_bytes = (uint64_t)narch * sizeof(struct fat_arch);
        if (sizeof(struct fat_header) + archs_bytes > size) return -1;
        struct fat_arch *archs = (struct fat_arch *)(buf + sizeof(struct fat_header));
        for (uint32_t i = 0; i < narch; i++) {
            if (OSSwapBigToHostInt32(archs[i].cputype) == CPU_TYPE_ARM64) {
                uint32_t offset = OSSwapBigToHostInt32(archs[i].offset);
                uint32_t arch_size = OSSwapBigToHostInt32(archs[i].size);
                if (arch_size == 0) continue;
                if ((uint64_t)offset + arch_size > size) continue;
                return ipadec_parse_macho_dump(buf + offset, arch_size, ctx);
            }
        }
        return -1;
    }

    if (magic != MH_MAGIC_64 && magic != MH_MAGIC) return -1;

    ctx->is_64 = (magic == MH_MAGIC_64);
    uint64_t header_size = ctx->is_64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
    if (size < header_size) return -1;

    struct mach_header_64 *header64 = (struct mach_header_64 *)buf;
    struct mach_header *header32 = (struct mach_header *)buf;
    ctx->ncmds = ctx->is_64 ? header64->ncmds : header32->ncmds;
    uint32_t sizeofcmds = ctx->is_64 ? header64->sizeofcmds : header32->sizeofcmds;
    if (ctx->ncmds == 0 || ctx->ncmds > 0x10000) return -1;
    if (header_size + (uint64_t)sizeofcmds > size) return -1;

    uint64_t off = header_size;
    uint64_t cmds_end = header_size + sizeofcmds;
    bool found_encryption = false;
    bool found_text = false;

    for (uint32_t i = 0; i < ctx->ncmds; i++) {
        if (off + sizeof(struct load_command) > cmds_end ||
            off + sizeof(struct load_command) > size) {
            return -1;
        }
        struct load_command *lc = (struct load_command *)(buf + off);
        uint32_t cmd = lc->cmd;
        uint32_t cmdsize = lc->cmdsize;
        // Load commands must be 4/8-byte aligned and large enough for the header.
        if (cmdsize < sizeof(struct load_command) || (cmdsize & 3u) != 0) return -1;
        if (off + cmdsize > cmds_end || off + cmdsize > size) return -1;

        if (cmd == LC_ENCRYPTION_INFO_64 && ctx->is_64) {
            if (cmdsize < sizeof(struct encryption_info_command_64)) return -1;
            struct encryption_info_command_64 *eic = (struct encryption_info_command_64 *)lc;
            ctx->cryptid = eic->cryptid;
            ctx->cryptoff = eic->cryptoff;
            ctx->cryptsize = eic->cryptsize;
            found_encryption = true;
        } else if (cmd == LC_ENCRYPTION_INFO && !ctx->is_64) {
            if (cmdsize < sizeof(struct encryption_info_command)) return -1;
            struct encryption_info_command *eic = (struct encryption_info_command *)lc;
            ctx->cryptid = eic->cryptid;
            ctx->cryptoff = eic->cryptoff;
            ctx->cryptsize = eic->cryptsize;
            found_encryption = true;
        } else if (cmd == LC_SEGMENT_64 && ctx->is_64) {
            if (cmdsize < sizeof(struct segment_command_64)) return -1;
            struct segment_command_64 *seg = (struct segment_command_64 *)lc;
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                ctx->text_vmaddr = seg->vmaddr;
                ctx->text_fileoff = seg->fileoff;
                ctx->text_filesize = seg->filesize;
                found_text = true;
            }
        } else if (cmd == LC_SEGMENT && !ctx->is_64) {
            if (cmdsize < sizeof(struct segment_command)) return -1;
            struct segment_command *seg = (struct segment_command *)lc;
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                ctx->text_vmaddr = seg->vmaddr;
                ctx->text_fileoff = seg->fileoff;
                ctx->text_filesize = seg->filesize;
                found_text = true;
            }
        } else if (cmd == LC_UUID) {
            if (cmdsize < sizeof(struct uuid_command)) return -1;
            struct uuid_command *uc = (struct uuid_command *)lc;
            memcpy(ctx->uuid, uc->uuid, 16);
            ctx->has_uuid = true;
        }
        off += cmdsize;
    }

    if (!found_encryption || !found_text) return -1;
    // crypt range must sit inside the image we will rewrite.
    if ((uint64_t)ctx->cryptoff + (uint64_t)ctx->cryptsize > size) return -1;
    ctx->binary_size = size;
    return 0;
}

// Parse LC_UUID from an in-memory Mach-O (or arm64 slice of a FAT) header buffer.
static int ipadec_extract_uuid_from_buffer(const uint8_t *buf, size_t size, uint8_t uuid_out[16])
{
    if (!buf || size < 4 || !uuid_out) return -1;
    uint32_t magic = 0;
    memcpy(&magic, buf, sizeof(magic));

    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        if (size < sizeof(struct fat_header)) return -1;
        struct fat_header fh;
        memcpy(&fh, buf, sizeof(fh));
        uint32_t narch = OSSwapBigToHostInt32(fh.nfat_arch);
        if (narch == 0 || narch > 64) return -1;
        uint64_t archs_bytes = (uint64_t)narch * sizeof(struct fat_arch);
        if (sizeof(struct fat_header) + archs_bytes > size) return -1;
        const struct fat_arch *archs =
            (const struct fat_arch *)(buf + sizeof(struct fat_header));
        for (uint32_t i = 0; i < narch; i++) {
            if (OSSwapBigToHostInt32(archs[i].cputype) != CPU_TYPE_ARM64) continue;
            uint32_t offset = OSSwapBigToHostInt32(archs[i].offset);
            uint32_t arch_size = OSSwapBigToHostInt32(archs[i].size);
            if (arch_size == 0 || (uint64_t)offset + arch_size > size) continue;
            return ipadec_extract_uuid_from_buffer(buf + offset, arch_size, uuid_out);
        }
        return -1;
    }

    if (magic != MH_MAGIC_64 && magic != MH_MAGIC) return -1;
    bool is64 = (magic == MH_MAGIC_64);
    size_t header_size = is64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
    if (size < header_size) return -1;

    uint32_t ncmds = 0;
    uint32_t sizeofcmds = 0;
    if (is64) {
        struct mach_header_64 mh;
        memcpy(&mh, buf, sizeof(mh));
        ncmds = mh.ncmds;
        sizeofcmds = mh.sizeofcmds;
    } else {
        struct mach_header mh;
        memcpy(&mh, buf, sizeof(mh));
        ncmds = mh.ncmds;
        sizeofcmds = mh.sizeofcmds;
    }
    if (ncmds == 0 || ncmds > 0x10000) return -1;
    if (header_size + (size_t)sizeofcmds > size) return -1;

    size_t off = header_size;
    size_t cmds_end = header_size + sizeofcmds;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (off + sizeof(struct load_command) > cmds_end) return -1;
        struct load_command lc;
        memcpy(&lc, buf + off, sizeof(lc));
        if (lc.cmdsize < sizeof(struct load_command) || (lc.cmdsize & 3u) != 0) return -1;
        if (off + lc.cmdsize > cmds_end) return -1;
        if (lc.cmd == LC_UUID) {
            if (lc.cmdsize < sizeof(struct uuid_command)) return -1;
            struct uuid_command uc;
            memcpy(&uc, buf + off, sizeof(uc));
            memcpy(uuid_out, uc.uuid, 16);
            return 0;
        }
        off += lc.cmdsize;
    }
    return -1;
}

// Map enough pages from a candidate image base to parse its LC_UUID.
static int ipadec_read_uuid_from_vm_image(uint64_t vmMap, uint64_t base, uint8_t uuid_out[16])
{
    if (base == 0 || base >= 0xffffff8000000000ULL) return -1;

    // Peek first page for header + sizeofcmds.
    uint64_t page0 = base & ~((uint64_t)PAGE_SIZE - 1);
    uint64_t page_off = base - page0;
    struct VMShmem sh0 = vm_map_remote_page(vmMap, page0);
    if (!sh0.used) return -1;

    const uint8_t *p0 = (const uint8_t *)(uintptr_t)sh0.localAddress;
    if (page_off + 4 > PAGE_SIZE) {
        mach_vm_deallocate(mach_task_self_, sh0.localAddress, PAGE_SIZE);
        return -1;
    }

    uint32_t magic = 0;
    memcpy(&magic, p0 + page_off, sizeof(magic));
    if (magic != MH_MAGIC_64 && magic != MH_MAGIC &&
        magic != FAT_MAGIC && magic != FAT_CIGAM) {
        mach_vm_deallocate(mach_task_self_, sh0.localAddress, PAGE_SIZE);
        return -1;
    }

    size_t need = PAGE_SIZE; // at least one page from base
    if (magic == MH_MAGIC_64 || magic == MH_MAGIC) {
        bool is64 = (magic == MH_MAGIC_64);
        size_t header_size = is64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
        if (page_off + header_size <= PAGE_SIZE) {
            uint32_t sizeofcmds = 0;
            if (is64) {
                struct mach_header_64 mh;
                memcpy(&mh, p0 + page_off, sizeof(mh));
                sizeofcmds = mh.sizeofcmds;
            } else {
                struct mach_header mh;
                memcpy(&mh, p0 + page_off, sizeof(mh));
                sizeofcmds = mh.sizeofcmds;
            }
            size_t header_and_cmds = header_size + (size_t)sizeofcmds;
            // Cap: refuse absurd load-command blobs.
            if (header_and_cmds > 256 * 1024) {
                mach_vm_deallocate(mach_task_self_, sh0.localAddress, PAGE_SIZE);
                return -1;
            }
            need = header_and_cmds;
        }
    } else {
        // FAT: need fat header + arch table + first arm64 slice header region.
        // Read up to 64KiB from base — enough for fat + slice start in practice.
        need = 64 * 1024;
    }

    uint8_t *buf = (uint8_t *)calloc(1, need);
    if (!buf) {
        mach_vm_deallocate(mach_task_self_, sh0.localAddress, PAGE_SIZE);
        return -1;
    }

    // Copy from first mapped page.
    size_t first_cpy = PAGE_SIZE - (size_t)page_off;
    if (first_cpy > need) first_cpy = need;
    memcpy(buf, p0 + page_off, first_cpy);
    mach_vm_deallocate(mach_task_self_, sh0.localAddress, PAGE_SIZE);

    size_t filled = first_cpy;
    while (filled < need) {
        uint64_t addr = base + filled;
        uint64_t pg = addr & ~((uint64_t)PAGE_SIZE - 1);
        uint64_t off_in_pg = addr - pg;
        struct VMShmem sh = vm_map_remote_page(vmMap, pg);
        if (!sh.used) {
            free(buf);
            return -1;
        }
        size_t cpy = PAGE_SIZE - (size_t)off_in_pg;
        if (cpy > need - filled) cpy = need - filled;
        memcpy(buf + filled, (const void *)(uintptr_t)(sh.localAddress + off_in_pg), cpy);
        mach_vm_deallocate(mach_task_self_, sh.localAddress, PAGE_SIZE);
        filled += cpy;
    }

    int ret = ipadec_extract_uuid_from_buffer(buf, need, uuid_out);
    free(buf);
    return ret;
}

static BOOL ipadec_uuid_equal(const uint8_t a[16], const uint8_t b[16])
{
    return a && b && memcmp(a, b, 16) == 0;
}

static void ipadec_log_uuid(const char *label, const uint8_t uuid[16])
{
    if (!uuid) {
        log_user("[IPADEC] %s: (nil)\n", label ?: "uuid");
        return;
    }
    log_user("[IPADEC] %s: %02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x\n",
             label ?: "uuid",
             uuid[0], uuid[1], uuid[2], uuid[3],
             uuid[4], uuid[5], uuid[6], uuid[7],
             uuid[8], uuid[9], uuid[10], uuid[11],
             uuid[12], uuid[13], uuid[14], uuid[15]);
}

// Locate the mapped image whose LC_UUID matches the on-disk main binary.
// Prefer fileoff alias heuristic as a filter, but NEVER accept a candidate
// without UUID equality. No "first Mach-O wins" fallback.
static int ipadec_find_text_segment_in_vm_map(uint64_t vmMap,
                                             uint64_t fileoff,
                                             const uint8_t expected_uuid[16],
                                             bool has_uuid,
                                             uint64_t *out_addr)
{
    if (!out_addr || !has_uuid || !expected_uuid) return -1;
    *out_addr = 0;

    __block uint64_t found_addr = 0;
    __block BOOL done = NO;

    // Pass 1: fileoff-hint candidates (same heuristic as before, UUID-gated).
    // Address filter: only skip null / kernel map; UUID is the real gate.
    vm_map_iterate_entries(vmMap, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
        (void)end;
        if (done) return;
        if (start == 0 || start >= 0xffffff8000000000ULL) return;

        uint64_t alias_offset = kread64(entry + off_vm_map_entry_vme_alias);
        if ((alias_offset >> 12) != (fileoff >> 14)) return;

        uint8_t live_uuid[16];
        if (ipadec_read_uuid_from_vm_image(vmMap, start, live_uuid) != 0) return;
        if (!ipadec_uuid_equal(expected_uuid, live_uuid)) return;

        found_addr = start;
        done = YES;
        *stop = YES;
    });

    // Pass 2: any user Mach-O mapping with matching UUID (no fileoff filter).
    if (found_addr == 0) {
        vm_map_iterate_entries(vmMap, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
            (void)end;
            (void)entry;
            if (done) return;
            if (start == 0 || start >= 0xffffff8000000000ULL) return;

            uint8_t live_uuid[16];
            if (ipadec_read_uuid_from_vm_image(vmMap, start, live_uuid) != 0) return;
            if (!ipadec_uuid_equal(expected_uuid, live_uuid)) return;

            found_addr = start;
            done = YES;
            *stop = YES;
        });
    }

    if (found_addr == 0) {
        log_user("[IPADEC] no VM image with matching LC_UUID\n");
        return -1;
    }

    *out_addr = found_addr;
    return 0;
}

static int ipadec_decrypt_to_output(pid_t pid,
                                    uint8_t *file_buf,
                                    uint64_t file_size,
                                    IPADecDumpCtx *ctx,
                                    const char *outputPath)
{
    uint64_t proc = proc_find(pid);
    if (proc == 0) {
        log_user("[IPADEC] process pid %d not found\n", (int)pid);
        return -1;
    }

    uint64_t task = proc_task(proc);
    if (task == 0) {
        log_user("[IPADEC] failed to get task for pid %d\n", (int)pid);
        return -1;
    }

    uint64_t vmMap = task_get_vm_map(task);
    if (vmMap == 0) {
        log_user("[IPADEC] failed to get vm_map for pid %d\n", (int)pid);
        return -1;
    }

    if (!ctx->has_uuid) {
        log_user("[IPADEC] disk image has no LC_UUID; refuse ambiguous VM match\n");
        return -1;
    }
    ipadec_log_uuid("disk LC_UUID", ctx->uuid);

    uint64_t text_addr = 0;
    if (ipadec_find_text_segment_in_vm_map(vmMap, ctx->text_fileoff,
                                           ctx->uuid, ctx->has_uuid,
                                           &text_addr) != 0) {
        log_user("[IPADEC] failed to find UUID-matched main image in process memory\n");
        return -1;
    }
    log_user("[IPADEC] text base in target (UUID-matched): 0x%llx\n", text_addr);

    uint8_t *decrypted = (uint8_t *)malloc((size_t)file_size);
    if (!decrypted) {
        log_user("[IPADEC] malloc failed for decrypted buffer\n");
        return -1;
    }
    memcpy(decrypted, file_buf, (size_t)file_size);

    uint64_t segment_fileoff = ctx->text_fileoff;
    uint32_t page_size = (uint32_t)PAGE_SIZE;
    uint32_t start_page = ctx->cryptoff / page_size;
    uint32_t end_page = (ctx->cryptoff + ctx->cryptsize + page_size - 1) / page_size;
    uint32_t total_pages = end_page > start_page ? (end_page - start_page) : 1;
    uint32_t pages_done = 0;
    uint32_t pages_ok = 0;

    for (uint32_t pg = start_page; pg < end_page; pg++) {
        uint64_t pg_file_start = (uint64_t)pg * page_size;
        uint64_t pg_virt = text_addr + pg_file_start - segment_fileoff;

        struct VMShmem shmem = vm_map_remote_page(vmMap, pg_virt);
        if (!shmem.used) {
            shmem = vm_map_remote_page(vmMap, pg_virt & ~(uint64_t)(page_size - 1));
            if (!shmem.used) {
                pages_done++;
                log_user("[IPADEC] crypt page map miss pg=%u virt=0x%llx fileoff=0x%llx\n",
                         pg, pg_virt, pg_file_start);
                continue;
            }
        }

        uint64_t copy_off = pg_file_start;
        uint32_t copy_size = page_size;
        if (copy_off + copy_size > file_size)
            copy_size = (uint32_t)(file_size - copy_off);

        memcpy(decrypted + copy_off, (void *)(uintptr_t)shmem.localAddress, copy_size);
        mach_vm_deallocate(mach_task_self_, shmem.localAddress, PAGE_SIZE);
        pages_ok++;
        pages_done++;
        if ((pages_done % 64) == 0 || pages_done == total_pages) {
            log_user("[IPADEC] dump progress %u/%u pages (ok=%u)\n",
                     pages_done, total_pages, pages_ok);
        }
    }

    // Integrity gate: partial crypt dumps must not be labeled decrypted.
    // Keep a .partial debug image (cryptid still set) for inspection.
    if (pages_ok != total_pages) {
        NSString *partialPath = [[NSString stringWithUTF8String:outputPath ?: ""]
                                 stringByAppendingString:@".partial"];
        if (partialPath.length > 0) {
            (void)ipadec_write_file(partialPath.UTF8String, decrypted, file_size);
            log_user("[IPADEC] incomplete crypt dump: %u/%u pages ok; debug copy: %s (cryptid left set)\n",
                     pages_ok, total_pages, partialPath.UTF8String);
        } else {
            log_user("[IPADEC] incomplete crypt dump: %u/%u pages ok (cryptid left set)\n",
                     pages_ok, total_pages);
        }
        free(decrypted);
        return -1;
    }

    uint64_t crypto_off = ctx->is_64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
    bool cleared = false;
    for (uint32_t i = 0; i < ctx->ncmds; i++) {
        if (crypto_off + sizeof(struct load_command) > file_size) break;
        struct load_command *lc = (struct load_command *)(decrypted + crypto_off);
        uint32_t cmdsize = lc->cmdsize;
        if (cmdsize < sizeof(struct load_command) || (cmdsize & 3u) != 0) break;
        if (crypto_off + cmdsize > file_size) break;
        if (lc->cmd == LC_ENCRYPTION_INFO_64 && ctx->is_64) {
            if (cmdsize < sizeof(struct encryption_info_command_64)) break;
            ((struct encryption_info_command_64 *)lc)->cryptid = 0;
            cleared = true;
            break;
        } else if (lc->cmd == LC_ENCRYPTION_INFO && !ctx->is_64) {
            if (cmdsize < sizeof(struct encryption_info_command)) break;
            ((struct encryption_info_command *)lc)->cryptid = 0;
            cleared = true;
            break;
        }
        crypto_off += cmdsize;
    }
    if (!cleared) {
        free(decrypted);
        log_user("[IPADEC] failed to clear cryptid after full dump\n");
        return -1;
    }

    if (ipadec_write_file(outputPath, decrypted, file_size) != 0) {
        free(decrypted);
        return -1;
    }

    free(decrypted);
    log_user("[IPADEC] wrote decrypted binary (%u/%u pages) -> %s\n",
             pages_ok, total_pages, outputPath);
    return 0;
}

static int ipadec_decrypt_binary_pid(const char *binaryPath, pid_t process_pid, const char *outputPath)
{
    if (!kexploit_krw_ready()) {
        log_user("[IPADEC] KRW not ready\n");
        return -1;
    }

    uint8_t *file_buf = NULL;
    uint64_t file_size = 0;

    // Disk image is required: LC_UUID must come from a known file, never from
    // an arbitrary first Mach-O found in the process VM.
    if (ipadec_read_file(binaryPath, &file_buf, &file_size) != 0) {
        log_user("[IPADEC] cannot read binary from disk (refuse UUID-less VM dump): %s\n",
                 binaryPath);
        return -1;
    }

    IPADecDumpCtx ctx;
    if (ipadec_parse_macho_dump(file_buf, file_size, &ctx) != 0) {
        free(file_buf);
        log_user("[IPADEC] failed to parse mach-o: %s\n", binaryPath);
        return -1;
    }
    if (ctx.cryptid == 0) {
        log_user("[IPADEC] binary not encrypted (cryptid=0): %s\n", binaryPath);
        int copyRet = 0;
        if (strcmp(binaryPath, outputPath) != 0) {
            copyRet = ipadec_write_file(outputPath, file_buf, file_size);
        }
        free(file_buf);
        return copyRet;
    }
    if (!ctx.has_uuid) {
        free(file_buf);
        log_user("[IPADEC] disk image has no LC_UUID; refuse dump: %s\n", binaryPath);
        return -1;
    }

    int ret = ipadec_decrypt_to_output(process_pid, file_buf, file_size, &ctx, outputPath);
    free(file_buf);
    return ret;
}

static int ipadec_is_encrypted_path(const char *binaryPath)
{
    uint8_t *buf = NULL;
    uint64_t size = 0;
    if (ipadec_read_file(binaryPath, &buf, &size) != 0) return -1;
    IPADecDumpCtx ctx;
    int ret = ipadec_parse_macho_dump(buf, size, &ctx);
    free(buf);
    if (ret != 0) return -1;
    return ctx.cryptid != 0 ? 1 : 0;
}

// MARK: - Bundle copy + store-only ZIP IPA writer

// Fail-closed recursive copy that preserves file modes (needed for +x on
// CFBundleExecutable / framework binaries). Uses copyfile(3), not NSData 0644.
static BOOL ipadec_copy_item(NSString *src, NSString *dst, NSError **error)
{
    if (src.length == 0 || dst.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"IPADecryptor"
                                         code:10
                                     userInfo:@{ NSLocalizedDescriptionKey: @"Empty copy path" }];
        }
        return NO;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:src isDirectory:&isDir]) {
        if (error) {
            *error = [NSError errorWithDomain:@"IPADecryptor"
                                         code:11
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"Source missing: %@", src] }];
        }
        return NO;
    }

    // Ensure parent of destination exists for both files and top-level dirs.
    NSString *parent = dst.stringByDeletingLastPathComponent;
    if (parent.length > 0 && ![fm fileExistsAtPath:parent]) {
        NSError *mkErr = nil;
        if (![fm createDirectoryAtPath:parent
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:&mkErr]) {
            if (error) *error = mkErr;
            return NO;
        }
    }

    // Remove stale destination so copyfile does not merge partially.
    [fm removeItemAtPath:dst error:nil];

    copyfile_flags_t flags = COPYFILE_ALL | COPYFILE_NOFOLLOW_SRC;
    if (isDir) flags |= COPYFILE_RECURSIVE;

    if (copyfile(src.fileSystemRepresentation, dst.fileSystemRepresentation, NULL, flags) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"copyfile failed for %@: %s",
                                          src.lastPathComponent, strerror(errno)] }];
        }
        return NO;
    }

    // Verify destination landed.
    if (![fm fileExistsAtPath:dst isDirectory:&isDir]) {
        if (error) {
            *error = [NSError errorWithDomain:@"IPADecryptor"
                                         code:12
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"Copy produced no destination: %@", dst] }];
        }
        return NO;
    }
    return YES;
}

// Unix mode → ZIP "external file attributes" (host = Unix: mode in high 16 bits).
// Uses lstat so symlink entries keep S_IFLNK, not the target type.
static uint32_t ipadec_zip_external_attrs_from_lstat(const struct stat *st, BOOL isDirFallback)
{
    mode_t mode = isDirFallback ? (S_IFDIR | 0755) : (S_IFREG | 0644);
    if (st) mode = st->st_mode;
    return ((uint32_t)(mode & 0xFFFF)) << 16;
}

static BOOL ipadec_readlink_target(NSString *path, NSData **targetOut, NSError **error)
{
    const char *cpath = path.fileSystemRepresentation;
    struct stat st;
    if (lstat(cpath, &st) != 0 || !S_ISLNK(st.st_mode)) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"readlink lstat failed: %@", path] }];
        }
        return NO;
    }

    // st_size is the link target length on Darwin; +1 room detects truncation.
    size_t alloc = (st.st_size > 0) ? ((size_t)st.st_size + 1) : ((size_t)PATH_MAX + 1);
    if (alloc > 1u << 20) { // refuse absurd targets
        if (error) {
            *error = [NSError errorWithDomain:@"IPADecryptor"
                                         code:14
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"symlink target too large: %@", path] }];
        }
        return NO;
    }

    char *buf = (char *)malloc(alloc);
    if (!buf) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:ENOMEM
                                     userInfo:@{ NSLocalizedDescriptionKey: @"readlink malloc failed" }];
        }
        return NO;
    }

    ssize_t n = readlink(cpath, buf, alloc);
    if (n < 0) {
        free(buf);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"readlink failed: %@", path] }];
        }
        return NO;
    }
    // If the buffer filled completely, target may be truncated — fail closed.
    if ((size_t)n >= alloc) {
        free(buf);
        if (error) {
            *error = [NSError errorWithDomain:@"IPADecryptor"
                                         code:14
                                     userInfo:@{ NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"symlink target truncated: %@", path] }];
        }
        return NO;
    }

    if (targetOut) *targetOut = [NSData dataWithBytes:buf length:(NSUInteger)n];
    free(buf);
    return YES;
}

static void ipadec_set_zip_error(NSError **error, NSInteger code, NSString *message)
{
    if (!error) return;
    *error = [NSError errorWithDomain:@"IPADecryptor"
                                 code:code
                             userInfo:@{ NSLocalizedDescriptionKey: message ?: @"ZIP error" }];
}

static void ipadec_write_le16(NSMutableData *d, uint16_t v)
{
    uint8_t b[2] = { (uint8_t)(v & 0xff), (uint8_t)((v >> 8) & 0xff) };
    [d appendBytes:b length:2];
}

static void ipadec_write_le32(NSMutableData *d, uint32_t v)
{
    uint8_t b[4] = {
        (uint8_t)(v & 0xff),
        (uint8_t)((v >> 8) & 0xff),
        (uint8_t)((v >> 16) & 0xff),
        (uint8_t)((v >> 24) & 0xff)
    };
    [d appendBytes:b length:4];
}

// Stream CRC32 for a file without loading it fully into memory.
static BOOL ipadec_crc32_and_size_of_file(NSString *path, uint32_t *crcOut, uint64_t *sizeOut)
{
    FILE *fp = fopen(path.fileSystemRepresentation, "rb");
    if (!fp) return NO;
    uLong crc = crc32(0L, Z_NULL, 0);
    uint64_t total = 0;
    uint8_t buf[256 * 1024];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) {
        crc = crc32(crc, buf, (uInt)n);
        total += n;
    }
    int err = ferror(fp);
    fclose(fp);
    if (err) return NO;
    if (crcOut) *crcOut = (uint32_t)crc;
    if (sizeOut) *sizeOut = total;
    return YES;
}

// Stream-copy regular file body (O_RDONLY | O_NOFOLLOW when available).
static BOOL ipadec_stream_copy_file_to_handle(NSString *path, NSFileHandle *fh, uint64_t expectedSize)
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) {
        // Fallback without NOFOLLOW for platforms/paths that reject it.
        fd = open(path.fileSystemRepresentation, O_RDONLY);
    }
    if (fd < 0) return NO;
    uint64_t total = 0;
    uint8_t buf[256 * 1024];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        @autoreleasepool {
            [fh writeData:[NSData dataWithBytes:buf length:(NSUInteger)n]];
        }
        total += (uint64_t)n;
    }
    int err = (n < 0) ? errno : 0;
    close(fd);
    if (err) return NO;
    return total == expectedSize;
}

typedef NS_ENUM(NSInteger, IPAZipEntryKind) {
    IPAZipEntryFile = 0,
    IPAZipEntryDir,
    IPAZipEntrySymlink,
};

// Store-only classic ZIP: stream per entry; fail-closed; write to .tmp then atomic rename.
// Symlinks are stored as Unix symlink entries (payload = link target), not followed.
static BOOL ipadec_create_zip_from_directory(NSString *sourceDir, NSString *ipaPath, NSError **error)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    // Do not resolve the workdir root through final symlink hops for enumeration base;
    // children are joined onto this path and classified with lstat.
    NSString *root = sourceDir.stringByStandardizingPath;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    if (!en) {
        ipadec_set_zip_error(error, 1, @"Cannot enumerate work directory");
        return NO;
    }

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];

    for (NSString *rel in en) {
        NSString *full = [root stringByAppendingPathComponent:rel];
        struct stat st;
        if (lstat(full.fileSystemRepresentation, &st) != 0) {
            ipadec_set_zip_error(error, 6,
                [NSString stringWithFormat:@"ZIP lstat failed: %@", rel]);
            return NO;
        }
        if (S_ISLNK(st.st_mode)) {
            [entries addObject:@{ @"rel": rel, @"kind": @(IPAZipEntrySymlink) }];
        } else if (S_ISDIR(st.st_mode)) {
            [entries addObject:@{ @"rel": rel, @"kind": @(IPAZipEntryDir) }];
        } else if (S_ISREG(st.st_mode)) {
            [entries addObject:@{ @"rel": rel, @"kind": @(IPAZipEntryFile) }];
        } else {
            ipadec_set_zip_error(error, 13,
                [NSString stringWithFormat:@"ZIP unsupported file type: %@", rel]);
            return NO;
        }
    }

    NSUInteger totalPlanned = entries.count;
    if (totalPlanned == 0) {
        ipadec_set_zip_error(error, 5, @"ZIP had zero entries");
        return NO;
    }
    if (totalPlanned > UINT16_MAX) {
        ipadec_set_zip_error(error, 7,
            [NSString stringWithFormat:
                @"ZIP entry count %lu exceeds classic ZIP limit 65535",
                (unsigned long)totalPlanned]);
        return NO;
    }

    // Preflight: no silent skips.
    for (NSDictionary *e in entries) {
        NSString *rel = e[@"rel"];
        NSString *full = [root stringByAppendingPathComponent:rel];
        IPAZipEntryKind kind = (IPAZipEntryKind)[e[@"kind"] integerValue];
        if (rel.length > UINT16_MAX) {
            ipadec_set_zip_error(error, 10,
                [NSString stringWithFormat:@"ZIP path name too long: %@", rel]);
            return NO;
        }
        if (kind == IPAZipEntryFile) {
            uint32_t crc = 0;
            uint64_t fsize = 0;
            if (!ipadec_crc32_and_size_of_file(full, &crc, &fsize)) {
                ipadec_set_zip_error(error, 8,
                    [NSString stringWithFormat:@"ZIP cannot read file: %@", rel]);
                return NO;
            }
            if (fsize > UINT32_MAX) {
                ipadec_set_zip_error(error, 9,
                    [NSString stringWithFormat:
                        @"ZIP file exceeds classic 4GiB store limit: %@", rel]);
                return NO;
            }
            (void)crc;
        } else if (kind == IPAZipEntrySymlink) {
            NSData *target = nil;
            NSError *rlErr = nil;
            if (!ipadec_readlink_target(full, &target, &rlErr) || target.length == 0) {
                ipadec_set_zip_error(error, 14,
                    [NSString stringWithFormat:@"ZIP cannot readlink: %@", rel]);
                return NO;
            }
            if (target.length > UINT32_MAX) {
                ipadec_set_zip_error(error, 9,
                    [NSString stringWithFormat:@"ZIP symlink target too large: %@", rel]);
                return NO;
            }
        }
    }

    [fm createDirectoryAtPath:ipaPath.stringByDeletingLastPathComponent
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];

    // Write to a temp path; only publish final name on full success.
    NSString *tmpPath = [ipaPath stringByAppendingString:@".writing"];
    [fm removeItemAtPath:tmpPath error:nil];
    if (![fm createFileAtPath:tmpPath contents:nil attributes:nil]) {
        ipadec_set_zip_error(error, 2, @"Cannot create temporary IPA file");
        return NO;
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:tmpPath];
    if (!fh) {
        [fm removeItemAtPath:tmpPath error:nil];
        ipadec_set_zip_error(error, 3, @"Cannot open temporary IPA for writing");
        return NO;
    }

    __block BOOL zipFailed = NO;
    void (^failZip)(NSInteger, NSString *) = ^(NSInteger code, NSString *msg) {
        zipFailed = YES;
        [fh closeFile];
        // Only discard the in-progress temp. Never touch a previous good ipaPath.
        [fm removeItemAtPath:tmpPath error:nil];
        ipadec_set_zip_error(error, code, msg);
    };

    NSMutableArray<NSData *> *cdEntries = [NSMutableArray array];
    const uint32_t lfhSig = 0x04034b50;
    const uint32_t cdSig = 0x02014b50;
    const uint32_t eocdSig = 0x06054b50;
    const uint16_t verMadeByUnix = (uint16_t)((3u << 8) | 20u);

    for (NSDictionary *e in entries) {
        if (zipFailed) break;
        @autoreleasepool {
            NSString *rel = e[@"rel"];
            NSString *full = [root stringByAppendingPathComponent:rel];
            IPAZipEntryKind kind = (IPAZipEntryKind)[e[@"kind"] integerValue];
            struct stat st;
            if (lstat(full.fileSystemRepresentation, &st) != 0) {
                failZip(6, [NSString stringWithFormat:@"ZIP lstat mid-write failed: %@", rel]);
                break;
            }

            NSString *zipName = rel;
            if (kind == IPAZipEntryDir && ![zipName hasSuffix:@"/"]) {
                zipName = [zipName stringByAppendingString:@"/"];
            }
            NSData *nameData = [zipName dataUsingEncoding:NSUTF8StringEncoding];
            if (!nameData || nameData.length > UINT16_MAX) {
                failZip(10, [NSString stringWithFormat:@"ZIP path encode failed: %@", rel]);
                break;
            }
            uint16_t nameLen = (uint16_t)nameData.length;

            uint32_t crc = 0;
            uint32_t size32 = 0;
            NSData *payload = nil; // symlink target only; files stream

            if (kind == IPAZipEntryFile) {
                uint64_t fsize = 0;
                if (!ipadec_crc32_and_size_of_file(full, &crc, &fsize) || fsize > UINT32_MAX) {
                    failZip(8, [NSString stringWithFormat:@"ZIP lost readability: %@", rel]);
                    break;
                }
                size32 = (uint32_t)fsize;
            } else if (kind == IPAZipEntrySymlink) {
                NSError *rlErr = nil;
                if (!ipadec_readlink_target(full, &payload, &rlErr) || !payload) {
                    failZip(14, [NSString stringWithFormat:@"ZIP readlink mid-write: %@", rel]);
                    break;
                }
                size32 = (uint32_t)payload.length;
                uLong c = crc32(0L, Z_NULL, 0);
                c = crc32(c, payload.bytes, (uInt)payload.length);
                crc = (uint32_t)c;
            } else {
                // directory: empty payload
                crc = 0;
                size32 = 0;
            }

            unsigned long long offsetULL = fh.offsetInFile;
            unsigned long long after =
                offsetULL + 30ull + (unsigned long long)nameLen + (unsigned long long)size32;
            if (offsetULL > UINT32_MAX || after > UINT32_MAX) {
                failZip(11, [NSString stringWithFormat:
                    @"ZIP would exceed classic 4GiB limit at: %@", rel]);
                break;
            }
            uint32_t offset = (uint32_t)offsetULL;
            uint32_t extAttrs = ipadec_zip_external_attrs_from_lstat(&st, kind == IPAZipEntryDir);

            NSMutableData *lfh = [NSMutableData data];
            ipadec_write_le32(lfh, lfhSig);
            ipadec_write_le16(lfh, 20);
            ipadec_write_le16(lfh, 0);
            ipadec_write_le16(lfh, 0); // store
            ipadec_write_le16(lfh, 0);
            ipadec_write_le16(lfh, 0);
            ipadec_write_le32(lfh, crc);
            ipadec_write_le32(lfh, size32);
            ipadec_write_le32(lfh, size32);
            ipadec_write_le16(lfh, nameLen);
            ipadec_write_le16(lfh, 0);
            [fh writeData:lfh];
            [fh writeData:nameData];

            if (kind == IPAZipEntryFile) {
                if (!ipadec_stream_copy_file_to_handle(full, fh, size32)) {
                    failZip(4, [NSString stringWithFormat:@"Failed streaming %@", rel]);
                    break;
                }
            } else if (kind == IPAZipEntrySymlink) {
                [fh writeData:payload];
            }

            NSMutableData *cd = [NSMutableData data];
            ipadec_write_le32(cd, cdSig);
            ipadec_write_le16(cd, verMadeByUnix);
            ipadec_write_le16(cd, 20);
            ipadec_write_le16(cd, 0);
            ipadec_write_le16(cd, 0);
            ipadec_write_le16(cd, 0);
            ipadec_write_le16(cd, 0);
            ipadec_write_le32(cd, crc);
            ipadec_write_le32(cd, size32);
            ipadec_write_le32(cd, size32);
            ipadec_write_le16(cd, nameLen);
            ipadec_write_le16(cd, 0);
            ipadec_write_le16(cd, 0);
            ipadec_write_le16(cd, 0);
            ipadec_write_le16(cd, 0);
            ipadec_write_le32(cd, extAttrs);
            ipadec_write_le32(cd, offset);
            [cd appendData:nameData];
            [cdEntries addObject:cd];
        }
    }

    if (zipFailed) return NO;

    if (cdEntries.count != totalPlanned) {
        failZip(12, @"ZIP entry count mismatch after write");
        return NO;
    }

    unsigned long long cdOffsetULL = fh.offsetInFile;
    if (cdOffsetULL > UINT32_MAX) {
        failZip(11, @"ZIP central-directory offset exceeds classic 4GiB limit");
        return NO;
    }
    uint32_t cdOffset = (uint32_t)cdOffsetULL;
    uint64_t cdSize64 = 0;
    for (NSData *cd in cdEntries) {
        cdSize64 += cd.length;
        if (cdSize64 > UINT32_MAX) {
            failZip(11, @"ZIP central directory exceeds classic 4GiB limit");
            return NO;
        }
        [fh writeData:cd];
    }
    uint32_t cdSize = (uint32_t)cdSize64;

    uint16_t totalEntries = (uint16_t)cdEntries.count;
    NSMutableData *eocd = [NSMutableData data];
    ipadec_write_le32(eocd, eocdSig);
    ipadec_write_le16(eocd, 0);
    ipadec_write_le16(eocd, 0);
    ipadec_write_le16(eocd, totalEntries);
    ipadec_write_le16(eocd, totalEntries);
    ipadec_write_le32(eocd, cdSize);
    ipadec_write_le32(eocd, cdOffset);
    ipadec_write_le16(eocd, 0);
    [fh writeData:eocd];
    [fh closeFile];

    // Same-directory POSIX rename replaces the final name atomically when both
    // exist — no remove-then-move window that can lose a previous good IPA.
    if (rename(tmpPath.fileSystemRepresentation, ipaPath.fileSystemRepresentation) != 0) {
        int saved = errno;
        [fm removeItemAtPath:tmpPath error:nil];
        // Leave any existing ipaPath untouched on publish failure.
        ipadec_set_zip_error(error, 15,
            [NSString stringWithFormat:@"Failed to publish IPA (rename): %s", strerror(saved)]);
        return NO;
    }
    return YES;
}

// Collect Mach-O paths under an app bundle that may be FairPlay-encrypted:
// main is handled separately; here: Frameworks (nested), PlugIns/*.appex, .dylib, etc.
// Bundle executables come from Info.plist CFBundleExecutable when present.
static NSArray<NSString *> *ipadec_collect_dependency_binaries(NSString *appRoot)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    void (^addPath)(NSString *) = ^(NSString *path) {
        if (path.length == 0) return;
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) return;
        if ([seen containsObject:path]) return;
        [seen addObject:path];
        [out addObject:path];
    };

    NSDirectoryEnumerator *en = [fm enumeratorAtPath:appRoot];
    for (NSString *rel in en) {
        NSString *full = [appRoot stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
        NSString *ext = full.pathExtension.lowercaseString;

        if (isDir && ([ext isEqualToString:@"framework"] ||
                      [ext isEqualToString:@"appex"] ||
                      [ext isEqualToString:@"bundle"] ||
                      [ext isEqualToString:@"xctest"])) {
            NSString *infoPath = [full stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
            NSString *exec = ipadec_nonempty_string(info[@"CFBundleExecutable"]);
            if (exec.length == 0) {
                exec = full.lastPathComponent.stringByDeletingPathExtension;
            }
            if (exec.length > 0) {
                addPath([full stringByAppendingPathComponent:exec]);
            }
            // Do not skip descendants: nested Frameworks live under *.framework/Frameworks.
            continue;
        }

        if (!isDir && [ext isEqualToString:@"dylib"]) {
            addPath(full);
        }
    }

    [out sortUsingSelector:@selector(compare:)];
    return out;
}

static NSString *ipadec_sanitize_ipa_name(NSString *name)
{
    NSString *base = name.length > 0 ? name : @"App";
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < base.length; i++) {
        unichar c = [base characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [out appendFormat:@"%C", c];
        } else if (c == ' ' || c == '\t') {
            // drop whitespace
        } else {
            [out appendString:@"_"];
        }
    }
    if (out.length == 0) [out appendString:@"App"];
    return out;
}

bool ipadecryptor_probe_installed_app(NSString *bundleID, NSString **messageOut)
{
    NSDictionary<NSString *, NSString *> *entry = ipadec_lookup_app(bundleID);
    if (!entry) {
        if (messageOut) *messageOut = @"Select an installed app first.";
        log_user("[IPADEC] No installed app selected/found for bundle id: %s\n",
                 bundleID.UTF8String ?: "(nil)");
        return false;
    }

    NSString *bundlePath = entry[kIPADecryptorKeyBundlePath];
    NSString *execPath = ipadec_executable_path_for_bundle(bundlePath);
    if (!ipadec_file_exists(execPath)) {
        NSString *msg = [NSString stringWithFormat:@"Executable not found in %@", bundlePath.lastPathComponent ?: bundlePath];
        if (messageOut) *messageOut = msg;
        log_user("[IPADEC] %s\n", msg.UTF8String);
        return false;
    }

    IPADecryptorMachOInfo mainInfo = ipadec_macho_info_for_file(execPath);
    log_user("[IPADEC] Target: %s (%s)\n",
             (entry[kIPADecryptorKeyName] ?: bundleID).UTF8String,
             bundleID.UTF8String);
    log_user("[IPADEC] Bundle: %s\n", bundlePath.UTF8String);
    log_user("[IPADEC] Main executable: %s\n", execPath.UTF8String);
    log_user("[IPADEC] Main encryption: %s\n", ipadec_macho_summary(mainInfo).UTF8String);
    log_user("[IPADEC] Output directory: %s\n", ipadecryptor_default_output_directory().UTF8String);

    if (!mainInfo.isMachO) {
        if (messageOut) *messageOut = @"Main executable is not a Mach-O file.";
        return false;
    }

    NSString *msg = mainInfo.hasEncryptionInfo
        ? [NSString stringWithFormat:@"Probe OK: cryptid=%u, cryptsize=0x%x.",
                                     mainInfo.cryptid,
                                     mainInfo.cryptsize]
        : @"Probe OK: Mach-O found, no encryption command in main executable.";
    if (messageOut) *messageOut = msg;
    return true;
}

bool ipadecryptor_start_decrypt_installed_app(NSString *bundleID, NSString **messageOut)
{
    NSString *probeMessage = nil;
    if (!ipadecryptor_probe_installed_app(bundleID, &probeMessage)) {
        if (messageOut) *messageOut = probeMessage ?: @"Probe failed.";
        return false;
    }

    if (!kexploit_krw_ready()) {
        if (messageOut) *messageOut = @"KRW not ready. Run the kernel chain first.";
        log_user("[IPADEC] KRW not ready\n");
        return false;
    }

    (void)ipadec_ensure_sandbox_for_dump();

    NSDictionary<NSString *, NSString *> *entry = ipadec_lookup_app(bundleID);
    NSString *bundlePath = entry[kIPADecryptorKeyBundlePath];
    NSString *appName = entry[kIPADecryptorKeyName] ?: bundleID;
    NSString *execPath = ipadec_executable_path_for_bundle(bundlePath);
    NSString *execName = execPath.lastPathComponent;
    NSString *appBundleName = bundlePath.lastPathComponent; // Foo.app

    if (execName.length == 0 || appBundleName.length == 0) {
        if (messageOut) *messageOut = @"Could not resolve executable/bundle names.";
        return false;
    }

    log_user("[IPADEC] Starting decrypt for %s\n", bundleID.UTF8String);

    // Find live process: KRW p_name (lara-style), optional path confirm.
    // Final dump safety is LC_UUID image match, not proc_pidpath (often empty on iOS).
    pid_t pid = ipadec_ensure_target_running(bundleID, execPath);
    if (pid <= 0) {
        NSString *msg = @"Target process not found. Open the selected app once, keep it in memory, then retry decrypt.";
        if (messageOut) *messageOut = msg;
        log_user("[IPADEC] %s want=%s exec=%s\n",
                 msg.UTF8String,
                 execPath.UTF8String ?: "(nil)",
                 execName.UTF8String ?: "(nil)");
        return false;
    }
    {
        NSString *livePath = ipadec_pid_executable_path(pid);
        if (livePath.length > 0) {
            if (!ipadec_exec_paths_match(execPath, livePath)) {
                NSString *msg = [NSString stringWithFormat:
                    @"Refusing dump: pid %d path %@ does not match selected %@",
                    (int)pid, livePath, execPath];
                if (messageOut) *messageOut = msg;
                log_user("[IPADEC] %s\n", msg.UTF8String);
                return false;
            }
            log_user("[IPADEC] Live process pid=%d path=%s\n",
                     (int)pid, livePath.UTF8String);
        } else {
            log_user("[IPADEC] Live process pid=%d (path unavailable; UUID will verify image)\n",
                     (int)pid);
        }
    }

    NSString *outDir = ipadecryptor_default_output_directory();
    NSString *workDir = [outDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@".tmp_%@", bundleID]];
    NSString *destAppPath = [workDir stringByAppendingPathComponent:appBundleName];
    NSString *payloadDir = [workDir stringByAppendingPathComponent:@"Payload"];
    NSString *payloadAppPath = [payloadDir stringByAppendingPathComponent:appBundleName];
    NSString *ipaName = [ipadec_sanitize_ipa_name(appName) stringByAppendingString:@".ipa"];
    NSString *ipaPath = [outDir stringByAppendingPathComponent:ipaName];

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:workDir error:nil];
    [fm createDirectoryAtPath:payloadDir withIntermediateDirectories:YES attributes:nil error:nil];

    log_user("[IPADEC] Copying bundle to workdir (preserving modes)...\n");
    NSError *copyErr = nil;
    if (!ipadec_copy_item(bundlePath, destAppPath, &copyErr)) {
        NSString *msg = [NSString stringWithFormat:@"Failed to copy app bundle: %@",
                                                   copyErr.localizedDescription ?: @"unknown error"];
        if (messageOut) *messageOut = msg;
        log_user("[IPADEC] %s src=%s\n", msg.UTF8String, bundlePath.UTF8String);
        [fm removeItemAtPath:workDir error:nil];
        return false;
    }
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:destAppPath isDirectory:&isDir] || !isDir) {
        NSString *msg = @"Copy reported success but destination bundle is missing.";
        if (messageOut) *messageOut = msg;
        log_user("[IPADEC] %s\n", msg.UTF8String);
        [fm removeItemAtPath:workDir error:nil];
        return false;
    }

    NSString *mainBinaryOut = [destAppPath stringByAppendingPathComponent:execName];
    NSString *mainBinarySrc = [bundlePath stringByAppendingPathComponent:execName];
    log_user("[IPADEC] Decrypting main binary only (dep image matching not enabled)...\n");
    int mainRet = ipadec_decrypt_binary_pid(mainBinarySrc.UTF8String, pid, mainBinaryOut.UTF8String);
    if (mainRet != 0) {
        // Fallback: try decrypting using the already-copied file as the source image.
        mainRet = ipadec_decrypt_binary_pid(mainBinaryOut.UTF8String, pid, mainBinaryOut.UTF8String);
    }
    if (mainRet != 0) {
        NSString *msg = @"Failed to decrypt main binary (incomplete crypt dump or map miss). See *.partial if present.";
        if (messageOut) *messageOut = msg;
        log_user("[IPADEC] %s\n", msg.UTF8String);
        NSString *failedDir = [outDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@".failed_%@", bundleID]];
        [fm removeItemAtPath:failedDir error:nil];
        [fm moveItemAtPath:workDir toPath:failedDir error:nil];
        return false;
    }

    // Inventory encrypted deps for disclosure only. Do NOT dump them with the
    // main-binary VM heuristic (shared __TEXT.fileoff=0 causes wrong image reads).
    NSArray<NSString *> *depBinaries = ipadec_collect_dependency_binaries(destAppPath);
    NSMutableArray<NSString *> *stillEncryptedDeps = [NSMutableArray array];
    for (NSString *depPath in depBinaries) {
        if ([depPath isEqualToString:mainBinaryOut]) continue;
        int enc = ipadec_is_encrypted_path(depPath.UTF8String);
        if (enc <= 0) continue;
        NSString *rel = [depPath hasPrefix:destAppPath]
            ? [depPath substringFromIndex:destAppPath.length]
            : depPath.lastPathComponent;
        if ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
        [stillEncryptedDeps addObject:rel];
        log_user("[IPADEC] encrypted dependency left as-is (no image match): %s\n",
                 rel.UTF8String);
    }
    if (stillEncryptedDeps.count > 0) {
        log_user("[IPADEC] %lu encrypted dependency binary(ies) not dumped; main-only IPA\n",
                 (unsigned long)stillEncryptedDeps.count);
    }

    NSError *moveErr = nil;
    [fm removeItemAtPath:payloadAppPath error:nil];
    if (![fm moveItemAtPath:destAppPath toPath:payloadAppPath error:&moveErr]) {
        NSString *msg = [NSString stringWithFormat:@"Failed to stage Payload: %@",
                                                   moveErr.localizedDescription ?: @"unknown error"];
        if (messageOut) *messageOut = msg;
        log_user("[IPADEC] %s\n", msg.UTF8String);
        NSString *failedDir = [outDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@".failed_%@", bundleID]];
        [fm removeItemAtPath:failedDir error:nil];
        [fm moveItemAtPath:workDir toPath:failedDir error:nil];
        return false;
    }

    log_user("[IPADEC] Writing IPA (streamed store ZIP, fail-closed)...\n");
    NSError *zipErr = nil;
    if (!ipadec_create_zip_from_directory(workDir, ipaPath, &zipErr)) {
        NSString *msg = [NSString stringWithFormat:@"Failed to create IPA: %@",
                                                   zipErr.localizedDescription ?: @"unknown error"];
        if (messageOut) *messageOut = msg;
        log_user("[IPADEC] %s\n", msg.UTF8String);
        NSString *failedDir = [outDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@".failed_%@", bundleID]];
        [fm removeItemAtPath:failedDir error:nil];
        [fm moveItemAtPath:workDir toPath:failedDir error:nil];
        return false;
    }

    [fm removeItemAtPath:workDir error:nil];
    log_user("[IPADEC] IPA saved to %s\n", ipaPath.UTF8String);

    // Durable last-output path for Settings share sheet.
    [[NSUserDefaults standardUserDefaults] setObject:ipaPath
                                              forKey:@"IPADecryptorLastOutputPath"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if (messageOut) {
        if (stillEncryptedDeps.count > 0) {
            NSString *list = stillEncryptedDeps.count <= 8
                ? [stillEncryptedDeps componentsJoinedByString:@", "]
                : [NSString stringWithFormat:@"%@, … (+%lu more)",
                     [[stillEncryptedDeps subarrayWithRange:NSMakeRange(0, 8)]
                      componentsJoinedByString:@", "],
                     (unsigned long)(stillEncryptedDeps.count - 8)];
            *messageOut = [NSString stringWithFormat:NSLocalizedString(
                @"Main binary decrypted IPA saved to %@. %lu encrypted dependency binary(ies) left encrypted (image-matched dep dump not enabled yet): %@.", nil),
                ipaPath, (unsigned long)stillEncryptedDeps.count, list];
        } else {
            *messageOut = [NSString stringWithFormat:NSLocalizedString(
                @"Main-binary decrypted IPA saved to %@", nil), ipaPath];
        }
    }
    return true;
}
