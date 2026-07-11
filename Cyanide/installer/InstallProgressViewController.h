//
//  InstallProgressViewController.h
//  Cyanide
//
//  Sileo-style install progress sheet: live log + spinner during apply, then
//  "Done" once settings_run_actions completes.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface InstallProgressViewController : UIViewController
@property (nonatomic, assign) BOOL promptsForHideHomeBarRespring;
@property (nonatomic, copy, nullable) dispatch_block_t onDismiss;
@end

NS_ASSUME_NONNULL_END
