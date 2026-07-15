//
//  MobileGestaltViewController.m
//  Cyanide
//

#import "MobileGestaltViewController.h"
#import "SettingsViewController.h"
#import "LogTextView.h"
#import "utils/sandbox.h"

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>
#import <sys/proc.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <unistd.h>

static NSString * const CYMGCurrentPath = @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";
static NSString * const CYMGTestPath = @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.test.plist";
static NSString * const CYMGWarningAcknowledgedKey = @"MobileGestaltWarningAcknowledged";

static NSString * const CYMGKindAction = @"action";
static NSString * const CYMGKindToggle = @"toggle";
static NSString * const CYMGKindPicker = @"picker";
static NSString * const CYMGKindText = @"text";

static NSString *CYMGL(NSString *text)
{
    return NSLocalizedString(text, nil);
}

static BOOL CYMGDebuggerAttached(void)
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc info = {0};
    size_t size = sizeof(info);
    BOOL traced = sysctl(mib, 4, &info, &size, NULL, 0) == 0 &&
                  (info.kp_proc.p_flag & P_TRACED) != 0;

    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    NSArray<NSString *> *xcodeKeys = @[
        @"CYANIDE_XCODE_RUN",
        @"__XCODE_BUILT_PRODUCTS_DIR_PATHS",
        @"__XPC_DYLD_FRAMEWORK_PATH",
        @"DYLD_FRAMEWORK_PATH",
        @"DYLD_LIBRARY_PATH",
        @"IDE_DISABLED_OS_ACTIVITY_DT_MODE",
        @"IDEPreferLogStreaming",
        @"OS_ACTIVITY_DT_MODE",
        @"XCODE_RUNNING_FOR_PREVIEWS",
        @"XCInjectBundleInto",
    ];
    NSString *matchedKey = nil;
    for (NSString *key in xcodeKeys) {
        if ([environment[key] length] > 0) {
            matchedKey = key;
            break;
        }
    }

    BOOL enabled = traced || matchedKey.length > 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log_user("[MG][DEBUG] FAKE tools %s (P_TRACED=%d, XcodeEnv=%s).\n",
                 enabled ? "enabled" : "hidden",
                 traced,
                 matchedKey.length > 0 ? matchedKey.UTF8String : "none");
    });
    return enabled;
}

static NSError *CYMGMakeError(NSString *message)
{
    return [NSError errorWithDomain:@"Cyanide.MobileGestalt"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

static NSString *CYMGBackupPath(void)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                               NSUserDomainMask,
                                                               YES).firstObject;
    return [documents stringByAppendingPathComponent:@"SavedGestalt.plist"];
}

static NSMutableDictionary *CYMGReadMutablePlist(NSString *path, NSError **error)
{
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (data.length == 0) {
        if (error && !*error) *error = CYMGMakeError(CYMGL(@"The property list is empty or unreadable."));
        return nil;
    }

    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                          options:NSPropertyListMutableContainersAndLeaves
                                                           format:nil
                                                            error:error];
    if (![plist isKindOfClass:NSMutableDictionary.class]) {
        if (error && !*error) *error = CYMGMakeError(CYMGL(@"The property list root is not a dictionary."));
        return nil;
    }
    return plist;
}

static NSData *CYMGValidatedPlistData(NSDictionary *plist, NSError **error)
{
    if (![NSPropertyListSerialization propertyList:plist
                                  isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
        if (error) *error = CYMGMakeError(CYMGL(@"The property list contains invalid values."));
        return nil;
    }

    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:error];
    if (data.length == 0) {
        if (error && !*error) *error = CYMGMakeError(CYMGL(@"Refusing to write an empty property list."));
        return nil;
    }

    id roundTrip = [NSPropertyListSerialization propertyListWithData:data
                                                              options:0
                                                               format:nil
                                                                error:error];
    if (![roundTrip isKindOfClass:NSDictionary.class]) {
        if (error && !*error) *error = CYMGMakeError(CYMGL(@"The serialized property list failed validation."));
        return nil;
    }
    return data;
}

static BOOL CYMGWriteAll(int fd, const uint8_t *bytes, NSUInteger length)
{
    NSUInteger total = 0;
    while (total < length) {
        ssize_t count = write(fd, bytes + total, length - total);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        total += (NSUInteger)count;
    }
    return YES;
}

static BOOL CYMGWriteDataToPath(NSData *data,
                                NSString *path,
                                BOOL allowCreate,
                                NSError **error)
{
    if (data.length == 0) {
        if (error) *error = CYMGMakeError(CYMGL(@"Refusing to write empty data."));
        return NO;
    }

    struct stat st = {0};
    BOOL exists = stat(path.fileSystemRepresentation, &st) == 0;
    if (!exists && !allowCreate) {
        if (error) *error = CYMGMakeError(CYMGL(@"The target file does not exist."));
        return NO;
    }
    if (exists && st.st_size == 0) {
        if (error) *error = CYMGMakeError(CYMGL(@"The target file is already 0 bytes. Writing was aborted."));
        return NO;
    }

    int flags = O_WRONLY | (allowCreate ? O_CREAT : 0);
    int fd = open(path.fileSystemRepresentation, flags, 0644);
    if (fd < 0) {
        if (error) {
            *error = CYMGMakeError([NSString stringWithFormat:@"open(%@) failed: %s",
                                   path, strerror(errno)]);
        }
        return NO;
    }

    BOOL ok = lseek(fd, 0, SEEK_SET) >= 0 && CYMGWriteAll(fd, data.bytes, data.length);
    if (ok) ok = ftruncate(fd, (off_t)data.length) == 0;
    if (ok) ok = fsync(fd) == 0;
    int savedErrno = errno;
    close(fd);
    if (!ok && error) {
        *error = CYMGMakeError([NSString stringWithFormat:@"write(%@) failed: %s",
                               path, strerror(savedErrno)]);
    }
    return ok;
}

static BOOL CYMGWritePlist(NSDictionary *plist,
                           NSString *path,
                           BOOL allowCreate,
                           NSError **error)
{
    NSData *data = CYMGValidatedPlistData(plist, error);
    if (!data) return NO;
    return CYMGWriteDataToPath(data, path, allowCreate, error);
}

static double CYMGSystemVersion(void)
{
    return UIDevice.currentDevice.systemVersion.doubleValue;
}

static NSString *CYMGMachineName(void)
{
    struct utsname info = {0};
    uname(&info);
    return [NSString stringWithUTF8String:info.machine] ?: @"unknown";
}

static BOOL CYMGHasHomeButton(void)
{
    SEL selector = NSSelectorFromString(@"_hasHomeButton");
    Class cls = UIDevice.class;
    if (![cls respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(cls, selector);
}

static long CYMGFindCacheDataOffset(const char *mgKey)
{
    const char *imagePath = "/usr/lib/libMobileGestalt.dylib";
    const struct mach_header_64 *header = NULL;
    dlopen(imagePath, RTLD_LAZY | RTLD_GLOBAL);

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strncmp(imagePath, name, strlen(imagePath)) == 0) {
            header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            break;
        }
    }
    if (!header) return -1;

    unsigned long stringSize = 0;
    const char *strings = (const char *)getsectiondata(header, "__TEXT", "__cstring", &stringSize);
    if (!strings) return -1;

    const char *keyAddress = NULL;
    for (unsigned long offset = 0; offset < stringSize; ) {
        const char *value = strings + offset;
        size_t length = strnlen(value, stringSize - offset);
        if (strcmp(value, mgKey) == 0) {
            keyAddress = value;
            break;
        }
        offset += length + 1;
    }
    if (!keyAddress) return -1;

    unsigned long constSize = 0;
    const uintptr_t *constants = (const uintptr_t *)getsectiondata(header,
                                                                    "__AUTH_CONST",
                                                                    "__const",
                                                                    &constSize);
    if (!constants) {
        constants = (const uintptr_t *)getsectiondata(header,
                                                       "__DATA_CONST",
                                                       "__const",
                                                       &constSize);
    }
    if (!constants) return -1;

    for (unsigned long i = 0; i < constSize / sizeof(uintptr_t); i++) {
        if (constants[i] != (uintptr_t)keyAddress) continue;
        const uint16_t *entry = (const uint16_t *)&constants[i];
        return ((long)entry[0x9a / 2]) << 3;
    }
    return -1;
}

