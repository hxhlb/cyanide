#import "TweakCompatibility.h"
#import "SettingsViewController.h"
#import "installer/Package.h"

NSString * const CyanideConflictGroupStatusBar = @"status-bar";
NSString * const CyanideConflictGroupHomeLayout = @"home-layout";
NSString * const CyanideConflictGroupThemeEngine = @"theme-engine";
NSString * const CyanideConflictGroupFloatingScenes = @"floating-scenes";
NSString * const CyanideConflictGroupWallpaper = @"wallpaper";
NSString * const CyanideConflictGroupAppLibrary = @"app-library";

@interface CyanideTweakResourceRecord ()
@property (nonatomic, readwrite, copy) NSString *packageIdentifier;
@property (nonatomic, readwrite, copy, nullable) NSString *enabledKey;
@property (nonatomic, readwrite, copy) NSString *displayName;
@property (nonatomic, readwrite, copy) NSString *resourceSummary;
@end

@implementation CyanideTweakResourceRecord
@end

static CyanideTweakResourceRecord *cyanide_tweak_record(NSString *identifier,
                                                         NSString * _Nullable enabledKey,
                                                         NSString *name,
                                                         NSString *resources)
{
    CyanideTweakResourceRecord *record = [CyanideTweakResourceRecord new];
    record.packageIdentifier = identifier;
    record.enabledKey = enabledKey;
    record.displayName = name;
    record.resourceSummary = resources;
    return record;
}

