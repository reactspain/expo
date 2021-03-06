// Copyright 2015-present 650 Industries. All rights reserved.

@import UIKit;

#import "EXAppDelegate.h"
#import "EXAppViewController.h"
#import "EXHomeAppManager.h"
#import "EXHomeDiagnosticsViewController.h"
#import "EXKernel.h"
#import "EXKernelAppLoader.h"
#import "EXKernelAppRecord.h"
#import "EXKernelAppRegistry.h"
#import "EXKernelLinkingManager.h"
#import "EXKernelServiceRegistry.h"
#import "EXMenuViewController.h"
#import "EXRootViewController.h"

NSString * const kEXHomeDisableNuxDefaultsKey = @"EXKernelDisableNuxDefaultsKey";
NSString * const kEXHomeIsNuxFinishedDefaultsKey = @"EXHomeIsNuxFinishedDefaultsKey";

NS_ASSUME_NONNULL_BEGIN

@interface EXRootViewController () <EXAppBrowserController>

@property (nonatomic, strong) EXMenuViewController *menuViewController;
@property (nonatomic, assign) BOOL isMenuVisible;
@property (nonatomic, assign) BOOL isAnimatingMenu;
@property (nonatomic, assign) BOOL isAnimatingAppTransition;

@end

@implementation EXRootViewController

- (instancetype)init
{
  if (self = [super init]) {
    [EXKernel sharedInstance].browserController = self;
    [self _maybeResetNuxState];
  }
  return self;
}

#pragma mark - EXViewController

- (void)createRootAppAndMakeVisible
{
  EXHomeAppManager *homeAppManager = [[EXHomeAppManager alloc] init];
  EXKernelAppLoader *homeAppLoader = [[EXKernelAppLoader alloc] initWithLocalManifest:[EXHomeAppManager bundledHomeManifest]];
  EXKernelAppRecord *homeAppRecord = [[EXKernelAppRecord alloc] initWithAppLoader:homeAppLoader appManager:homeAppManager];
  [[EXKernel sharedInstance].appRegistry registerHomeAppRecord:homeAppRecord];
  [self moveAppToVisible:homeAppRecord];
}

#pragma mark - EXAppBrowserController

- (void)moveAppToVisible:(EXKernelAppRecord *)appRecord
{
  [self _foregroundAppRecord:appRecord];
}

- (void)toggleMenuWithCompletion:(void (^ _Nullable)(void))completion
{
  [self setIsMenuVisible:!_isMenuVisible completion:completion];
}

- (void)setIsMenuVisible:(BOOL)isMenuVisible completion:(void (^ _Nullable)(void))completion
{
  if (!_menuViewController) {
    _menuViewController = [[EXMenuViewController alloc] init];
  }
  
  // TODO: ben: can this be more robust?
  // some third party libs (and core RN) often just look for the root VC and present random crap from it.
  if (self.presentedViewController && self.presentedViewController != _menuViewController) {
    [self.presentedViewController dismissViewControllerAnimated:NO completion:nil];
  }
  
  if (!_isAnimatingMenu && isMenuVisible != _isMenuVisible) {
    _isMenuVisible = isMenuVisible;
    [self _animateMenuToVisible:_isMenuVisible completion:completion];
  }
}

- (void)showDiagnostics
{
  __weak typeof(self) weakSelf = self;
  [self setIsMenuVisible:NO completion:^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf) {
      EXHomeDiagnosticsViewController *vcDiagnostics = [[EXHomeDiagnosticsViewController alloc] init];
      [strongSelf presentViewController:vcDiagnostics animated:NO completion:nil];
    }
  }];
}

- (void)showQRReader
{
  [self moveHomeToVisible];
  [[self _getHomeAppManager] showQRReader];
}

- (void)moveHomeToVisible
{
  __weak typeof(self) weakSelf = self;
  [self setIsMenuVisible:NO completion:^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf) {
      [strongSelf moveAppToVisible:[EXKernel sharedInstance].appRegistry.homeAppRecord];
    }
  }];
}

- (void)refreshVisibleApp
{
  // this is different from Util.reload()
  // because it can work even on an errored app record (e.g. with no manifest, or with no running bridge).
  [self setIsMenuVisible:NO completion:nil];
  EXKernelAppRecord *visibleApp = [EXKernel sharedInstance].visibleApp;
  [[EXKernel sharedInstance] logAnalyticsEvent:@"RELOAD_EXPERIENCE" forAppRecord:visibleApp];
  NSURL *urlToRefresh = visibleApp.appLoader.manifestUrl;
  [[EXKernel sharedInstance] createNewAppWithUrl:urlToRefresh initialProps:nil];
}

- (void)addHistoryItemWithUrl:(NSURL *)manifestUrl manifest:(NSDictionary *)manifest
{
  [[self _getHomeAppManager] addHistoryItemWithUrl:manifestUrl manifest:manifest];
}

- (void)getHistoryUrlForExperienceId:(NSString *)experienceId completion:(void (^)(NSString *))completion
{
  return [[self _getHomeAppManager] getHistoryUrlForExperienceId:experienceId completion:completion];
}

