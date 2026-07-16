//
//  AppStoreToolsViewController.m
//  Installed-App Store metadata browser for downgrade and update blocking.
//

#import "AppStoreToolsViewController.h"
#import "SettingsViewController.h"
#import "tweaks/experimental/ipadecryptor.h"
#import "LogTextView.h"

#import <objc/message.h>

static NSString * const kASTBundleID = @"bundleID";
static NSString * const kASTName = @"name";
static NSString * const kASTBundlePath = @"bundlePath";
static NSString * const kASTVersion = @"version";
static NSString * const kASTItemID = @"itemID";
static NSString * const kASTStoreFront = @"storeFront";
static NSString * const kASTAccountID = @"accountID";
static NSString * const kASTAccountAvailable = @"accountAvailable";
static NSString * const kASTHistoryEndpointTemplateKey = @"AppDowngradeHistoryEndpointTemplate";
static NSString * const kASTDefaultHistoryEndpointTemplate = @"https://apis.bilin.eu.org/history/{itemID}";

static NSString *ast_l10n(NSString *value)
{
    return value.length > 0 ? NSLocalizedString(value, nil) : @"";
}

static NSString *ast_string(id value)
{
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return @"";
}

static unsigned long long ast_u64(id value)
{
    return [value respondsToSelector:@selector(unsignedLongLongValue)]
        ? [value unsignedLongLongValue]
        : 0;
}

static id ast_first_metadata_value(NSDictionary *dictionary, NSArray<NSString *> *keys)
{
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in keys) {
        id value = dictionary[key];
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 0) return value;
        if ([value respondsToSelector:@selector(unsignedLongLongValue)] && ast_u64(value) != 0) return value;
    }
    return nil;
}

static NSString *ast_history_endpoint_template(void)
{
    NSString *value = [NSUserDefaults.standardUserDefaults
        stringForKey:kASTHistoryEndpointTemplateKey];
    return value.length > 0 ? value : kASTDefaultHistoryEndpointTemplate;
}

static NSURL *ast_history_url(unsigned long long itemID)
{
    NSString *template = ast_history_endpoint_template();
    if (![template containsString:@"{itemID}"]) return nil;
    NSString *urlString = [template stringByReplacingOccurrencesOfString:@"{itemID}"
                                                               withString:[NSString stringWithFormat:@"%llu", itemID]];
    return [NSURL URLWithString:urlString];
}

static NSString *ast_storefront_name(NSString *identifier)
{
    NSString *base = [[identifier componentsSeparatedByString:@"-"] firstObject] ?: identifier;
    NSDictionary<NSString *, NSString *> *regionCodes = @{
        @"143441": @"US",
        @"143465": @"CN",
        @"143463": @"HK",
        @"143470": @"TW",
        @"143462": @"JP",
        @"143444": @"GB",
        @"143464": @"SG",
        @"143460": @"AU",
        @"143466": @"KR",
        @"143455": @"CA",
    };
    NSString *code = regionCodes[base];
    return code.length > 0 ? code : (base.length > 0 ? base : ast_l10n(@"Unknown"));
}