NSArray<CyanideTweakResourceRecord *> *cyanide_tweak_resource_registry(void)
{
    static NSArray<CyanideTweakResourceRecord *> *records;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        records = @[
            cyanide_tweak_record(@"com.darksword.statbar", kSettingsStatBarEnabled, @"StatBar", @"SpringBoard status-bar overlay UIWindow and metric refresh loop"),
            cyanide_tweak_record(@"com.darksword.nsbar", kSettingsNSBarEnabled, @"NSBar", @"SpringBoard status-bar overlay UIWindow and network-speed refresh loop"),
            cyanide_tweak_record(@"com.darksword.nicebarlite", kSettingsNiceBarLiteEnabled, @"NiceBar Lite", @"SpringBoard status-bar overlay UIWindow, weather and system text slots"),
            cyanide_tweak_record(@"com.darksword.rssidisplay", kSettingsRSSIDisplayEnabled, @"Signal Display", @"STUIStatusBar Wi-Fi and cellular signal views"),
            cyanide_tweak_record(@"com.darksword.sbcustomizer", kSettingsSBCEnabled, @"SpringBoard Customizer", @"SBIconController Home Screen and Dock grid configuration"),
            cyanide_tweak_record(@"com.darksword.powercuff", kSettingsPowercuffEnabled, @"Powercuff", @"CPMSHelper power and thermal policy level"),
            cyanide_tweak_record(@"com.darksword.axonlite", kSettingsAxonLiteEnabled, @"Axon Lite", @"SpringBoard notification list filters and Axon overlay"),
            cyanide_tweak_record(@"com.darksword.typebanner", kSettingsTypeBannerEnabled, @"TypeBanner", @"SpringBoard typing-indicator overlay and MobileSMS keepalive"),
            cyanide_tweak_record(@"com.darksword.notificationisland", kSettingsNotificationIslandEnabled, @"Notification Island", @"ActivityKit and Dynamic Island notification presentation"),
            cyanide_tweak_record(@"com.darksword.ipadecryptor", nil, @"IPA Decryptor", @"Installed app Mach-O reads and decrypted IPA output in Documents"),
            cyanide_tweak_record(@"com.darksword.stagestrip", kSettingsStageStripEnabled, @"Dynamic Stage Lite", @"SpringBoard hosted application scenes and floating scene window"),
            cyanide_tweak_record(@"com.darksword.mwlite", kSettingsMWLiteEnabled, @"MilkyWay Lite", @"SpringBoard hosted application scenes, floating windows and control bar"),
            cyanide_tweak_record(@"com.darksword.locationsim", nil, @"Location Simulator", @"CLSimulationManager location state in selected host processes"),
            cyanide_tweak_record(@"com.darksword.snowboardlite", kSettingsSnowBoardLiteEnabled, @"SnowBoard Lite", @"SBIconView icon image-provider theme state"),
            cyanide_tweak_record(@"com.darksword.livewp", kSettingsLiveWPEnabled, @"LiveWP", @"AVPlayerLayer in Home Screen and Cover Sheet wallpaper windows"),
            cyanide_tweak_record(@"com.banana.metal-lock-light", kSettingsMetalLockLightEnabled, @"Metal Lock Light", @"CAMetalLayer renderer in the lock-screen wallpaper window"),
            cyanide_tweak_record(@"com.banana.mood-wallpaper", kSettingsMoodWallpaperEnabled, @"Mood Wallpaper", @"Motion-driven UIImageView layers in Home Screen and lock-screen wallpaper windows"),
            cyanide_tweak_record(@"com.darksword.layoutextras", kSettingsLayoutExtrasEnabled, @"Home Layout Extras", @"Home Screen and Dock layout insets plus icon transforms"),
            cyanide_tweak_record(@"com.darksword.gravitylite", kSettingsGravityLiteEnabled, @"Gravity Lite", @"UIKit Dynamics ownership of Home Screen icons and optional Dock icons"),
            cyanide_tweak_record(@"com.darksword.watchlayout", kSettingsWatchLayoutEnabled, @"Watch Layout", @"Vertically scrolling Home Screen icon overlay with circular containers"),
            cyanide_tweak_record(@"com.darksword.cylinderlite", kSettingsCylinderLiteEnabled, @"Cylinder Lite", @"SBIconScrollView page tracking and SBIconListView Core Animation transitions"),
            cyanide_tweak_record(@"com.darksword.appdowngrade", nil, @"App Downgrade", @"App Store metadata lookup and StoreKitUI historical-version request"),
            cyanide_tweak_record(@"com.darksword.appupdateblocking", nil, @"App Update Blocking", @"installd-owned per-application App Store update marker"),
            cyanide_tweak_record(@"com.darksword.debugoverlay", kSettingsDebugOverlayEnabled, @"UIKit Debug Overlay", @"UIDebuggingInformationOverlay availability and status-bar gesture"),
            cyanide_tweak_record(@"com.darksword.upsidedown", kSettingsUpsideDownEnabled, @"Enable Upside Down", @"SpringBoard Home, Cover Sheet and scene orientation methods"),
            cyanide_tweak_record(@"com.darksword.appswitchergrid", kSettingsAppSwitcherGridEnabled, @"App Switcher Grid", @"SBAppSwitcherSettings style and optional iPad switching behavior"),
            cyanide_tweak_record(@"com.darksword.floatingdock", kSettingsFloatingDockEnabled, @"iPad Dock", @"SBFloatingDockController scene participant and App Library pod"),
            cyanide_tweak_record(@"com.darksword.quickloader", kSettingsQuickLoaderEnabled, @"QuickLoader", @"Long-lived QuickJS runtime; script-owned resources are dynamic"),
            cyanide_tweak_record(@"com.darksword.fastlockx-lite", kSettingsFastLockXLiteEnabled, @"FastLockX Lite", @"Lock-screen biometric, AOD, timer, media, flashlight and power behavior"),
            cyanide_tweak_record(@"com.darksword.nanoregistry", nil, @"Nano Registry", @"Watch pairing compatibility registry and MobileAsset caches"),
            cyanide_tweak_record(@"com.darksword.callrecording-sound", nil, @"Call Recording Sound", @"CallServices disclosure-sound files and Cyanide backups"),
            cyanide_tweak_record(@"com.darksword.hide-home-bar", nil, @"Hide Home Bar", @"MaterialKit Assets.car first-page memory contents"),
            cyanide_tweak_record(@"com.darksword.ota-block", nil, @"OTA Updates", @"launchd disabled.plist, OTA preferences and MobileGestalt OTA cache"),
            cyanide_tweak_record(@"com.darksword.disable-app-library", kSettingsDSDisableAppLibrary, @"Disable App Library", @"SBIconController trailing App Library controllers"),
            cyanide_tweak_record(@"com.darksword.disable-icon-flyin", kSettingsDSDisableIconFlyIn, @"Disable Icon Fly-In", @"SBCoverSheetPresentationManager icon animation state"),
            cyanide_tweak_record(@"com.darksword.zero-wake-animation", kSettingsDSZeroWakeAnimation, @"Zero Wake Animation", @"SBScreenWakeAnimationController wake duration and speed settings"),
            cyanide_tweak_record(@"com.darksword.zero-backlight-fade", kSettingsDSZeroBacklightFade, @"Zero Backlight Fade", @"SpringBoard wake settings backlight fade duration"),
            cyanide_tweak_record(@"com.darksword.double-tap-to-lock", kSettingsDSDoubleTapToLock, @"Double-Tap to Lock", @"Home Screen and root-window gestures targeting SpringBoard lock action"),
            cyanide_tweak_record(@"com.darksword.drag-coefficient", kSettingsDSDragCoefficientEnabled, @"Drag Coefficient", @"UIKitCore _UIAnimationDragCoefficient behavior"),

            // Internal runtime entries do not appear in PackageCatalog but must
            // still participate in compatibility decisions and documentation.
            cyanide_tweak_record(@"com.darksword.themer", kSettingsThemerEnabled, @"Icon Theme Engine", @"SBIconView icon image-provider theme state"),
            cyanide_tweak_record(@"com.darksword.repotweaks", kSettingsRepoTweaksEnabled, @"RepoTweaks", @"Downloaded JavaScript runtime; script-owned resources are dynamic"),
            cyanide_tweak_record(@"com.darksword.killallapps", nil, @"Kill All Apps", @"SBApplicationController running-application termination"),
        ];
    });
    return records;
}