static NSDictionary *CYMGActionRow(NSString *title, NSString *identifier, BOOL destructive)
{
    return @{ @"kind": CYMGKindAction,
              @"title": title,
              @"id": identifier,
              @"destructive": @(destructive) };
}

static NSDictionary *CYMGPickerRow(NSString *title, NSString *icon, NSString *identifier)
{
    return @{ @"kind": CYMGKindPicker,
              @"title": title,
              @"icon": icon ?: @"",
              @"id": identifier };
}

static NSDictionary *CYMGTextRow(NSString *title, NSString *identifier)
{
    return @{ @"kind": CYMGKindText,
              @"title": title,
              @"id": identifier };
}

static NSDictionary *CYMGToggleRow(NSString *title,
                                   NSString *icon,
                                   NSArray<NSString *> *keys,
                                   id enabledValue)
{
    return @{ @"kind": CYMGKindToggle,
              @"source": @"mg",
              @"title": title,
              @"icon": icon ?: @"",
              @"keys": keys,
              @"enabledValue": enabledValue ?: @1 };
}

static NSDictionary *CYMGSpecialToggleRow(NSString *title,
                                          NSString *icon,
                                          NSString *identifier)
{
    return @{ @"kind": CYMGKindToggle,
              @"source": @"special",
              @"title": title,
              @"icon": icon ?: @"",
              @"id": identifier };
}

static NSDictionary *CYMGPreferenceRow(NSString *title,
                                       NSString *icon,
                                       NSString *key,
                                       NSString *path)
{
    return @{ @"kind": CYMGKindToggle,
              @"source": @"preference",
              @"title": title,
              @"icon": icon ?: @"",
              @"key": key,
              @"path": path };
}

static NSArray<NSDictionary *> *CYMGAllPreferenceKeys(void)
{
    NSString *springboard = @"/var/Managed Preferences/mobile/com.apple.springboard.plist";
    NSString *global = @"/var/Managed Preferences/mobile/.GlobalPreferences.plist";
    NSString *airdrop = @"/var/Managed Preferences/mobile/com.apple.sharingd.plist";
    NSString *backboard = @"/var/Managed Preferences/mobile/com.apple.backboardd.plist";
    NSString *coreMotion = @"/var/Managed Preferences/mobile/com.apple.CoreMotion.plist";
    NSString *pasteboard = @"/var/Managed Preferences/mobile/com.apple.Pasteboard.plist";
    NSString *appStore = @"/var/Managed Preferences/mobile/com.apple.AppStore.plist";
    NSString *notes = @"/var/Managed Preferences/mobile/com.apple.mobilenotes.plist";

    return @[
        @{ @"key": @"SBSuppressDynamicIslandCompletely", @"path": springboard },
        @{ @"key": @"SBShowAuthenticationEngineeringUI", @"path": springboard },
        @{ @"key": @"UIStatusBarShowBuildVersion", @"path": global },
        @{ @"key": @"NSForceRightToLeftWritingDirection", @"path": global },
        @{ @"key": @"NSForceLeftToRightWritingDirection", @"path": global },
        @{ @"key": @"GesturesEnabled", @"path": global },
        @{ @"key": @"SBDisableClockIconSecondsHand", @"path": global },
        @{ @"key": @"SBHardwareButtonHintDropletsAlwaysVisibleInSnapshots", @"path": global },
        @{ @"key": @"BKHideAppleLogoOnLaunch", @"path": backboard },
        @{ @"key": @"SBNeverBreadcrumb", @"path": springboard },
        @{ @"key": @"SBShowSupervisionTextOnLockScreen", @"path": springboard },
        @{ @"key": @"OverrideTimeLimitEveryoneMode", @"path": airdrop },
        @{ @"key": @"SBDontLockAfterCrash", @"path": springboard },
        @{ @"key": @"SBDontDimOrLockOnAC", @"path": springboard },
        @{ @"key": @"SBHideLowPowerAlerts", @"path": springboard },
        @{ @"key": @"SBHideACPower", @"path": springboard },
        @{ @"key": @"SBAlwaysShowSystemApertureInSnapshots", @"path": springboard },
        @{ @"key": @"SBExtendedDisplayOverrideSupportForAirPlayAndDontFileRadars", @"path": springboard },
        @{ @"key": @"SBIconVisibility", @"path": global },
        @{ @"key": @"SBSearchDisabledDomains", @"path": global },
        @{ @"key": @"EnableWakeGestureHaptic", @"path": coreMotion },
        @{ @"key": @"PlaySoundOnPaste", @"path": pasteboard },
        @{ @"key": @"AnnounceAllPastes", @"path": pasteboard },
        @{ @"key": @"MetalForceHudEnabled", @"path": global },
        @{ @"key": @"iMessageDiagnosticsEnabled", @"path": global },
        @{ @"key": @"IDSDiagnosticsEnabled", @"path": global },
        @{ @"key": @"VCDiagnosticsEnabled", @"path": global },
        @{ @"key": @"AccessoryDeveloperEnabled", @"path": global },
        @{ @"key": @"debugGestureEnabled", @"path": appStore },
        @{ @"key": @"DebugModeEnabled", @"path": notes },
        @{ @"key": @"BKDigitizerVisualizeTouches", @"path": backboard },
    ];
}

@interface CYMGFileViewController : UITableViewController
- (instancetype)initWithCurrentGestalt:(NSMutableDictionary *)gestalt;
@end

@interface CYMGDictionaryViewController : UITableViewController
@property (nonatomic, copy) NSString *dictionaryTitle;
@property (nonatomic, strong) NSDictionary *dictionary;
@property (nonatomic, strong) NSArray<NSString *> *keys;
- (instancetype)initWithTitle:(NSString *)title dictionary:(NSDictionary *)dictionary;
@end

@implementation CYMGDictionaryViewController

- (instancetype)initWithTitle:(NSString *)title dictionary:(NSDictionary *)dictionary
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _dictionaryTitle = [title copy];
        _dictionary = dictionary ?: @{};
        _keys = [[_dictionary allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [[a description] localizedCaseInsensitiveCompare:[b description]];
        }];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = self.dictionaryTitle;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.keys.count;
}

- (NSString *)displayValue:(id)value
{
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
            return [value boolValue] ? CYMGL(@"True") : CYMGL(@"False");
        }
        return [value stringValue];
    }
    if ([value isKindOfClass:NSData.class]) return [value base64EncodedStringWithOptions:0];
    if ([value isKindOfClass:NSArray.class]) return [value description];
    if ([value isKindOfClass:NSDate.class]) return [value description];
    return [value description] ?: CYMGL(@"Unknown");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MGDictionaryValue"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"MGDictionaryValue"];
    }
    NSString *key = self.keys[indexPath.row];
    id value = self.dictionary[key];
    cell.textLabel.text = [key description];
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.text = [value isKindOfClass:NSDictionary.class]
        ? [NSString stringWithFormat:CYMGL(@"Dictionary (%lu)"), (unsigned long)[value count]]
        : [self displayValue:value];
    cell.detailTextLabel.numberOfLines = 3;
    cell.accessoryType = [value isKindOfClass:NSDictionary.class]
        ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = [value isKindOfClass:NSDictionary.class]
        ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *key = self.keys[indexPath.row];
    NSDictionary *value = self.dictionary[key];
    if (![value isKindOfClass:NSDictionary.class]) return;
    CYMGDictionaryViewController *child = [[CYMGDictionaryViewController alloc]
        initWithTitle:key dictionary:value];
    [self.navigationController pushViewController:child animated:YES];
}