- (void)setIsNuxFinished:(BOOL)isFinished
{
  [[NSUserDefaults standardUserDefaults] setBool:isFinished forKey:kEXHomeIsNuxFinishedDefaultsKey];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)isNuxFinished
{
  return [[NSUserDefaults standardUserDefaults] boolForKey:kEXHomeIsNuxFinishedDefaultsKey];
}

- (void)appDidFinishLoadingSuccessfully:(EXKernelAppRecord *)appRecord
{
  // show nux if needed
  if (!self.isNuxFinished
      && appRecord == [EXKernel sharedInstance].visibleApp
      && appRecord != [EXKernel sharedInstance].appRegistry.homeAppRecord
      && !self.isMenuVisible) {
    [self setIsMenuVisible:YES completion:nil];
  }
}

#pragma mark - internal

- (void)_foregroundAppRecord:(EXKernelAppRecord *)appRecord
{
  if (_isAnimatingAppTransition) {
    return;
  }
  EXAppViewController *viewControllerToShow = appRecord.viewController;
  EXAppViewController *viewControllerToHide;
  if (viewControllerToShow != self.contentViewController) {
    _isAnimatingAppTransition = YES;
    if (self.contentViewController) {
      viewControllerToHide = (EXAppViewController *)self.contentViewController;
    }
    if (viewControllerToShow) {
      [viewControllerToShow willMoveToParentViewController:self];
      [self.view addSubview:viewControllerToShow.view];
    }

    __weak typeof(self) weakSelf = self;
    void (^transitionFinished)(void) = ^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (strongSelf) {
        if (viewControllerToHide) {
          [viewControllerToHide willMoveToParentViewController:nil];
          [viewControllerToHide.view removeFromSuperview];
          [viewControllerToHide didMoveToParentViewController:nil];
        }
        if (viewControllerToShow) {
          [viewControllerToShow didMoveToParentViewController:strongSelf];
          strongSelf.contentViewController = viewControllerToShow;
        }
        [strongSelf.view setNeedsLayout];
        strongSelf.isAnimatingAppTransition = NO;
        if (strongSelf.delegate) {
          [strongSelf.delegate viewController:strongSelf didNavigateAppToVisible:appRecord];
        }
      }
    };
    
    BOOL animated = (viewControllerToHide && viewControllerToShow);
    if (animated) {
      if (viewControllerToHide.contentView) {
        viewControllerToHide.contentView.transform = CGAffineTransformIdentity;
        viewControllerToHide.contentView.alpha = 1.0f;
      }
      if (viewControllerToShow.contentView) {
        viewControllerToShow.contentView.transform = CGAffineTransformMakeScale(1.1f, 1.1f);
        viewControllerToShow.contentView.alpha = 0;
      }
      [UIView animateWithDuration:0.3f animations:^{
        if (viewControllerToHide.contentView) {
          viewControllerToHide.contentView.transform = CGAffineTransformMakeScale(0.95f, 0.95f);
          viewControllerToHide.contentView.alpha = 0.5f;
        }
        if (viewControllerToShow.contentView) {
          viewControllerToShow.contentView.transform = CGAffineTransformIdentity;
          viewControllerToShow.contentView.alpha = 1.0f;
        }
      } completion:^(BOOL finished) {
        transitionFinished();
      }];
    } else {
      transitionFinished();
    }
  }
}

- (void)_animateMenuToVisible:(BOOL)visible completion:(void (^ _Nullable)(void))completion
{
  _isAnimatingMenu = YES;
  __weak typeof(self) weakSelf = self;
  if (visible) {
    [_menuViewController willMoveToParentViewController:self];
    [self.view addSubview:_menuViewController.view];
    _menuViewController.view.alpha = 0.0f;
    _menuViewController.view.transform = CGAffineTransformMakeScale(1.1f, 1.1f);
    [UIView animateWithDuration:0.1f animations:^{
      _menuViewController.view.alpha = 1.0f;
      _menuViewController.view.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (strongSelf) {
        strongSelf.isAnimatingMenu = NO;
        [strongSelf.menuViewController didMoveToParentViewController:self];
        if (completion) {
          completion();
        }
      }
    }];
  } else {
    _menuViewController.view.alpha = 1.0f;
    [UIView animateWithDuration:0.1f animations:^{
      _menuViewController.view.alpha = 0.0f;
    } completion:^(BOOL finished) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (strongSelf) {
        strongSelf.isAnimatingMenu = NO;
        [strongSelf.menuViewController willMoveToParentViewController:nil];
        [strongSelf.menuViewController.view removeFromSuperview];
        [strongSelf.menuViewController didMoveToParentViewController:nil];
        if (completion) {
          completion();
        }
      }
    }];
  }
}

- (EXHomeAppManager *)_getHomeAppManager
{
  return (EXHomeAppManager *)[EXKernel sharedInstance].appRegistry.homeAppRecord.appManager;
}

- (void)_maybeResetNuxState
{
  // used by appetize: optionally disable nux
  BOOL disableNuxDefaultsValue = [[NSUserDefaults standardUserDefaults] boolForKey:kEXHomeDisableNuxDefaultsKey];
  if (disableNuxDefaultsValue) {
    [self setIsNuxFinished:YES];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kEXHomeDisableNuxDefaultsKey];
  }
}

@end

NS_ASSUME_NONNULL_END