static NSArray<NSDictionary<NSString *, id> *> *cyanide_tweak_conflict_groups(void)
{
    static NSArray<NSDictionary<NSString *, id> *> *groups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        groups = @[
            @{ @"identifier": CyanideConflictGroupStatusBar,
               @"title": @"Status Bar Overlays",
               @"keys": @[ kSettingsStatBarEnabled, kSettingsNSBarEnabled, kSettingsNiceBarLiteEnabled ],
               @"reason": @"These tweaks each own a SpringBoard status-bar overlay window. Deactivate the active one before installing another." },
            @{ @"identifier": CyanideConflictGroupHomeLayout,
               @"title": @"Home Screen Layout",
               @"keys": @[ kSettingsSBCEnabled, kSettingsLayoutExtrasEnabled, kSettingsGravityLiteEnabled, kSettingsWatchLayoutEnabled, kSettingsCylinderLiteEnabled ],
               @"reason": @"These tweaks each own Home Screen icon layout or live icon frames. Deactivate the active one before installing another." },
            @{ @"identifier": CyanideConflictGroupThemeEngine,
               @"title": @"Icon Theme Engines",
               @"keys": @[ kSettingsThemerEnabled, kSettingsSnowBoardLiteEnabled ],
               @"reason": @"These tweaks share the SpringBoard icon theme backend. Deactivate the active theme engine before installing another." },
            @{ @"identifier": CyanideConflictGroupFloatingScenes,
               @"title": @"Floating Windows",
               @"keys": @[ kSettingsStageStripEnabled, kSettingsMWLiteEnabled ],
               @"reason": @"These tweaks both own SpringBoard floating-scene state. Deactivate the active one before installing another." },
            @{ @"identifier": CyanideConflictGroupWallpaper,
               @"title": @"Wallpaper Effects",
               @"keys": @[ kSettingsLiveWPEnabled, kSettingsMetalLockLightEnabled, kSettingsMoodWallpaperEnabled ],
               @"reason": @"These tweaks each own SpringBoard wallpaper layers. Deactivate the active wallpaper effect before installing another." },
            @{ @"identifier": CyanideConflictGroupAppLibrary,
               @"title": @"App Library",
               @"keys": @[ kSettingsDSDisableAppLibrary, kSettingsFloatingDockEnabled ],
               @"reason": @"iPad Dock requires the App Library pod that Disable App Library removes. Deactivate the active tweak before installing the other." },
        ];
    });
    return groups;
}

CyanideTweakResourceRecord *cyanide_tweak_resource_record_for_identifier(NSString *identifier)
{
    if (identifier.length == 0) return nil;
    for (CyanideTweakResourceRecord *record in cyanide_tweak_resource_registry()) {
        if ([record.packageIdentifier isEqualToString:identifier]) return record;
    }
    return nil;
}

NSArray<NSString *> *cyanide_missing_native_tweak_registry_identifiers(NSArray<Package *> *packages)
{
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (Package *package in packages) {
        if (package.kind == PackageInstallKindRepoTweak) continue;
        if (!cyanide_tweak_resource_record_for_identifier(package.identifier)) {
            [missing addObject:package.identifier ?: @"(missing identifier)"];
        }
    }
    return missing;
}

NSString *cyanide_tweak_enabled_key_for_package(Package *package)
{
    if (package.enabledKey.length > 0) return package.enabledKey;
    return package.repoNativeEnabledKey;
}

BOOL cyanide_tweak_package_has_conflicts(Package *package)
{
    return cyanide_conflicting_enabled_keys(cyanide_tweak_enabled_key_for_package(package)).count > 0;
}

static NSDictionary<NSString *, id> * _Nullable cyanide_tweak_conflict_group_for_identifier(NSString *groupIdentifier)
{
    if (groupIdentifier.length == 0) return nil;
    for (NSDictionary<NSString *, id> *group in cyanide_tweak_conflict_groups()) {
        if ([group[@"identifier"] isEqualToString:groupIdentifier]) return group;
    }
    return nil;
}

NSArray<NSString *> *cyanide_tweak_conflict_group_identifiers(void)
{
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *group in cyanide_tweak_conflict_groups()) {
        [identifiers addObject:group[@"identifier"]];
    }
    return identifiers;
}