@end


@interface CYMGFileViewController ()
@property (nonatomic, strong) NSMutableDictionary *currentGestalt;
@property (nonatomic, strong) NSDictionary *cacheExtra;
@property (nonatomic, strong) NSArray<NSString *> *cacheKeys;
@end


@implementation CYMGFileViewController

- (instancetype)initWithCurrentGestalt:(NSMutableDictionary *)gestalt
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _currentGestalt = gestalt ?: [NSMutableDictionary dictionary];
        _cacheExtra = [_currentGestalt[@"CacheExtra"] isKindOfClass:NSDictionary.class]
            ? _currentGestalt[@"CacheExtra"] : @{};
        _cacheKeys = [[_cacheExtra allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = CYMGL(@"Gestalt File");
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return CYMGDebuggerAttached() ? 4 : 3;
    return self.cacheKeys.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return CYMGL(@"Files");
    return @"CacheExtra";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0) {
        return CYMGL(CYMGDebuggerAttached()
            ? @"Apply (FAKE) writes a separate test file in the same cache directory. Apply Tweaks writes the live MobileGestalt."
            : @"Export the saved original, the live filesystem file, or the currently edited in-memory MobileGestalt.");
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MGFileAction"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                  reuseIdentifier:@"MGFileAction"];
        NSMutableArray *titles = [NSMutableArray arrayWithArray:@[
            @"Export Original MobileGestalt",
            @"Export MobileGestalt from Filesystem",
            @"Export Current MobileGestalt",
        ]];
        if (CYMGDebuggerAttached()) [titles addObject:@"Export Test MobileGestalt"];
        cell.textLabel.text = CYMGL(titles[indexPath.row]);
        cell.textLabel.textColor = self.view.tintColor;
        cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
        cell.userInteractionEnabled = YES;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MGCacheKey"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                              reuseIdentifier:@"MGCacheKey"];
    NSString *key = self.cacheKeys[indexPath.row];
    id value = self.cacheExtra[key];
    cell.textLabel.text = key;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    cell.detailTextLabel.text = [value isKindOfClass:NSDictionary.class]
        ? [NSString stringWithFormat:CYMGL(@"Dictionary (%lu)"), (unsigned long)[value count]]
        : [value description];
    cell.accessoryType = [value isKindOfClass:NSDictionary.class]
        ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = [value isKindOfClass:NSDictionary.class]
        ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) [self exportOriginal];
        else if (indexPath.row == 1) [self exportFilesystem];
        else if (indexPath.row == 2) [self exportCurrent];
        else if (CYMGDebuggerAttached()) {
            [self presentShareURL:[NSURL fileURLWithPath:CYMGTestPath]];
        }
        return;
    }

    NSString *key = self.cacheKeys[indexPath.row];
    NSDictionary *value = self.cacheExtra[key];
    if (![value isKindOfClass:NSDictionary.class]) return;
    CYMGDictionaryViewController *child = [[CYMGDictionaryViewController alloc]
        initWithTitle:key dictionary:value];
    [self.navigationController pushViewController:child animated:YES];
}

- (void)presentShareURL:(NSURL *)url
{
    if (!url || ![NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        [self showMessage:CYMGL(@"Export Failed")
                  message:CYMGL(@"The requested MobileGestalt file does not exist.")];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                 CGRectGetMidY(self.view.bounds),
                                                                 1, 1);
    [self presentViewController:share animated:YES completion:nil];
}

- (NSURL *)temporaryURLNamed:(NSString *)name
{
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    return url;
}

- (void)exportOriginal
{
    [self presentShareURL:[NSURL fileURLWithPath:CYMGBackupPath()]];
}

- (void)exportFilesystem
{
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:CYMGCurrentPath options:0 error:&error];
    NSURL *url = [self temporaryURLNamed:@"MobileGestalt-Filesystem.plist"];
    if (data.length == 0 || ![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
        [self showMessage:CYMGL(@"Export Failed") message:error.localizedDescription];
        return;
    }
    [self presentShareURL:url];
}

- (void)exportCurrent
{
    NSError *error = nil;
    NSData *data = CYMGValidatedPlistData(self.currentGestalt, &error);
    NSURL *url = [self temporaryURLNamed:@"MobileGestalt-Current.plist"];
    if (data.length == 0 || ![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
        [self showMessage:CYMGL(@"Export Failed") message:error.localizedDescription];
        return;
    }
    [self presentShareURL:url];
}

- (void)showMessage:(NSString *)title message:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message ?: CYMGL(@"Unknown error")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CYMGL(@"OK")
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@interface MobileGestaltViewController () <UITextFieldDelegate>
@property (nonatomic, strong) NSMutableDictionary *gestalt;
@property (nonatomic, strong) NSMutableDictionary *cacheExtra;
@property (nonatomic, strong) NSMutableDictionary *artwork;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *preferenceValues;
@property (nonatomic, strong) NSArray<NSDictionary *> *sections;
@property (nonatomic) NSInteger originalSubtype;
@property (nonatomic) NSInteger subtype;
@property (nonatomic, copy) NSString *productType;
@property (nonatomic, copy) NSString *deviceName;
@property (nonatomic) BOOL customDeviceName;
@property (nonatomic) BOOL loaded;
- (NSArray<NSDictionary *> *)productTypeOptions;
@end

@implementation MobileGestaltViewController

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = CYMGL(@"MobileGestalt Editor");
    self.preferenceValues = [NSMutableDictionary dictionary];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"doc"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(openFileTools)];

    BOOL accessReady = settings_mobilegestalt_access_ready();
    NSError *error = nil;
    self.loaded = accessReady && [self loadCurrentGestalt:&error];
    [self loadPreferenceValues];
    [self rebuildSections];
    self.navigationItem.rightBarButtonItem.enabled = self.loaded;

    if (accessReady && !self.loaded) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showError:CYMGL(@"Failed to load MobileGestalt") error:error];
        });
    }

    if (![NSUserDefaults.standardUserDefaults boolForKey:CYMGWarningAcknowledgedKey]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:CYMGL(@"Warning")
                                 message:CYMGL(@"MobileGestalt editing is dangerous. Incorrect values can crash SpringBoard, break device features, or cause a boot loop. Continue only if you understand how to restore the original file.")
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:CYMGL(@"I Understand")
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(__unused UIAlertAction *action) {
                [NSUserDefaults.standardUserDefaults setBool:YES
                                                      forKey:CYMGWarningAcknowledgedKey];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    }
}