static NSDictionary<NSString *, id> *ast_metadata_for_app(NSDictionary<NSString *, NSString *> *entry)
{
    NSString *bundleID = entry[kASTBundleID] ?: @"";
    NSString *bundlePath = entry[kASTBundlePath] ?: @"";
    NSMutableDictionary<NSString *, id> *result = [NSMutableDictionary dictionaryWithDictionary:entry];
    if (bundleID.length == 0 || bundlePath.length == 0) return result;

    NSString *containerPath = bundlePath.stringByDeletingLastPathComponent;
    NSString *metadataPath = [containerPath stringByAppendingPathComponent:@"iTunesMetadata.plist"];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
    NSDictionary *downloadInfo = [metadata[@"com.apple.iTunesStore.downloadInfo"]
        isKindOfClass:NSDictionary.class] ? metadata[@"com.apple.iTunesStore.downloadInfo"] : nil;
    NSDictionary *accountInfo = [downloadInfo[@"accountInfo"] isKindOfClass:NSDictionary.class]
        ? downloadInfo[@"accountInfo"] : nil;

    id itemID = ast_first_metadata_value(metadata, @[@"itemId", @"itemID", @"adamId", @"adamID"])
        ?: ast_first_metadata_value(downloadInfo, @[@"itemId", @"itemID", @"adamId", @"adamID"]);
    id storeFront = ast_first_metadata_value(metadata, @[@"s", @"storeFront", @"storefront", @"storefrontId"])
        ?: ast_first_metadata_value(downloadInfo, @[@"s", @"storeFront", @"storefront", @"storefrontId"])
        ?: ast_first_metadata_value(accountInfo, @[@"storeFront", @"storefront", @"storefrontId"]);
    id account = ast_first_metadata_value(accountInfo, @[@"DSPersonID", @"dsPersonID", @"accountIdentifier"])
        ?: ast_first_metadata_value(downloadInfo, @[@"DSPersonID", @"dsPersonID", @"accountIdentifier"])
        ?: ast_first_metadata_value(metadata, @[@"purchaserDSID", @"downloaderDSID", @"applicationDSID"]);
    id version = ast_first_metadata_value(metadata, @[@"bundleShortVersionString", @"bundleVersion"]);
    if (!version) {
        NSDictionary *bundleInfo = [NSDictionary dictionaryWithContentsOfFile:
            [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
        version = ast_first_metadata_value(bundleInfo,
            @[@"CFBundleShortVersionString", @"CFBundleVersion"]);
    }

    if (ast_u64(itemID) != 0) result[kASTItemID] = @(ast_u64(itemID));
    NSString *storeFrontString = ast_string(storeFront);
    if (storeFrontString.length > 0 && ![storeFrontString isEqualToString:@"0"]) {
        result[kASTStoreFront] = storeFrontString;
    }
    unsigned long long accountID = ast_u64(account);
    if (accountID != 0) result[kASTAccountID] = @(accountID);
    if (ast_string(version).length > 0) result[kASTVersion] = ast_string(version);
    result[kASTAccountAvailable] = @(accountID != 0);
    return result;
}

static NSString *ast_marker_path(NSDictionary<NSString *, id> *app)
{
    NSString *bundlePath = ast_string(app[kASTBundlePath]);
    if (bundlePath.length == 0) return @"";
    NSString *containerPath = bundlePath.stringByStandardizingPath.stringByDeletingLastPathComponent;
    NSString *markerRoot = @"/var/containers/Bundle/Application/";
    NSRange rootRange = [containerPath rangeOfString:markerRoot];
    if (rootRange.location == NSNotFound) return @"";
    NSString *containerID = [containerPath substringFromIndex:NSMaxRange(rootRange)];
    if (containerID.length == 0 || [containerID containsString:@"/"]) return @"";
    return [containerPath stringByAppendingPathComponent:@"com.apple.mobileinstallation.placeholder"];
}

static UIImage *ast_icon_for_bundle(NSString *bundleID)
{
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (bundleID.length > 0 && [UIImage respondsToSelector:selector]) {
        UIImage *image = ((id (*)(id, SEL, id, NSInteger, CGFloat))objc_msgSend)(
            UIImage.class, selector, bundleID, 2, UIScreen.mainScreen.scale);
        if ([image isKindOfClass:UIImage.class]) return image;
    }
    return [UIImage systemImageNamed:@"app.dashed"];
}

typedef NS_ENUM(NSInteger, ASTToolMode) {
    ASTToolModeDowngrade,
    ASTToolModeUpdateBlocking,
};

@interface AppStoreAppListViewController () <UISearchResultsUpdating>
@property (nonatomic, assign) ASTToolMode mode;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *apps;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *filteredApps;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, assign) BOOL loading;
- (void)loadApps;
- (void)handleApp:(NSDictionary<NSString *, id> *)app sourceView:(UIView *)sourceView;
@end

@interface AppDowngradeVersionsViewController : UITableViewController
@property (nonatomic, copy) NSDictionary<NSString *, id> *app;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *versions;
- (instancetype)initWithApp:(NSDictionary<NSString *, id> *)app
                    versions:(NSArray<NSDictionary<NSString *, id> *> *)versions;
@end

@implementation AppStoreAppListViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = 68.0;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(loadApps)];
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = ast_l10n(@"Search Apps");
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.apps = @[];
    self.filteredApps = @[];
    [self loadApps];
}

