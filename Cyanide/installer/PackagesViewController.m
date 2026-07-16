//
//  PackagesViewController.m
//  Cyanide
//

#import "PackagesViewController.h"
#import "CYIconBadge.h"
#import "PackageCatalog.h"
#import "PackageDetailViewController.h"
#import "PackageQueue.h"
#import "../SettingsViewController.h"
#import "../TweakCompatibility.h"
#import "../tweaks/RepoTweaks.h"
#import "MainTabBarController.h"

static NSString * const kPkgCellID    = @"PkgCell";
static NSString * const kSearchCellID = @"SearchPkgCell";

static NSString *packages_l10n(NSString *text)
{
    return text.length ? NSLocalizedString(text, nil) : text;
}

static BOOL package_has_repo_update(Package *pkg)
{
    if (pkg.kind != PackageInstallKindRepoTweak) return NO;
    if (pkg.isInstallDisabled) return NO;
    if (pkg.repoURL.length == 0 || pkg.repoTweakID.length == 0) return NO;
    NSString *installed = [[NSUserDefaults standardUserDefaults]
        stringForKey:repotweaks_installed_version_key(pkg.repoURL, pkg.repoTweakID)];
    if (installed.length == 0 || pkg.version.length == 0) return NO;
    return repotweaks_compare_versions(pkg.version, installed) == NSOrderedDescending;
}

static BOOL package_is_javascript(Package *package)
{
    return package.repoTweakUsesQuickLoader ||
           [package.identifier isEqualToString:@"com.darksword.quickloader"];
}

@interface PackagesViewController () <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *packageSections;
@property (nonatomic, copy) NSArray<Package *> *allPackagesSorted;
@property (nonatomic, copy) NSArray<Package *> *searchResults;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, strong) UISearchController *searchCtl;
@end

@implementation PackagesViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = packages_l10n(@"Packages");
    self.navigationItem.title = packages_l10n(@"Packages");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.searchText = @"";

    [self refreshCatalog];

    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68.0;
    self.tableView.sectionFooterHeight = 4.0;

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(pullToRefresh) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;

    self.searchCtl = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchCtl.searchResultsUpdater = self;
    self.searchCtl.obscuresBackgroundDuringPresentation = NO;
    self.searchCtl.searchBar.placeholder = packages_l10n(@"Search all tweaks");
    self.navigationItem.searchController = self.searchCtl;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(catalogDidChange:)
                                                 name:PackageQueueDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(catalogDidChange:)
                                                 name:kSettingsActionsDidCompleteNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(catalogDidChange:)
                                                 name:RepoTweaksDidRefreshNotification
                                               object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refreshCatalog];
    [self.tableView reloadData];
}

- (void)catalogDidChange:(NSNotification *)note
{
    if (!self.isViewLoaded) return;
    [self refreshCatalog];
    [self.tableView reloadData];
}