- (BOOL)loadCurrentGestalt:(NSError **)error
{
    NSMutableDictionary *gestalt = CYMGReadMutablePlist(CYMGCurrentPath, error);
    if (!gestalt) return NO;

    NSMutableDictionary *cacheExtra = gestalt[@"CacheExtra"];
    if (![cacheExtra isKindOfClass:NSMutableDictionary.class] || cacheExtra.count == 0) {
        if (error) *error = CYMGMakeError(CYMGL(@"MobileGestalt is missing CacheExtra."));
        return NO;
    }

    NSString *backupPath = CYMGBackupPath();
    if (![NSFileManager.defaultManager fileExistsAtPath:backupPath]) {
        NSData *source = [NSData dataWithContentsOfFile:CYMGCurrentPath options:0 error:error];
        if (source.length == 0 || ![source writeToFile:backupPath options:NSDataWritingAtomic error:error]) {
            return NO;
        }
        log_user("[MG] Saved original MobileGestalt backup.\n");
    }

    NSError *backupError = nil;
    NSMutableDictionary *backup = CYMGReadMutablePlist(backupPath, &backupError);
    NSMutableDictionary *backupExtra = [backup[@"CacheExtra"] isKindOfClass:NSMutableDictionary.class]
        ? backup[@"CacheExtra"] : nil;

    NSMutableDictionary *artwork = cacheExtra[@"oPeik/9e8lQWMszEjbPzng"];
    if (![artwork isKindOfClass:NSMutableDictionary.class]) {
        artwork = [NSMutableDictionary dictionary];
        cacheExtra[@"oPeik/9e8lQWMszEjbPzng"] = artwork;
    }
    NSMutableDictionary *backupArtwork = [backupExtra[@"oPeik/9e8lQWMszEjbPzng"] isKindOfClass:NSMutableDictionary.class]
        ? backupExtra[@"oPeik/9e8lQWMszEjbPzng"] : nil;

    self.gestalt = gestalt;
    self.cacheExtra = cacheExtra;
    self.artwork = artwork;
    self.originalSubtype = [backupArtwork[@"ArtworkDeviceSubType"] integerValue];
    if (self.originalSubtype == 0) {
        self.originalSubtype = [artwork[@"ArtworkDeviceSubType"] integerValue];
    }
    self.subtype = artwork[@"ArtworkDeviceSubType"]
        ? [artwork[@"ArtworkDeviceSubType"] integerValue] : self.originalSubtype;
    self.productType = [cacheExtra[@"h9jDsbgj7xIVeIQ8S3/X3Q"] isKindOfClass:NSString.class]
        ? cacheExtra[@"h9jDsbgj7xIVeIQ8S3/X3Q"] : CYMGMachineName();
    self.deviceName = [backupArtwork[@"ArtworkDeviceProductDescription"] isKindOfClass:NSString.class]
        ? backupArtwork[@"ArtworkDeviceProductDescription"]
        : ([artwork[@"ArtworkDeviceProductDescription"] isKindOfClass:NSString.class]
           ? artwork[@"ArtworkDeviceProductDescription"] : CYMGMachineName());
    self.customDeviceName = NO;
    return YES;
}

- (void)rebuildSections
{
    double version = CYMGSystemVersion();
    BOOL isPad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    BOOL hasHomeButton = CYMGHasHomeButton();
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];

    NSMutableArray *applying = [NSMutableArray array];
    if (!self.loaded) {
        [applying addObject:CYMGActionRow(@"Prepare Kernel & Escape", @"prepare", NO)];
    }
    [applying addObjectsFromArray:@[
        CYMGActionRow(@"Apply Tweaks", @"apply", NO),
    ]];
    if (CYMGDebuggerAttached()) {
        [applying addObject:CYMGActionRow(@"Apply (FAKE)", @"apply-fake", NO)];
    }
    [applying addObjectsFromArray:@[
        CYMGActionRow(@"Reset MobileGestalt", @"reset-mg", YES),
        CYMGActionRow(@"Reset All Tweaks", @"reset-all", YES),
    ]];
    [sections addObject:@{ @"title": @"Applying", @"rows": applying }];

    NSMutableArray *artworkRows = [NSMutableArray arrayWithArray:@[
        CYMGPickerRow(@"Subtype", @"iphone", @"subtype"),
        CYMGSpecialToggleRow(@"Custom Device Name", @"pencil", @"custom-name"),
    ]];
    if (self.customDeviceName) {
        [artworkRows addObject:CYMGTextRow(@"Device Name", @"device-name")];
    }
    [sections addObject:@{ @"title": @"Device Artwork", @"rows": artworkRows }];

    NSMutableArray *software = [NSMutableArray array];
    if (version >= 19.0) [software addObject:CYMGToggleRow(@"Dynamic Island", @"platter.filled.top.iphone", @[@"YlEtTtHlNesRBMal1CqRaA"], @1)];
    if (version >= 18.0) [software addObject:CYMGToggleRow(@"Always On Display", @"sun.max", @[@"j8/Omm6s1lsmTDFsXjsBfA", @"2OOJf1VhaM7NxfRok3HbWQ"], @1)];
    if (version >= 18.0) [software addObject:CYMGToggleRow(@"AOD Vibrancy", @"rays", @[@"ykpu7qyhqFweVMKtxNylWA"], @1)];
    if (version >= 17.0) [software addObject:CYMGToggleRow(@"Charge Limit", @"battery.100.bolt", @[@"37NVydb//GP/GrhuTN+exg"], @1)];
    [software addObject:CYMGToggleRow(@"Boot Chime", @"speaker.wave.3", @[@"QHxt+hGLaBPbQJbXiUJX3w"], @1)];
    if (version >= 19.0) [software addObject:CYMGToggleRow(@"Liquid Glass LPM", @"app.background.dotted", @[@"SAGvsp6O6kAQ4fEfDJpC4Q"], @1)];
    [sections addObject:@{ @"title": @"Software-Oriented Features", @"rows": software }];

    NSMutableArray *hardware = [NSMutableArray array];
    if (version >= 18.0) [hardware addObject:CYMGToggleRow(@"Camera Control", @"camera.shutter.button", @[@"CwvKxM2cEogD3p+HYgaW0Q", @"oOV1jhJbdV3AddkcCg0AEA"], @1)];
    if (version >= 17.0) [hardware addObject:CYMGToggleRow(@"Action Button", @"button.vertical.left.press", @[@"cT44WE1EohiwRzhsZ8xEsw"], @1)];
    [hardware addObject:CYMGToggleRow(@"Crash Detection", @"car", @[@"HCzWusHQwZDea6nNhaKndw"], @1)];
    if (hasHomeButton) [hardware addObject:CYMGToggleRow(@"Enable Tap to Wake", @"hand.tap", @[@"yZf3GTRMGTuwSV/lD7Cagw"], @1)];
    if (version >= 19.0) [hardware addObject:CYMGToggleRow(@"Pulse Width Modulation", @"eye", @[@"6IejgN+1Fmu5/QrZFOIeNw"], @1)];
    [sections addObject:@{ @"title": @"Hardware-Oriented Features", @"rows": hardware }];

    NSMutableArray *eligibility = [NSMutableArray array];
    if (version >= 26.0) [eligibility addObject:CYMGToggleRow(@"Security Research Device UI", @"terminal", @[@"XYlJKKkj2hztRP1NWWnhlw"], @1)];
    [eligibility addObject:CYMGSpecialToggleRow(@"Disable Region Restrictions", @"globe", @"region")];
    if (version >= 18.1) [eligibility addObject:CYMGToggleRow(@"Apple Intelligence", @"apple.intelligence", @[@"A62OafQ85EJAiiqKn4agtg"], @1)];
    [eligibility addObject:CYMGPickerRow(@"Device Spoofing", @"iphone.gen3", @"product-type")];
    [sections addObject:@{ @"title": @"Eligibility", @"rows": eligibility }];

    NSMutableArray *ipad = [NSMutableArray arrayWithObjects:
        CYMGToggleRow(@"Allow Installing iPadOS Apps", @"plus.app", @[@"9MZ5AdH43csAUajl/dU+IQ"], @[@1, @2]),
        CYMGToggleRow(@"Apple Pencil Settings", @"pencil", @[@"yhHcB0iH0d1XzPO/CFd3ow"], @1), nil];
    if (isPad) [ipad addObject:CYMGToggleRow(@"Stage Manager", @"squares.leading.rectangle", @[@"qeaj75wk3HF4DwQ8qbIi7g"], @1)];
    [ipad addObject:CYMGSpecialToggleRow(@"iPadOS UI", @"ipad", @"trollpad")];
    [sections addObject:@{ @"title": @"iPadOS Features", @"rows": ipad }];

    [sections addObject:@{ @"title": @"Internal", @"rows": @[
        CYMGToggleRow(@"Internal Storage", @"externaldrive", @[@"LBJfwOEzExRxzlAnSuI7eg"], @1),
        CYMGSpecialToggleRow(@"Internal Features", @"gearshape", @"internal"),
        CYMGToggleRow(@"Metal HUD in All Apps", @"terminal", @[@"EqrsVvjcYDdxHBiQmGhAWw"], @1),
    ] }];

    NSString *springboard = @"/var/Managed Preferences/mobile/com.apple.springboard.plist";
    NSString *global = @"/var/Managed Preferences/mobile/.GlobalPreferences.plist";
    NSString *pasteboard = @"/var/Managed Preferences/mobile/com.apple.Pasteboard.plist";
    NSString *appStore = @"/var/Managed Preferences/mobile/com.apple.AppStore.plist";
    NSString *notes = @"/var/Managed Preferences/mobile/com.apple.mobilenotes.plist";
    NSString *backboard = @"/var/Managed Preferences/mobile/com.apple.backboardd.plist";

    [sections addObject:@{ @"title": @"UI Tweaks", @"rows": @[
        CYMGPreferenceRow(@"Hide Dynamic Island Completely", @"capsule", @"SBSuppressDynamicIslandCompletely", springboard),
        CYMGPreferenceRow(@"Authentication Debug Line", @"faceid", @"SBShowAuthenticationEngineeringUI", springboard),
        CYMGPreferenceRow(@"Show Build Version", @"number", @"UIStatusBarShowBuildVersion", global),
        CYMGPreferenceRow(@"Force RTL Layout", @"arrow.left", @"NSForceRightToLeftWritingDirection", global),
        CYMGPreferenceRow(@"Keyboard Character Flick", @"keyboard", @"GesturesEnabled", global),
        CYMGPreferenceRow(@"Disable Breadcrumbs", @"chevron.backward", @"SBNeverBreadcrumb", springboard),
    ] }];

    [sections addObject:@{ @"title": @"SpringBoard", @"rows": @[
        CYMGPreferenceRow(@"Disable Lock After Respring", @"lock.open", @"SBDontLockAfterCrash", springboard),
        CYMGPreferenceRow(@"Disable Low Battery Alerts", @"battery.25", @"SBHideLowPowerAlerts", springboard),
        CYMGPreferenceRow(@"Show Dynamic Island in Screenshots", @"camera", @"SBAlwaysShowSystemApertureInSnapshots", springboard),
        CYMGPreferenceRow(@"Play Sound on Paste", @"speaker.wave.2", @"PlaySoundOnPaste", pasteboard),
        CYMGPreferenceRow(@"System Paste Notifications", @"doc.on.clipboard", @"AnnounceAllPastes", pasteboard),
    ] }];

    [sections addObject:@{ @"title": @"Debug", @"rows": @[
        CYMGPreferenceRow(@"Metal HUD Debug", @"cpu", @"MetalForceHudEnabled", global),
        CYMGPreferenceRow(@"App Store Debug Gesture", @"hand.tap", @"debugGestureEnabled", appStore),
        CYMGPreferenceRow(@"Notes Debug Mode", @"note.text", @"DebugModeEnabled", notes),
        CYMGPreferenceRow(@"Show Touches", @"hand.point.up.left", @"BKDigitizerVisualizeTouches", backboard),
    ] }];

    self.sections = sections;
}

