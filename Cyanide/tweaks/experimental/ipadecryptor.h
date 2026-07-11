//
//  ipadecryptor.h
//  Cyanide local IPA decryptor (FairPlay dump via DarkSword KRW).
//
//  Flow (installed apps / main-binary only):
//  1. Discover installed user apps
//  2. Run Kernel Chain (KRW + sandbox widen) if needed
//  3. Launch target if needed; match live process by name / path
//  4. Dump main Mach-O crypt pages (UUID-matched); clear cryptid
//  5. Pack Payload/*.app into Documents/DecryptedIPAs/*.ipa
//
//  No App Store login or remote IPA download.
//  Dependency dump intentionally disabled until image matching exists.
//

#ifndef ipadecryptor_h
#define ipadecryptor_h

#import <stdbool.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>

NSArray<NSDictionary<NSString *, NSString *> *> *ipadecryptor_installed_apps(void);
NSArray<NSDictionary<NSString *, NSString *> *> *ipadecryptor_installed_apps_with_system_apps(BOOL includeSystemApps);
/// Best-effort sandbox widen so installed-app enumeration can see /var/containers.
bool ipadecryptor_prepare_for_app_enumeration(void);
NSString *ipadecryptor_display_name_for_bundle(NSString *bundleID);
NSString *ipadecryptor_default_output_directory(void);

bool ipadecryptor_probe_installed_app(NSString *bundleID, NSString **messageOut);
bool ipadecryptor_start_decrypt_installed_app(NSString *bundleID, NSString **messageOut);

#endif /* __OBJC__ */

#endif /* ipadecryptor_h */