- (void)refreshCatalog
{
    NSArray<Package *> *all = [[PackageCatalog allPackages]
        sortedArrayUsingComparator:^NSComparisonResult(Package *a, Package *b) {
            return [a.name caseInsensitiveCompare:b.name];
        }];

    NSMutableArray<NSDictionary<NSString *, id> *> *conflictSections = [NSMutableArray array];
    NSMutableSet<NSString *> *groupedIdentifiers = [NSMutableSet set];
    for (NSString *groupIdentifier in cyanide_tweak_conflict_group_identifiers()) {
        NSSet<NSString *> *enabledKeys = [NSSet setWithArray:cyanide_tweak_conflict_group_enabled_keys(groupIdentifier)];
        NSMutableArray<Package *> *packages = [NSMutableArray array];
        for (Package *package in all) {
            NSString *enabledKey = cyanide_tweak_enabled_key_for_package(package);
            NSString *primaryGroup = cyanide_tweak_primary_conflict_group_identifier(enabledKey);
            if ([primaryGroup isEqualToString:groupIdentifier] && [enabledKeys containsObject:enabledKey]) {
                [packages addObject:package];
            }
        }
        if (packages.count >= 2) {
            [conflictSections addObject:@{
                @"title": cyanide_tweak_conflict_group_title(groupIdentifier) ?: groupIdentifier,
                @"packages": packages,
            }];
            for (Package *package in packages) {
                [groupedIdentifiers addObject:package.identifier];
            }
        }
    }

    NSMutableArray<Package *> *javaScriptPackages = [NSMutableArray array];
    NSMutableArray<Package *> *otherPackages = [NSMutableArray array];
    for (Package *package in all) {
        if ([groupedIdentifiers containsObject:package.identifier]) continue;
        if (package_is_javascript(package)) {
            [javaScriptPackages addObject:package];
        } else {
            [otherPackages addObject:package];
        }
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *sections = [NSMutableArray array];
    if (javaScriptPackages.count > 0) {
        [sections addObject:@{ @"title": @"JavaScript", @"packages": javaScriptPackages }];
    }
    [sections addObjectsFromArray:conflictSections];
    if (otherPackages.count > 0) {
        [sections addObject:@{ @"title": @"Packages", @"packages": otherPackages }];
    }

    self.packageSections = sections;
    self.allPackagesSorted = all;
    [self rebuildSearchResults];
}

- (void)pullToRefresh
{
    [self.refreshControl endRefreshing];
    MainTabBarController *tab = (MainTabBarController *)self.tabBarController;
    if ([tab respondsToSelector:@selector(showRefreshBanner)]) [tab showRefreshBanner];
    repotweaks_refresh_all_sources(nil);
}

- (BOOL)isSearchActive { return self.searchText.length > 0; }

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *q = searchController.searchBar.text ?: @"";
    if ([q isEqualToString:self.searchText]) return;
    self.searchText = q;
    [self rebuildSearchResults];
    [self.tableView reloadData];
}

- (void)rebuildSearchResults
{
    if (![self isSearchActive]) { self.searchResults = nil; return; }
    NSString *q = self.searchText;
    NSStringCompareOptions opt = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSMutableArray *out = [NSMutableArray array];
    for (Package *p in self.allPackagesSorted) {
        if ([p.name rangeOfString:q options:opt].location != NSNotFound ||
            [p.shortDescription rangeOfString:q options:opt].location != NSNotFound ||
            [p.category rangeOfString:q options:opt].location != NSNotFound) {
            [out addObject:p];
        }
    }
    self.searchResults = out;
}

#pragma mark - Data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    if ([self isSearchActive]) return 1;
    return (NSInteger)self.packageSections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if ([self isSearchActive]) return (NSInteger)self.searchResults.count;
    return (NSInteger)[self.packageSections[section][@"packages"] count];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if ([self isSearchActive]) return nil;
    return CYSectionHeaderView(packages_l10n(self.packageSections[section][@"title"]));
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if ([self isSearchActive]) return 0.0;
    return 46.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self isSearchActive]) return [self packageCellForPackage:self.searchResults[indexPath.row] colorIndex:(NSUInteger)indexPath.row tableView:tableView];
    NSArray<Package *> *packages = self.packageSections[indexPath.section][@"packages"];
    return [self packageCellForPackage:packages[indexPath.row] colorIndex:(NSUInteger)indexPath.row tableView:tableView];
}