- (NSDictionary *)rowAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray *rows = self.sections[indexPath.section][@"rows"];
    return indexPath.row < (NSInteger)rows.count ? rows[indexPath.row] : nil;
}

- (NSString *)preferenceIDForRow:(NSDictionary *)row
{
    return [NSString stringWithFormat:@"%@|%@", row[@"path"], row[@"key"]];
}

- (void)loadPreferenceValues
{
    NSMutableDictionary<NSString *, NSMutableDictionary *> *cache = [NSMutableDictionary dictionary];
    for (NSDictionary *definition in CYMGAllPreferenceKeys()) {
        NSString *path = definition[@"path"];
        NSMutableDictionary *plist = cache[path];
        if (!plist) {
            plist = CYMGReadMutablePlist(path, nil) ?: [NSMutableDictionary dictionary];
            cache[path] = plist;
        }
        NSString *identifier = [NSString stringWithFormat:@"%@|%@", path, definition[@"key"]];
        self.preferenceValues[identifier] = @([plist[definition[@"key"]] boolValue]);
    }
}

- (BOOL)toggleValueForRow:(NSDictionary *)row
{
    NSString *source = row[@"source"];
    if ([source isEqualToString:@"mg"]) {
        NSString *firstKey = [row[@"keys"] firstObject];
        return [self.cacheExtra[firstKey] isEqual:row[@"enabledValue"]];
    }
    if ([source isEqualToString:@"preference"]) {
        return [self.preferenceValues[[self preferenceIDForRow:row]] boolValue];
    }

    NSString *identifier = row[@"id"];
    if ([identifier isEqualToString:@"custom-name"]) return self.customDeviceName;
    if ([identifier isEqualToString:@"region"]) {
        return [self.cacheExtra[@"h63QSdBCiT/z0WU6rdQv6Q"] isEqual:@"US"] &&
               [self.cacheExtra[@"zHeENZu+wbg7PUprwNwBWg"] isEqual:@"LL/A"];
    }
    if ([identifier isEqualToString:@"trollpad"]) {
        return [self.cacheExtra[@"uKc7FPnEO++lVhHWHFlGbQ"] integerValue] == 1;
    }
    if ([identifier isEqualToString:@"internal"]) {
        return [self cacheDataValueForKey:"EqrsVvjcYDdxHBiQmGhAWw"] == 1;
    }
    return NO;
}

- (uint64_t)cacheDataValueForKey:(const char *)key
{
    NSMutableData *cacheData = self.gestalt[@"CacheData"];
    if (![cacheData isKindOfClass:NSMutableData.class]) return 0;
    long offset = CYMGFindCacheDataOffset(key);
    if (offset < 0 || (NSUInteger)offset + sizeof(uint64_t) > cacheData.length) return 0;
    uint64_t value = 0;
    memcpy(&value, (const uint8_t *)cacheData.bytes + offset, sizeof(value));
    return value;
}

- (BOOL)setCacheDataValue:(uint64_t)value forKey:(const char *)key
{
    NSMutableData *cacheData = self.gestalt[@"CacheData"];
    if (![cacheData isKindOfClass:NSMutableData.class]) return NO;
    long offset = CYMGFindCacheDataOffset(key);
    if (offset < 0 || (NSUInteger)offset + sizeof(uint64_t) > cacheData.length) return NO;
    memcpy((uint8_t *)cacheData.mutableBytes + offset, &value, sizeof(value));
    return YES;
}

- (BOOL)setPreferenceRow:(NSDictionary *)row enabled:(BOOL)enabled error:(NSError **)error
{
    NSString *path = row[@"path"];
    NSMutableDictionary *plist = CYMGReadMutablePlist(path, nil);
    if (!plist) plist = [NSMutableDictionary dictionary];
    if (enabled) plist[row[@"key"]] = @YES;
    else [plist removeObjectForKey:row[@"key"]];

    if (!CYMGWritePlist(plist, path, YES, error)) return NO;
    self.preferenceValues[[self preferenceIDForRow:row]] = @(enabled);
    return YES;
}