- (void)showMessage:(NSString *)message buttonTitle:(NSString *)buttonTitle action:(SEL)action
{
    UIView *container = [[UIView alloc] initWithFrame:self.tableView.bounds];
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = message;
    label.textColor = UIColor.secondaryLabelColor;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    [container addSubview:label];

    NSMutableArray<NSLayoutConstraint *> *constraints = [@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:30.0],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-30.0],
        [label.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-24.0],
    ] mutableCopy];
    if (buttonTitle.length > 0 && action) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [button setTitle:buttonTitle forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        [container addSubview:button];
        [constraints addObject:[button.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:18.0]];
        [constraints addObject:[button.centerXAnchor constraintEqualToAnchor:container.centerXAnchor]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    self.tableView.backgroundView = container;
}

- (void)prepareAccess
{
    settings_prepare_app_store_tools_access(self, ^(BOOL success) {
        if (success) [self loadApps];
    });
}

- (void)loadApps
{
    if (self.loading) return;
    if (!settings_app_store_tools_access_ready()) {
        [self showMessage:ast_l10n(@"Kernel access and filesystem escape are required to inspect installed App Store applications.")
                  buttonTitle:ast_l10n(@"Run Kernel Chain")
                       action:@selector(prepareAccess)];
        return;
    }

    self.loading = YES;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [self showMessage:ast_l10n(@"Loading installed applications…") buttonTitle:@"" action:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary<NSString *, NSString *> *> *raw = ipadecryptor_installed_apps();
        NSMutableArray<NSDictionary<NSString *, id> *> *loaded = [NSMutableArray arrayWithCapacity:raw.count];
        NSUInteger itemIDCount = 0;
        NSUInteger storefrontCount = 0;
        NSUInteger accountIDCount = 0;
        for (NSDictionary<NSString *, NSString *> *entry in raw) {
            NSDictionary *metadata = ast_metadata_for_app(entry);
            if (self.mode == ASTToolModeUpdateBlocking && ast_marker_path(metadata).length == 0) {
                continue;
            }
            if (metadata[kASTBundleID]) {
                [loaded addObject:metadata];
                if (ast_u64(metadata[kASTItemID]) != 0) itemIDCount++;
                if (ast_string(metadata[kASTStoreFront]).length > 0) storefrontCount++;
                if (ast_u64(metadata[kASTAccountID]) != 0) accountIDCount++;
            }
        }
        log_user("[APPSTORE] Local metadata apps=%lu itemID=%lu storefront=%lu accountID=%lu.\n",
                 (unsigned long)loaded.count,
                 (unsigned long)itemIDCount,
                 (unsigned long)storefrontCount,
                 (unsigned long)accountIDCount);
        [loaded sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [ast_string(a[kASTName]) localizedCaseInsensitiveCompare:ast_string(b[kASTName])];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loading = NO;
            self.apps = loaded;
            self.navigationItem.rightBarButtonItem.enabled = YES;
            self.tableView.backgroundView = nil;
            [self updateSearchResultsForSearchController:self.searchController];
            [self.tableView reloadData];
            if (loaded.count == 0) {
                [self showMessage:ast_l10n(@"No installed App Store applications were found.")
                      buttonTitle:ast_l10n(@"Refresh")
                           action:@selector(loadApps)];
            }
        });
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *query = searchController.searchBar.text ?: @"";
    if (query.length == 0) {
        self.filteredApps = self.apps;
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *app, NSDictionary *bindings) {
            (void)bindings;
            return [ast_string(app[kASTName]) localizedCaseInsensitiveContainsString:query] ||
                   [ast_string(app[kASTBundleID]) localizedCaseInsensitiveContainsString:query];
        }];
        self.filteredApps = [self.apps filteredArrayUsingPredicate:predicate];
    }
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return self.mode == ASTToolModeDowngrade ? 2 : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    if (self.mode == ASTToolModeDowngrade && section == 0) return 1;
    return self.filteredApps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    if (self.mode == ASTToolModeDowngrade && section == 0) {
        return ast_l10n(@"Version History API");
    }
    return ast_l10n(@"Installed Apps");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    if (self.mode != ASTToolModeDowngrade || section != 0) return nil;
    return ast_l10n(@"GET request: replace {itemID} with the installed application's numeric App Store item ID. Compatible JSON response: {\"data\":[{\"bundle_version\":\"1.0\",\"external_identifier\":\"123456789\",\"release_date\":\"optional\"}]}. The service is third-party and can be replaced at any time.");
}