NSString *cyanide_tweak_conflict_group_title(NSString *groupIdentifier)
{
    NSString *title = cyanide_tweak_conflict_group_for_identifier(groupIdentifier)[@"title"];
    return title.length > 0 ? NSLocalizedString(title, nil) : nil;
}

NSArray<NSString *> *cyanide_tweak_conflict_group_enabled_keys(NSString *groupIdentifier)
{
    return cyanide_tweak_conflict_group_for_identifier(groupIdentifier)[@"keys"] ?: @[];
}

NSString *cyanide_tweak_primary_conflict_group_identifier(NSString * _Nullable enabledKey)
{
    if (enabledKey.length == 0) return nil;
    for (NSDictionary<NSString *, id> *group in cyanide_tweak_conflict_groups()) {
        if ([group[@"keys"] containsObject:enabledKey]) return group[@"identifier"];
    }
    return nil;
}

static NSArray<NSDictionary<NSString *, id> *> *cyanide_tweak_conflict_groups_for_key(NSString * _Nullable enabledKey)
{
    if (enabledKey.length == 0) return @[];
    NSMutableArray<NSDictionary<NSString *, id> *> *matches = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *group in cyanide_tweak_conflict_groups()) {
        if ([group[@"keys"] containsObject:enabledKey]) [matches addObject:group];
    }
    return matches;
}

static BOOL cyanide_tweak_participates_in_conflict_group(NSUserDefaults *defaults,
                                                         NSString *enabledKey,
                                                         NSDictionary<NSString *, id> *group)
{
    (void)defaults;
    (void)enabledKey;
    (void)group;
    return YES;
}

NSArray<NSString *> *cyanide_conflicting_enabled_keys(NSString * _Nullable enabledKey)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableOrderedSet<NSString *> *peers = [NSMutableOrderedSet orderedSet];
    for (NSDictionary<NSString *, id> *group in cyanide_tweak_conflict_groups_for_key(enabledKey)) {
        if (!cyanide_tweak_participates_in_conflict_group(defaults, enabledKey, group)) continue;
        for (NSString *candidate in group[@"keys"]) {
            if (![candidate isEqualToString:enabledKey] &&
                cyanide_tweak_participates_in_conflict_group(defaults, candidate, group)) {
                [peers addObject:candidate];
            }
        }
    }
    return peers.array;
}

NSString *cyanide_tweak_display_name_for_enabled_key(NSString * _Nullable enabledKey)
{
    if (enabledKey.length == 0) return nil;
    for (CyanideTweakResourceRecord *record in cyanide_tweak_resource_registry()) {
        if ([record.enabledKey isEqualToString:enabledKey]) {
            return NSLocalizedString(record.displayName, nil);
        }
    }
    return nil;
}

NSString *cyanide_tweak_conflict_reason(NSString * _Nullable firstKey, NSString * _Nullable secondKey)
{
    for (NSDictionary<NSString *, id> *group in cyanide_tweak_conflict_groups_for_key(firstKey)) {
        if ([group[@"keys"] containsObject:secondKey]) {
            NSString *reason = group[@"reason"];
            return reason.length > 0 ? NSLocalizedString(reason, nil) : nil;
        }
    }
    return nil;
}

BOOL cyanide_tweak_enabled_with_compatibility(NSUserDefaults *defaults, NSString *enabledKey)
{
    if (![defaults boolForKey:enabledKey]) return NO;
    for (NSDictionary<NSString *, id> *group in cyanide_tweak_conflict_groups_for_key(enabledKey)) {
        if (!cyanide_tweak_participates_in_conflict_group(defaults, enabledKey, group)) continue;
        for (NSString *candidate in group[@"keys"]) {
            if (!cyanide_tweak_participates_in_conflict_group(defaults, candidate, group)) continue;
            if (![defaults boolForKey:candidate]) continue;
            if (![candidate isEqualToString:enabledKey]) return NO;
            break;
        }
    }
    return YES;
}

NSArray<NSString *> *cyanide_blocked_enabled_tweak_keys(NSUserDefaults *defaults)
{
    NSMutableOrderedSet<NSString *> *blocked = [NSMutableOrderedSet orderedSet];
    for (NSDictionary<NSString *, id> *group in cyanide_tweak_conflict_groups()) {
        BOOL foundWinner = NO;
        for (NSString *key in group[@"keys"]) {
            if (!cyanide_tweak_participates_in_conflict_group(defaults, key, group)) continue;
            if (![defaults boolForKey:key]) continue;
            if (!foundWinner) {
                foundWinner = YES;
            } else {
                [blocked addObject:key];
            }
        }
    }
    return blocked.array;
}