- (BOOL)setToggleRow:(NSDictionary *)row enabled:(BOOL)enabled error:(NSError **)error
{
    NSString *source = row[@"source"];
    if ([source isEqualToString:@"mg"]) {
        for (NSString *key in row[@"keys"]) {
            if (enabled) self.cacheExtra[key] = row[@"enabledValue"];
            else [self.cacheExtra removeObjectForKey:key];
        }
        return YES;
    }
    if ([source isEqualToString:@"preference"]) {
        return [self setPreferenceRow:row enabled:enabled error:error];
    }

    NSString *identifier = row[@"id"];
    if ([identifier isEqualToString:@"custom-name"]) {
        self.customDeviceName = enabled;
        [self rebuildSections];
        [self.tableView reloadData];
        return YES;
    }
    if ([identifier isEqualToString:@"region"]) {
        if (enabled) {
            self.cacheExtra[@"h63QSdBCiT/z0WU6rdQv6Q"] = @"US";
            self.cacheExtra[@"zHeENZu+wbg7PUprwNwBWg"] = @"LL/A";
            [self showInformation:CYMGL(@"Warning")
                          message:CYMGL(@"Do not use region spoofing to bypass laws or service restrictions. You are responsible for how this setting is used.")];
        } else {
            [self.cacheExtra removeObjectForKey:@"h63QSdBCiT/z0WU6rdQv6Q"];
            [self.cacheExtra removeObjectForKey:@"zHeENZu+wbg7PUprwNwBWg"];
        }
        return YES;
    }
    if ([identifier isEqualToString:@"trollpad"]) {
        uint64_t cacheValue = enabled ? 3 : 1;
        if (![self setCacheDataValue:cacheValue forKey:"mtrAoWJ3gsq+I90ZnQ0vQw"]) {
            if (error) *error = CYMGMakeError(CYMGL(@"Could not locate the iPadOS UI value in CacheData."));
            return NO;
        }
        NSArray *keys = @[
            @"uKc7FPnEO++lVhHWHFlGbQ", @"mG0AnH/Vy1veoqoLRAIgTA",
            @"UCG5MkVahJxG1YULbbd5Bg", @"ZYqko/XM5zD3XBfN5RmaXA",
            @"nVh/gwNpy7Jv1NOk00CMrw", @"qeaj75wk3HF4DwQ8qbIi7g",
        ];
        for (NSString *key in keys) {
            if (enabled) self.cacheExtra[key] = @1;
            else [self.cacheExtra removeObjectForKey:key];
        }
        if (enabled) {
            [self showInformation:CYMGL(@"High-Risk Feature")
                          message:CYMGL(@"iPadOS UI can cause severe instability or a boot loop. Do not use it with an alphanumeric passcode, and do not disable Show Dock in Stage Manager.")];
        }
        return YES;
    }
    if ([identifier isEqualToString:@"internal"]) {
        uint64_t value = enabled ? 1 : 0;
        const char *keys[] = {
            "EqrsVvjcYDdxHBiQmGhAWw",
            "Oji6HRoPi7rH7HPdWVakuw",
            "LBJfwOEzExRxzlAnSuI7eg",
        };
        for (NSUInteger i = 0; i < 3; i++) {
            if (![self setCacheDataValue:value forKey:keys[i]]) {
                if (error) *error = CYMGMakeError(CYMGL(@"Could not locate an Internal Features value in CacheData."));
                return NO;
            }
        }
        return YES;
    }
    return NO;
}

- (void)switchChanged:(UISwitch *)sender
{
    NSInteger section = sender.tag / 1000;
    NSInteger rowIndex = sender.tag % 1000;
    if (section >= (NSInteger)self.sections.count) return;
    NSArray *rows = self.sections[section][@"rows"];
    if (rowIndex >= (NSInteger)rows.count) return;

    NSDictionary *row = rows[rowIndex];
    NSError *error = nil;
    if (![self setToggleRow:row enabled:sender.isOn error:&error]) {
        sender.on = !sender.isOn;
        [self showError:CYMGL(@"Failed to update setting") error:error];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [self.sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return CYMGL(self.sections[section][@"title"]);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    NSString *title = self.sections[section][@"title"];
    if ([title isEqualToString:@"Applying"]) {
        return CYMGL(CYMGDebuggerAttached()
            ? @"Apply (FAKE) writes com.apple.MobileGestalt.test.plist without modifying the live cache. Apply Tweaks uses the original live-write and respring flow."
            : @"MobileGestalt changes are staged until Apply Tweaks. Managed Preference switches apply immediately. A respring is normally required.");
    }
    return nil;
}

- (NSString *)subtypeDisplayName
{
    NSDictionary<NSNumber *, NSString *> *names = @{
        @2436: @"iPhone 14 Pro",
        @2796: @"iPhone 14 Pro Max",
        @2976: @"iPhone 15 Pro Max",
        @2622: @"iPhone 16 Pro",
        @2868: @"iPhone 16 Pro Max",
        @2736: @"iPhone Air",
    };
    NSString *name = names[@(self.subtype)];
    if (name.length > 0) return CYMGL(name);
    if (self.subtype == self.originalSubtype) {
        return [NSString stringWithFormat:CYMGL(@"Original (%ld)"), (long)self.subtype];
    }
    return [NSString stringWithFormat:@"%ld", (long)self.subtype];
}

- (NSString *)productTypeDisplayName
{
    if (self.productType.length == 0 || [self.productType isEqualToString:CYMGMachineName()]) {
        return CYMGL(@"Default");
    }
    for (NSDictionary *option in self.productTypeOptions) {
        if ([option[@"value"] isEqual:self.productType]) {
            return CYMGL(option[@"title"]);
        }
    }
    return self.productType;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *row = [self rowAtIndexPath:indexPath];
    NSString *kind = row[@"kind"];
    NSString *reuse = [@"MG-" stringByAppendingString:kind ?: @"row"];
    UITableViewCellStyle style = [kind isEqualToString:CYMGKindPicker]
        ? UITableViewCellStyleValue1 : UITableViewCellStyleDefault;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:reuse];

    cell.textLabel.text = CYMGL(row[@"title"]);
    cell.textLabel.textColor = UIColor.labelColor;
    cell.imageView.image = [row[@"icon"] length]
        ? [UIImage systemImageNamed:row[@"icon"]] : nil;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    if ([kind isEqualToString:CYMGKindToggle]) {
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = [self toggleValueForRow:row];
        toggle.tag = indexPath.section * 1000 + indexPath.row;
        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([kind isEqualToString:CYMGKindPicker]) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if ([row[@"id"] isEqualToString:@"subtype"]) {
            cell.detailTextLabel.text = [self subtypeDisplayName];
        } else {
            cell.detailTextLabel.text = [self productTypeDisplayName];
        }
    } else if ([kind isEqualToString:CYMGKindText]) {
        UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 190, 34)];
        field.text = self.deviceName;
        field.placeholder = CYMGL(@"Device Name");
        field.textAlignment = NSTextAlignmentRight;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.returnKeyType = UIReturnKeyDone;
        field.delegate = self;
        [field addTarget:self action:@selector(deviceNameChanged:) forControlEvents:UIControlEventEditingChanged];
        cell.accessoryView = field;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([kind isEqualToString:CYMGKindAction]) {
        cell.textLabel.textColor = [row[@"destructive"] boolValue]
            ? UIColor.systemRedColor : self.view.tintColor;
    }
    BOOL enabled = self.loaded || [row[@"id"] isEqualToString:@"prepare"];
    cell.userInteractionEnabled = enabled;
    cell.textLabel.enabled = enabled;
    cell.imageView.alpha = enabled ? 1.0 : 0.35;
    cell.accessoryView.userInteractionEnabled = enabled;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = [self rowAtIndexPath:indexPath];
    NSString *kind = row[@"kind"];
    NSString *identifier = row[@"id"];
    if ([kind isEqualToString:CYMGKindAction]) {
        if ([identifier isEqualToString:@"prepare"]) [self prepareAccess];
        else if ([identifier isEqualToString:@"apply"]) [self applyGestalt];
        else if ([identifier isEqualToString:@"apply-fake"]) [self applyFakeGestalt];
        else if ([identifier isEqualToString:@"reset-mg"]) [self confirmMobileGestaltReset];
        else if ([identifier isEqualToString:@"reset-all"]) [self confirmAllTweaksReset];
    } else if ([kind isEqualToString:CYMGKindPicker]) {
        if ([identifier isEqualToString:@"subtype"]) [self presentSubtypePicker];
        else if ([identifier isEqualToString:@"product-type"]) [self presentProductTypePicker];
    }
}