- (void)historyEndpointChanged:(UITextField *)field
{
    NSString *value = [field.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (value.length == 0 || [value isEqualToString:kASTDefaultHistoryEndpointTemplate]) {
        [defaults removeObjectForKey:kASTHistoryEndpointTemplateKey];
    } else {
        [defaults setObject:value forKey:kASTHistoryEndpointTemplateKey];
    }
    [defaults synchronize];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.mode == ASTToolModeDowngrade && indexPath.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"HistoryEndpoint"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           reuseIdentifier:@"HistoryEndpoint"];
            UITextField *field = [[UITextField alloc] init];
            field.translatesAutoresizingMaskIntoConstraints = NO;
            field.keyboardType = UIKeyboardTypeURL;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
            field.placeholder = kASTDefaultHistoryEndpointTemplate;
            field.accessibilityIdentifier = @"AppDowngradeHistoryEndpoint";
            [field addTarget:self action:@selector(historyEndpointChanged:)
            forControlEvents:UIControlEventEditingChanged];
            [cell.contentView addSubview:field];
            [NSLayoutConstraint activateConstraints:@[
                [field.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
                [field.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
                [field.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10.0],
                [field.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10.0],
            ]];
        }
        UITextField *field = [cell.contentView.subviews filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(UIView *view, NSDictionary *bindings) {
                (void)bindings;
                return [view isKindOfClass:UITextField.class];
            }]].firstObject;
        field.text = ast_history_endpoint_template();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"App"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"App"];
    NSDictionary *app = self.filteredApps[indexPath.row];
    NSString *bundleID = ast_string(app[kASTBundleID]);
    NSString *version = ast_string(app[kASTVersion]);
    NSString *storeFront = ast_string(app[kASTStoreFront]);
    cell.textLabel.text = ast_string(app[kASTName]);
    cell.detailTextLabel.text = version.length > 0
        ? [NSString stringWithFormat:@"%@ · %@", bundleID, version]
        : bundleID;
    cell.imageView.image = ast_icon_for_bundle(bundleID);
    cell.imageView.layer.cornerRadius = 9.0;
    cell.imageView.layer.masksToBounds = YES;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (self.mode == ASTToolModeUpdateBlocking) {
        BOOL blocked = [NSFileManager.defaultManager fileExistsAtPath:ast_marker_path(app)];
        cell.accessoryType = blocked ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;
        if (blocked) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
                bundleID, ast_l10n(@"Updates Blocked")];
        }
    } else if (storeFront.length > 0) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
            cell.detailTextLabel.text, ast_storefront_name(storeFront)];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.mode == ASTToolModeDowngrade && indexPath.section == 0) return;
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    [self handleApp:self.filteredApps[indexPath.row] sourceView:cell];
}

- (void)handleApp:(NSDictionary<NSString *, id> *)app sourceView:(UIView *)sourceView
{
    (void)app; (void)sourceView;
}

