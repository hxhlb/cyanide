#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class Package;

FOUNDATION_EXPORT NSString * const CyanideConflictGroupStatusBar;
FOUNDATION_EXPORT NSString * const CyanideConflictGroupHomeLayout;
FOUNDATION_EXPORT NSString * const CyanideConflictGroupThemeEngine;
FOUNDATION_EXPORT NSString * const CyanideConflictGroupFloatingScenes;
FOUNDATION_EXPORT NSString * const CyanideConflictGroupWallpaper;
FOUNDATION_EXPORT NSString * const CyanideConflictGroupAppLibrary;

@interface CyanideTweakResourceRecord : NSObject

@property (nonatomic, readonly, copy) NSString *packageIdentifier;
@property (nonatomic, readonly, copy, nullable) NSString *enabledKey;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, copy) NSString *resourceSummary;

@end

// Central registry for native tweaks and internal SpringBoard actions. Every
// new native PackageCatalog entry must be registered here.
FOUNDATION_EXPORT NSArray<CyanideTweakResourceRecord *> *cyanide_tweak_resource_registry(void);
FOUNDATION_EXPORT CyanideTweakResourceRecord * _Nullable cyanide_tweak_resource_record_for_identifier(NSString *identifier);
FOUNDATION_EXPORT NSArray<NSString *> *cyanide_missing_native_tweak_registry_identifiers(NSArray<Package *> *packages);
FOUNDATION_EXPORT NSString * _Nullable cyanide_tweak_enabled_key_for_package(Package *package);
FOUNDATION_EXPORT BOOL cyanide_tweak_package_has_conflicts(Package *package);
FOUNDATION_EXPORT NSArray<NSString *> *cyanide_tweak_conflict_group_identifiers(void);
FOUNDATION_EXPORT NSString * _Nullable cyanide_tweak_conflict_group_title(NSString *groupIdentifier);
FOUNDATION_EXPORT NSArray<NSString *> *cyanide_tweak_conflict_group_enabled_keys(NSString *groupIdentifier);
FOUNDATION_EXPORT NSString * _Nullable cyanide_tweak_primary_conflict_group_identifier(NSString * _Nullable enabledKey);

// Conflict groups are ordered. If legacy/manual preferences enable multiple
// members, the first enabled member wins without rewriting user defaults.
FOUNDATION_EXPORT NSArray<NSString *> *cyanide_conflicting_enabled_keys(NSString * _Nullable enabledKey);
FOUNDATION_EXPORT NSString * _Nullable cyanide_tweak_display_name_for_enabled_key(NSString * _Nullable enabledKey);
FOUNDATION_EXPORT NSString * _Nullable cyanide_tweak_conflict_reason(NSString * _Nullable firstKey, NSString * _Nullable secondKey);
FOUNDATION_EXPORT BOOL cyanide_tweak_enabled_with_compatibility(NSUserDefaults *defaults, NSString *enabledKey);
FOUNDATION_EXPORT NSArray<NSString *> *cyanide_blocked_enabled_tweak_keys(NSUserDefaults *defaults);

NS_ASSUME_NONNULL_END