- (void)prepareAccess
{
    __weak typeof(self) weakSelf = self;
    settings_prepare_mobilegestalt_access(self, ^(BOOL success) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !success) return;

        NSError *error = nil;
        self.loaded = [self loadCurrentGestalt:&error];
        self.preferenceValues = [NSMutableDictionary dictionary];
        [self loadPreferenceValues];
        [self rebuildSections];
        self.navigationItem.rightBarButtonItem.enabled = self.loaded;
        [self.tableView reloadData];
        if (!self.loaded) {
            [self showError:CYMGL(@"Failed to load MobileGestalt") error:error];
        }
    });
}

- (void)deviceNameChanged:(UITextField *)field
{
    self.deviceName = field.text ?: @"";
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

- (NSArray<NSDictionary *> *)subtypeOptions
{
    NSMutableArray *options = [NSMutableArray arrayWithObject:@{
        @"title": [NSString stringWithFormat:CYMGL(@"Original (%ld)"), (long)self.originalSubtype],
        @"value": @(self.originalSubtype),
    }];
    NSArray *supported = @[@"iPhone15,2", @"iPhone15,3", @"iPhone15,4", @"iPhone15,5",
                           @"iPhone16,1", @"iPhone16,2", @"iPhone17,3", @"iPhone17,4",
                           @"iPhone17,1", @"iPhone17,2", @"iPhone18,3", @"iPhone18,1",
                           @"iPhone18,2", @"iPhone17,5"];
    if ([supported containsObject:CYMGMachineName()] && CYMGSystemVersion() < 19.0) {
        [options addObject:@{ @"title": @"Disable Dynamic Island", @"value": @2436 }];
    }
    [options addObjectsFromArray:@[
        @{ @"title": @"iPhone 14 Pro", @"value": @2436 },
        @{ @"title": @"iPhone 14 Pro Max", @"value": @2796 },
        @{ @"title": @"iPhone 15 Pro Max", @"value": @2976 },
    ]];
    if (CYMGSystemVersion() >= 18.0) {
        [options addObjectsFromArray:@[
            @{ @"title": @"iPhone 16 Pro", @"value": @2622 },
            @{ @"title": @"iPhone 16 Pro Max", @"value": @2868 },
        ]];
    }
    if (CYMGSystemVersion() >= 26.0) {
        [options addObject:@{ @"title": @"iPhone Air", @"value": @2736 }];
    }
    if (CYMGHasHomeButton()) {
        [options addObject:@{ @"title": @"iPhone X Gestures", @"value": @2436 }];
    }
    return options;
}

- (NSArray<NSDictionary *> *)productTypeOptions
{
    NSMutableArray *options = [NSMutableArray arrayWithObject:@{
        @"title": @"Default", @"value": CYMGMachineName(),
    }];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        if (CYMGSystemVersion() >= 17.4) {
            [options addObjectsFromArray:@[
                @{ @"title": @"iPad Pro 11-inch (M4)", @"value": @"iPad16,3" },
                @{ @"title": @"iPad Pro 11-inch (M4, Cellular)", @"value": @"iPad16,4" },
            ]];
        }
        [options addObjectsFromArray:@[
            @{ @"title": @"iPad Pro 11-inch (4th Gen)", @"value": @"iPad14,3" },
            @{ @"title": @"iPad Pro 11-inch (4th Gen, Cellular)", @"value": @"iPad14,4" },
        ]];
    } else {
        [options addObjectsFromArray:@[
            @{ @"title": @"iPhone 15 Pro", @"value": @"iPhone16,1" },
            @{ @"title": @"iPhone 15 Pro Max", @"value": @"iPhone16,2" },
        ]];
        if (CYMGSystemVersion() >= 18.0) {
            [options addObjectsFromArray:@[
                @{ @"title": @"iPhone 16", @"value": @"iPhone17,3" },
                @{ @"title": @"iPhone 16 Plus", @"value": @"iPhone17,4" },
                @{ @"title": @"iPhone 16 Pro", @"value": @"iPhone17,1" },
                @{ @"title": @"iPhone 16 Pro Max", @"value": @"iPhone17,2" },
            ]];
        }
        if (CYMGSystemVersion() >= 19.0) {
            [options addObjectsFromArray:@[
                @{ @"title": @"iPhone 17", @"value": @"iPhone18,3" },
                @{ @"title": @"iPhone 17 Pro", @"value": @"iPhone18,1" },
                @{ @"title": @"iPhone 17 Pro Max", @"value": @"iPhone18,2" },
                @{ @"title": @"iPhone Air", @"value": @"iPhone18,4" },
            ]];
        }
    }
    return options;
}