@end

@implementation AppDowngradeViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.mode = ASTToolModeDowngrade;
        self.title = ast_l10n(@"App Downgrade");
    }
    return self;
}

- (void)handleApp:(NSDictionary<NSString *, id> *)app sourceView:(UIView *)sourceView
{
    (void)sourceView;
    unsigned long long itemID = ast_u64(app[kASTItemID]);
    if (itemID == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:ast_l10n(@"App Store Metadata Unavailable")
            message:ast_l10n(@"This application does not expose an App Store item ID. Sideloaded, enterprise, and some TestFlight applications cannot be downgraded through this tool.")
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ast_l10n(@"OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIAlertController *loading = [UIAlertController alertControllerWithTitle:ast_l10n(@"Loading Version History")
        message:ast_string(app[kASTName]) preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:^{
        NSURL *historyURL = ast_history_url(itemID);
        if (!historyURL) {
            [loading dismissViewControllerAnimated:YES completion:^{
                UIAlertController *invalid = [UIAlertController alertControllerWithTitle:ast_l10n(@"Invalid Version History API")
                    message:ast_l10n(@"The API URL template must be a valid URL containing {itemID}.")
                    preferredStyle:UIAlertControllerStyleAlert];
                [invalid addAction:[UIAlertAction actionWithTitle:ast_l10n(@"OK") style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:invalid animated:YES completion:nil];
            }];
            return;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:historyURL];
        request.timeoutInterval = 15.0;
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSError *jsonError = nil;
            NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
            NSArray *history = [json isKindOfClass:NSDictionary.class] && [json[@"data"] isKindOfClass:NSArray.class]
                ? json[@"data"] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                [loading dismissViewControllerAnimated:YES completion:^{
                    if (error || jsonError || history.count == 0) {
                        NSString *message = error.localizedDescription ?: jsonError.localizedDescription
                            ?: ast_l10n(@"No historical versions were returned for this application.");
                        UIAlertController *failed = [UIAlertController alertControllerWithTitle:ast_l10n(@"Version Lookup Failed")
                            message:message preferredStyle:UIAlertControllerStyleAlert];
                        [failed addAction:[UIAlertAction actionWithTitle:ast_l10n(@"OK") style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:failed animated:YES completion:nil];
                        return;
                    }
                    AppDowngradeVersionsViewController *versions =
                        [[AppDowngradeVersionsViewController alloc] initWithApp:app versions:history];
                    [self.navigationController pushViewController:versions animated:YES];
                }];
            });
        }] resume];
    }];
}

@end

@implementation AppDowngradeVersionsViewController

- (instancetype)initWithApp:(NSDictionary<NSString *,id> *)app
                    versions:(NSArray<NSDictionary<NSString *,id> *> *)versions
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _app = [app copy];
        _versions = [versions sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [ast_string(b[@"release_date"]) compare:ast_string(a[@"release_date"])
                                                       options:NSNumericSearch];
        }];
        self.title = ast_string(app[kASTName]);
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = 58.0;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:ast_l10n(@"Custom ID")
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(promptCustomVersion)];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    return self.versions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Version"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Version"];
    NSDictionary *version = self.versions[indexPath.row];
    NSString *display = ast_string(version[@"bundle_version"]);
    NSString *identifier = ast_string(version[@"external_identifier"]);
    NSString *date = ast_string(version[@"release_date"]);
    cell.textLabel.text = display.length > 0 ? display : ast_l10n(@"Unknown Version");
    cell.detailTextLabel.text = date.length > 0
        ? [NSString stringWithFormat:@"ID %@ · %@", identifier, date]
        : [NSString stringWithFormat:@"ID %@", identifier];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *version = self.versions[indexPath.row];
    [self confirmVersionID:ast_u64(version[@"external_identifier"])
               versionName:ast_string(version[@"bundle_version"])];
}