- (UITableViewCell *)packageCellForPackage:(Package *)pkg colorIndex:(NSUInteger)colorIndex tableView:(UITableView *)tableView
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kPkgCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kPkgCellID];
    }

    BOOL installed = pkg.isInstalled;
    BOOL unsupported = pkg.isInstallDisabled && pkg.installDisabledReason.length > 0;
    BOOL disabledForInstall = pkg.isInstallDisabled && !installed;
    UIColor *iconColor = disabledForInstall ? UIColor.secondaryLabelColor : CYSpectrumColor(colorIndex);
    UIListContentConfiguration *config = [UIListContentConfiguration subtitleCellConfiguration];
    config.image = CYIconBadgeImage(pkg.symbolName, iconColor, 32.0);
    config.imageProperties.reservedLayoutSize = CGSizeMake(32.0, 32.0);
    config.imageProperties.maximumSize = CGSizeMake(32.0, 32.0);
    config.imageToTextPadding = 12.0;
    config.text = packages_l10n(pkg.name);
    config.textProperties.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    if (disabledForInstall) config.textProperties.color = UIColor.secondaryLabelColor;

    BOOL hasUpdate = package_has_repo_update(pkg);
    NSString *shortDescription = packages_l10n(pkg.shortDescription);
    NSString *installDisabledReason = packages_l10n(pkg.installDisabledReason);
    if (unsupported && installed && pkg.shortDescription.length > 0) {
        config.secondaryText = [NSString stringWithFormat:packages_l10n(@"Installed, unsupported here · %@ · %@"),
                                installDisabledReason,
                                shortDescription];
    } else if (unsupported && installed) {
        config.secondaryText = [NSString stringWithFormat:packages_l10n(@"Installed, unsupported here · %@"),
                                installDisabledReason];
    } else if (unsupported && pkg.shortDescription.length > 0) {
        config.secondaryText = [NSString stringWithFormat:@"%@ · %@", installDisabledReason, shortDescription];
    } else if (unsupported) {
        config.secondaryText = installDisabledReason;
    } else if (hasUpdate && pkg.shortDescription.length > 0) {
        config.secondaryText = [NSString stringWithFormat:packages_l10n(@"Update available · %@"), shortDescription];
    } else if (hasUpdate) {
        config.secondaryText = packages_l10n(@"Update available");
    } else {
        config.secondaryText = shortDescription;
    }
    config.secondaryTextProperties.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    config.secondaryTextProperties.color = unsupported
        ? UIColor.systemOrangeColor
        : (hasUpdate ? UIColor.systemBlueColor : [UIColor.labelColor colorWithAlphaComponent:0.55]);
    config.secondaryTextProperties.numberOfLines = 3;
    config.textToSecondaryTextVerticalPadding = 2.0;
    NSDirectionalEdgeInsets m = config.directionalLayoutMargins;
    m.top = 10.0; m.bottom = 10.0;
    config.directionalLayoutMargins = m;
    cell.contentConfiguration = config;

    if (unsupported && installed) {
        UILabel *pill = [[UILabel alloc] init];
        pill.text = packages_l10n(@"INSTALLED");
        pill.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightHeavy];
        pill.textColor = UIColor.systemGreenColor;
        pill.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.15];
        pill.textAlignment = NSTextAlignmentCenter;
        [pill sizeToFit];
        CGRect f = pill.frame;
        f.size.width += 14.0;
        f.size.height = 22.0;
        pill.frame = f;
        pill.layer.cornerRadius = f.size.height / 2.0;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.layer.masksToBounds = YES;
        cell.accessoryView = pill;
    } else if (unsupported) {
        UILabel *pill = [[UILabel alloc] init];
        pill.text = [pkg.category isEqualToString:@"In Development"] ? packages_l10n(@"DISABLED") : packages_l10n(@"UNSUPPORTED");
        pill.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightHeavy];
        pill.textColor = UIColor.systemOrangeColor;
        pill.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.15];
        pill.textAlignment = NSTextAlignmentCenter;
        [pill sizeToFit];
        CGRect f = pill.frame;
        f.size.width += 14.0;
        f.size.height = 22.0;
        pill.frame = f;
        pill.layer.cornerRadius = f.size.height / 2.0;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.layer.masksToBounds = YES;
        cell.accessoryView = pill;
    } else if (hasUpdate) {
        UILabel *pill = [[UILabel alloc] init];
        pill.text = packages_l10n(@"UPDATE");
        pill.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightHeavy];
        pill.textColor = UIColor.systemBlueColor;
        pill.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.15];
        pill.textAlignment = NSTextAlignmentCenter;
        [pill sizeToFit];
        CGRect f = pill.frame;
        f.size.width += 14.0;
        f.size.height = 22.0;
        pill.frame = f;
        pill.layer.cornerRadius = f.size.height / 2.0;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.layer.masksToBounds = YES;
        cell.accessoryView = pill;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

#pragma mark - Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    Package *pkg;
    if ([self isSearchActive]) {
        pkg = self.searchResults[indexPath.row];
    } else {
        NSArray<Package *> *packages = self.packageSections[indexPath.section][@"packages"];
        pkg = packages[indexPath.row];
    }
    PackageDetailViewController *detail = [[PackageDetailViewController alloc] initWithPackage:pkg];
    [self.navigationController pushViewController:detail animated:YES];
}

@end