- (void)presentOptions:(NSArray<NSDictionary *> *)options
                  title:(NSString *)title
              selection:(void (^)(id value))selection
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:CYMGL(title)
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *option in options) {
        [sheet addAction:[UIAlertAction actionWithTitle:CYMGL(option[@"title"])
                                                 style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *action) {
            selection(option[@"value"]);
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:CYMGL(@"Cancel")
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentSubtypePicker
{
    [self presentOptions:self.subtypeOptions title:@"Subtype" selection:^(NSNumber *value) {
        self.subtype = value.integerValue;
        [self.tableView reloadData];
    }];
}

- (void)presentProductTypePicker
{
    [self presentOptions:self.productTypeOptions title:@"Device Spoofing" selection:^(NSString *value) {
        self.productType = value;
        [self.tableView reloadData];
        [self showInformation:CYMGL(@"Device Spoofing")
                      message:CYMGL(@"Only spoof the device model when required for Apple Intelligence. Spoofing may break Face ID or other hardware-dependent features.")];
    }];
}

- (void)applyGestalt
{
    [self applyGestaltToPath:CYMGCurrentPath fake:NO];
}

- (void)applyFakeGestalt
{
    [self applyGestaltToPath:CYMGTestPath fake:YES];
}

- (void)applyGestaltToPath:(NSString *)path fake:(BOOL)fake
{
    if (!self.loaded) {
        [self showInformation:CYMGL(@"MobileGestalt Unavailable")
                      message:CYMGL(@"Run the kernel chain and filesystem sandbox step, then reopen this page.")];
        return;
    }
    if (self.cacheExtra.count == 0) {
        [self showInformation:CYMGL(@"Invalid MobileGestalt")
                      message:CYMGL(@"CacheExtra is empty. No changes were written.")];
        return;
    }

    if (self.productType.length > 0) self.cacheExtra[@"h9jDsbgj7xIVeIQ8S3/X3Q"] = self.productType;
    self.artwork[@"ArtworkDeviceSubType"] = @(self.subtype);
    if (self.customDeviceName && self.deviceName.length > 0) {
        self.artwork[@"ArtworkDeviceProductDescription"] = self.deviceName;
    }

    NSError *error = nil;
    if (!CYMGWritePlist(self.gestalt, path, fake, &error)) {
        [self showError:CYMGL(fake
            ? @"Failed to write test MobileGestalt"
            : @"Failed to overwrite MobileGestalt") error:error];
        return;
    }

    UIAlertController *alert = nil;
    if (fake) {
        log_user("[MG] Test MobileGestalt written to %s; live cache unchanged.\n",
                 path.UTF8String);
        alert = [UIAlertController
            alertControllerWithTitle:CYMGL(@"Test MobileGestalt Written")
                             message:CYMGL(@"The test MobileGestalt file was written successfully. The live system cache was not modified.")
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:CYMGL(@"OK")
                                                style:UIAlertActionStyleDefault
                                              handler:nil]];
    } else {
        log_user("[MG] MobileGestalt changes applied. Respring required.\n");
        alert = [UIAlertController
            alertControllerWithTitle:CYMGL(@"MobileGestalt Applied")
                             message:CYMGL(@"The MobileGestalt file was updated successfully. Respring to apply the changes.")
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:CYMGL(@"Later")
                                                style:UIAlertActionStyleCancel
                                              handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:CYMGL(@"Respring")
                                                style:UIAlertActionStyleDestructive
                                              handler:^(__unused UIAlertAction *action) {
            settings_request_respring_from_controller(self);
        }]];
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmMobileGestaltReset
{
    NSString *message = CYMGDebuggerAttached()
        ? @"This loads the saved MobileGestalt backup into the editor without changing any Managed Preferences. Use Apply (FAKE) to compare it, or Apply Tweaks to write it live."
        : @"This loads the saved MobileGestalt backup into the editor without changing any Managed Preferences. Tap Apply Tweaks afterward to write it live.";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CYMGL(@"Reset MobileGestalt?")
                         message:CYMGL(message)
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CYMGL(@"Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CYMGL(@"Reset MobileGestalt")
                                            style:UIAlertActionStyleDestructive
                                          handler:^(__unused UIAlertAction *action) {
        [self resetTweaksRemovingPreferences:NO];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmAllTweaksReset
{
    NSString *message = CYMGDebuggerAttached()
        ? @"This reset affects both MobileGestalt and other Managed Preferences associated with this editor. The saved MobileGestalt backup will be loaded for the next Apply, while the related Managed Preferences will be removed immediately. Use Apply (FAKE) to compare the restored MobileGestalt, or Apply Tweaks to write it live."
        : @"This reset affects both MobileGestalt and other Managed Preferences associated with this editor. The saved MobileGestalt backup will be loaded for the next Apply, while the related Managed Preferences will be removed immediately. Tap Apply Tweaks afterward to write the restored MobileGestalt live.";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CYMGL(@"Reset All Tweaks?")
                         message:CYMGL(message)
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CYMGL(@"Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CYMGL(@"Reset All Tweaks")
                                            style:UIAlertActionStyleDestructive
                                          handler:^(__unused UIAlertAction *action) {
        [self resetTweaksRemovingPreferences:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetTweaksRemovingPreferences:(BOOL)removePreferences
{
    NSError *error = nil;
    NSMutableDictionary *backup = CYMGReadMutablePlist(CYMGBackupPath(), &error);
    if (!backup) {
        [self showError:CYMGL(@"Failed to restore MobileGestalt backup") error:error];
        return;
    }

    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    if (removePreferences) {
        NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *keysByPath = [NSMutableDictionary dictionary];
        for (NSDictionary *definition in CYMGAllPreferenceKeys()) {
            NSMutableArray *keys = keysByPath[definition[@"path"]];
            if (!keys) {
                keys = [NSMutableArray array];
                keysByPath[definition[@"path"]] = keys;
            }
            [keys addObject:definition[@"key"]];
        }

        [keysByPath enumerateKeysAndObjectsUsingBlock:^(NSString *path,
                                                        NSMutableArray<NSString *> *keys,
                                                        __unused BOOL *stop) {
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) return;
            NSMutableDictionary *plist = CYMGReadMutablePlist(path, nil);
            if (!plist) return;
            for (NSString *key in keys) [plist removeObjectForKey:key];
            NSError *writeError = nil;
            if (!CYMGWritePlist(plist, path, NO, &writeError)) {
                [failures addObject:[NSString stringWithFormat:@"%@: %@", path,
                                     writeError.localizedDescription ?: @"write failed"]];
            }
        }];
    }

    self.gestalt = backup;
    self.cacheExtra = backup[@"CacheExtra"];
    self.artwork = self.cacheExtra[@"oPeik/9e8lQWMszEjbPzng"];
    if (![self.artwork isKindOfClass:NSMutableDictionary.class]) {
        self.artwork = [NSMutableDictionary dictionary];
        self.cacheExtra[@"oPeik/9e8lQWMszEjbPzng"] = self.artwork;
    }
    self.subtype = [self.artwork[@"ArtworkDeviceSubType"] integerValue];
    self.productType = [self.cacheExtra[@"h9jDsbgj7xIVeIQ8S3/X3Q"] isKindOfClass:NSString.class]
        ? self.cacheExtra[@"h9jDsbgj7xIVeIQ8S3/X3Q"] : CYMGMachineName();
    self.customDeviceName = NO;
    [self.preferenceValues removeAllObjects];
    [self loadPreferenceValues];
    [self rebuildSections];
    [self.tableView reloadData];

    if (failures.count > 0) {
        [self showInformation:CYMGL(@"Reset Partially Completed")
                      message:[failures componentsJoinedByString:@"\n"]];
    } else {
        NSString *message = nil;
        if (removePreferences) {
            message = CYMGDebuggerAttached()
                ? @"The MobileGestalt backup is loaded and the related Managed Preferences were removed. Use Apply (FAKE) for comparison, or Apply Tweaks to restore MobileGestalt live."
                : @"The MobileGestalt backup is loaded and the related Managed Preferences were removed. Tap Apply Tweaks to restore MobileGestalt live.";
        } else {
            message = CYMGDebuggerAttached()
                ? @"The MobileGestalt backup is loaded. Managed Preferences were not changed. Use Apply (FAKE) for comparison, or Apply Tweaks to restore it live."
                : @"The MobileGestalt backup is loaded. Managed Preferences were not changed. Tap Apply Tweaks to restore it live.";
        }
        [self showInformation:CYMGL(removePreferences ? @"All Tweaks Reset Prepared" : @"MobileGestalt Reset Prepared")
                          message:CYMGL(message)];
    }
}

- (void)openFileTools
{
    CYMGFileViewController *controller = [[CYMGFileViewController alloc]
        initWithCurrentGestalt:self.gestalt ?: [NSMutableDictionary dictionary]];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)showInformation:(NSString *)title message:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:CYMGL(@"OK")
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showError:(NSString *)title error:(NSError *)error
{
    NSString *message = error.localizedDescription ?: CYMGL(@"Unknown error");
    if (access(CYMGCurrentPath.fileSystemRepresentation, R_OK) != 0) {
        message = [message stringByAppendingFormat:@"\n\n%@",
                   CYMGL(@"Run the kernel chain and filesystem sandbox step, then reopen this page.")];
    }
    [self showInformation:title message:message];
}

@end