- (void)promptCustomVersion
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ast_l10n(@"Custom Version ID")
        message:ast_l10n(@"Enter the numeric AppExtVrsId for the historical App Store build.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.placeholder = @"AppExtVrsId";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:ast_l10n(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:ast_l10n(@"Continue") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [self confirmVersionID:[alert.textFields.firstObject.text longLongValue]
                   versionName:ast_l10n(@"Custom Version")];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmVersionID:(unsigned long long)versionID versionName:(NSString *)versionName
{
    if (versionID == 0) return;
    NSString *store = ast_storefront_name(ast_string(self.app[kASTStoreFront]));
    BOOL accountAvailable = [self.app[kASTAccountAvailable] boolValue];
    NSString *accountState = ast_l10n(accountAvailable
        ? @"Installed app account metadata was found."
        : @"Installed app account metadata was not found; StoreKitUI will choose an account and may request authentication.");
    NSString *message = [NSString stringWithFormat:
        ast_l10n(@"Version: %@\nOriginal Storefront: %@\n%@\n\nThe request uses the installed app's App Store item ID and account metadata."),
        versionName.length > 0 ? versionName : [NSString stringWithFormat:@"%llu", versionID],
        store,
        accountState];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:ast_l10n(@"Confirm Downgrade")
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ast_l10n(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:ast_l10n(@"Downgrade") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        settings_perform_app_downgrade(self,
            ast_string(self.app[kASTBundleID]),
            ast_u64(self.app[kASTItemID]),
            versionID,
            ast_u64(self.app[kASTAccountID]),
            ^(BOOL success, NSString *message) {
                UIAlertController *result = [UIAlertController alertControllerWithTitle:
                    ast_l10n(success ? @"Request Sent" : @"Downgrade Failed")
                    message:message preferredStyle:UIAlertControllerStyleAlert];
                [result addAction:[UIAlertAction actionWithTitle:ast_l10n(@"OK") style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:result animated:YES completion:nil];
            });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@implementation AppUpdateBlockingViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.mode = ASTToolModeUpdateBlocking;
        self.title = ast_l10n(@"App Update Blocking");
    }
    return self;
}

- (void)handleApp:(NSDictionary<NSString *, id> *)app sourceView:(UIView *)sourceView
{
    NSString *marker = ast_marker_path(app);
    if (marker.length == 0) return;
    BOOL blocked = [NSFileManager.defaultManager fileExistsAtPath:marker];
    NSString *name = ast_string(app[kASTName]);
    NSString *message = blocked
        ? [NSString stringWithFormat:ast_l10n(@"Remove Cyanide's update-blocking marker for %@?"), name]
        : [NSString stringWithFormat:ast_l10n(@"Block App Store updates for %@? You must unblock it before installing a newer version."), name];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name
        message:message preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:ast_l10n(blocked ? @"Unblock Updates" : @"Block Updates")
        style:blocked ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            (void)action;
            settings_set_app_update_blocked(self, marker, !blocked, ^(BOOL success, NSString *resultMessage) {
                [self loadApps];
                BOOL installdUnavailable = !success && [resultMessage containsString:@"App Store"];
                UIAlertController *result = [UIAlertController alertControllerWithTitle:
                    ast_l10n(success ? @"Updated" : (installdUnavailable ? @"Wake installd" : @"Operation Failed"))
                    message:resultMessage preferredStyle:UIAlertControllerStyleAlert];
                if (installdUnavailable) {
                    [result addAction:[UIAlertAction actionWithTitle:ast_l10n(@"Open App Store")
                        style:UIAlertActionStyleDefault handler:^(UIAlertAction *openAction) {
                            (void)openAction;
                            NSURL *url = [NSURL URLWithString:@"itms-apps://itunes.apple.com"];
                            if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
                        }]];
                }
                [result addAction:[UIAlertAction actionWithTitle:ast_l10n(@"OK") style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:result animated:YES completion:nil];
            });
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:ast_l10n(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView ?: self.view;
        popover.sourceRect = sourceView ? sourceView.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
