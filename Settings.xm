// Tweaks/YTLocalQueue/Settings.xm
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "LocalQueueManager.h"
#import "LocalQueueViewController.h"

// ---------------------------------------------------------------------------
// Typed interfaces for the YouTube settings classes we use.
//
// IMPORTANT (crash fix): the previous version built switch items via a
// hand-written objc_msgSend cast:
//
//   ((id (*)(id, SEL, id, id, id, BOOL, BOOL(^)(id,BOOL), NSInteger))objc_msgSend)(...)
//
// On arm64e that is fragile: the BOOL (1 byte) argument followed by a block
// pointer can be marshalled into the wrong register, so when the switch is
// toggled YouTube reads the "switchBlock" from a bad slot and ARC retains a
// garbage pointer -> EXC_BAD_ACCESS in objc_retain on every toggle.
//
// The fix is to call the real, typed Objective-C methods (exactly as
// PoomSmart's tweaks do), letting the compiler emit the correct ABI.
// ---------------------------------------------------------------------------

@interface YTSettingsSectionItem : NSObject
+ (instancetype)switchItemWithTitle:(NSString *)title
                   titleDescription:(NSString *)titleDescription
            accessibilityIdentifier:(NSString *)accessibilityIdentifier
                           switchOn:(BOOL)switchOn
                        switchBlock:(BOOL (^)(id cell, BOOL enabled))switchBlock
                      settingItemId:(NSInteger)settingItemId;

+ (instancetype)itemWithTitle:(NSString *)title
             titleDescription:(NSString *)titleDescription
      accessibilityIdentifier:(NSString *)accessibilityIdentifier
              detailTextBlock:(NSString * (^)(void))detailTextBlock
                  selectBlock:(BOOL (^)(id cell, NSUInteger arg))selectBlock;
@end

@interface YTUIUtilsCompat : NSObject
@end

static const NSInteger YTLocalQueueSection = 931; // unique tweak section id
static NSString *const kYTLPVersion = @"0.0.1+build22";

static BOOL YTLP_AutoAdvanceEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"ytlp_queue_auto_advance_enabled"];
}

static BOOL YTLP_ShowPlayNextButton(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"ytlp_show_play_next_button"] == nil) {
        return YES; // Default: on
    }
    return [defaults boolForKey:@"ytlp_show_play_next_button"];
}

static BOOL YTLP_ShowQueueButton(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"ytlp_show_queue_button"] == nil) {
        return YES; // Default: on
    }
    return [defaults boolForKey:@"ytlp_show_queue_button"];
}

// Small helper to show a HUD message safely.
static void ytlp_showHUD(NSString *message) {
    Class HUD = objc_getClass("GOOHUDManagerInternal");
    Class HUDMsg = objc_getClass("YTHUDMessage");
    if (HUD && HUDMsg) {
        id hudInstance = ((id (*)(id, SEL))objc_msgSend)(HUD, sel_getUid("sharedInstance"));
        id hudMsg = ((id (*)(id, SEL, id))objc_msgSend)(HUDMsg, sel_getUid("messageWithText:"), message);
        if (hudInstance && hudMsg) {
            ((void (*)(id, SEL, id))objc_msgSend)(hudInstance, sel_getUid("showMessageMainThread:"), hudMsg);
        }
    }
}

// Build section items via typed method calls (safe ABI).
static NSArray *ytlp_buildSectionItems(void) {
    NSMutableArray *items = [NSMutableArray array];
    Class SectionItemClass = objc_getClass("YTSettingsSectionItem");
    if (!SectionItemClass) return items;

    // Guard: only proceed if the class actually responds to the switch selector
    // on this YouTube build. If not, we simply skip the toggles rather than
    // crash.
    SEL switchSel = @selector(switchItemWithTitle:titleDescription:accessibilityIdentifier:switchOn:switchBlock:settingItemId:);
    BOOL hasSwitch = [SectionItemClass respondsToSelector:switchSel];

    if (hasSwitch) {
        // Auto advance toggle
        id enableAuto = [YTSettingsSectionItem
            switchItemWithTitle:@"Auto advance"
               titleDescription:@"Automatically play next item from local queue when video ends"
        accessibilityIdentifier:nil
                       switchOn:YTLP_AutoAdvanceEnabled()
                    switchBlock:^BOOL(id cell, BOOL enabled) {
                        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"ytlp_queue_auto_advance_enabled"];
                        return YES;
                    }
                  settingItemId:0];
        if (enableAuto) [items addObject:enableAuto];

        // Show Play Next button toggle
        id showPlayNext = [YTSettingsSectionItem
            switchItemWithTitle:@"Show Play Next button"
               titleDescription:@"Show the Play Next button in the video player overlay"
        accessibilityIdentifier:nil
                       switchOn:YTLP_ShowPlayNextButton()
                    switchBlock:^BOOL(id cell, BOOL enabled) {
                        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"ytlp_show_play_next_button"];
                        return YES;
                    }
                  settingItemId:0];
        if (showPlayNext) [items addObject:showPlayNext];

        // Show Queue button toggle
        id showQueue = [YTSettingsSectionItem
            switchItemWithTitle:@"Show Queue button"
               titleDescription:@"Show the Queue button in the video player overlay"
        accessibilityIdentifier:nil
                       switchOn:YTLP_ShowQueueButton()
                    switchBlock:^BOOL(id cell, BOOL enabled) {
                        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"ytlp_show_queue_button"];
                        return YES;
                    }
                  settingItemId:0];
        if (showQueue) [items addObject:showQueue];
    }

    SEL itemSel = @selector(itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:selectBlock:);
    BOOL hasItem = [SectionItemClass respondsToSelector:itemSel];

    if (hasItem) {
        // Open Local Queue
        id openUI = [YTSettingsSectionItem
            itemWithTitle:@"Open Local Queue"
         titleDescription:nil
  accessibilityIdentifier:nil
          detailTextBlock:nil
              selectBlock:^BOOL(id cell, NSUInteger arg1) {
                  Class UIUtils = objc_getClass("YTUIUtils");
                  UIViewController *presenting = nil;
                  if (UIUtils && [UIUtils respondsToSelector:sel_getUid("topViewControllerForPresenting")]) {
                      presenting = ((id (*)(id, SEL))objc_msgSend)(UIUtils, sel_getUid("topViewControllerForPresenting"));
                  }
                  if (!presenting) return NO;
                  YTLPLocalQueueViewController *vc = [[YTLPLocalQueueViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
                  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
                  [presenting presentViewController:nav animated:YES completion:nil];
                  return YES;
              }];
        if (openUI) [items addObject:openUI];

        // Clear Local Queue
        id clear = [YTSettingsSectionItem
            itemWithTitle:@"Clear Local Queue"
         titleDescription:nil
  accessibilityIdentifier:nil
          detailTextBlock:nil
              selectBlock:^BOOL(id cell, NSUInteger arg1) {
                  NSInteger count = [[YTLPLocalQueueManager shared] allItems].count;
                  [[YTLPLocalQueueManager shared] clear];
                  NSString *message = (count > 0)
                      ? [NSString stringWithFormat:@"Cleared %ld video%@", (long)count, count == 1 ? @"" : @"s"]
                      : @"Queue is empty";
                  ytlp_showHUD(message);
                  return YES;
              }];
        if (clear) [items addObject:clear];

        // Version info (non-interactive)
        id versionItem = [YTSettingsSectionItem
            itemWithTitle:[NSString stringWithFormat:@"Version %@", kYTLPVersion]
         titleDescription:nil
  accessibilityIdentifier:nil
          detailTextBlock:nil
              selectBlock:^BOOL(id cell, NSUInteger arg1) { return NO; }];
        if (versionItem) [items addObject:versionItem];
    }

    return items;
}

// Originals
typedef NSArray* (*SettingsCategoryOrderIMP)(id, SEL);
static SettingsCategoryOrderIMP origSettingsCategoryOrder = NULL;

typedef NSArray* (*OrderedCategoriesIMP)(id, SEL);
static OrderedCategoriesIMP origOrderedCategories = NULL;

typedef NSMutableArray* (*TweaksClassIMP)(id, SEL);
static TweaksClassIMP origTweaksList = NULL;

typedef void (*UpdateSectionIMP)(id, SEL, NSUInteger, id);
static UpdateSectionIMP origUpdateSection = NULL;

// Replacements
static NSArray* ytlp_settingsCategoryOrder(id self, SEL _cmd) {
    NSArray *order = origSettingsCategoryOrder ? origSettingsCategoryOrder(self, _cmd) : nil;
    if (![order isKindOfClass:[NSArray class]]) return order;
    NSUInteger insertIndex = [order indexOfObject:@(1)];
    if (insertIndex != NSNotFound) {
        NSMutableArray *mut = [order mutableCopy];
        [mut insertObject:@(YTLocalQueueSection) atIndex:insertIndex + 1];
        order = [mut copy];
    }
    return order;
}

static NSArray* ytlp_orderedCategories(id self, SEL _cmd) {
    BOOL isType1 = NO;
    SEL selType = sel_getUid("type");
    if ([self respondsToSelector:selType]) {
        int (*typeCall)(id, SEL) = (int (*)(id, SEL))objc_msgSend;
        isType1 = (typeCall(self, selType) == 1);
    }
    NSArray *orig = origOrderedCategories ? origOrderedCategories(self, _cmd) : nil;
    if (!isType1) return orig;
    Class GroupData = objc_getClass("YTSettingsGroupData");
    if (GroupData && class_getClassMethod(GroupData, sel_getUid("tweaks"))) return orig;
    NSMutableArray *mutArr = [orig isKindOfClass:[NSArray class]] ? [orig mutableCopy] : [NSMutableArray array];
    [mutArr insertObject:@(YTLocalQueueSection) atIndex:0];
    return [mutArr copy];
}

static NSMutableArray* ytlp_tweaksList(id cls, SEL _cmd) {
    NSMutableArray *arr = origTweaksList ? origTweaksList(cls, _cmd) : [NSMutableArray array];
    if ([arr isKindOfClass:[NSMutableArray class]]) {
        NSNumber *cat = @(YTLocalQueueSection);
        if (![arr containsObject:cat]) [arr addObject:cat];
    }
    return arr;
}

static void ytlp_updateSection(id self, SEL _cmd, NSUInteger category, id entry) {
    if (category == (NSUInteger)YTLocalQueueSection) {
        id delegate = nil;
        @try { delegate = [self valueForKey:@"_dataDelegate"]; } @catch (__unused NSException *e) {}
        NSArray *items = ytlp_buildSectionItems();
        SEL selWithIcon = sel_getUid("setSectionItems:forCategory:title:icon:titleDescription:headerHidden:");
        SEL selNoIcon   = sel_getUid("setSectionItems:forCategory:title:titleDescription:headerHidden:");
        if (delegate && [delegate respondsToSelector:selWithIcon]) {
            ((void (*)(id, SEL, id, NSUInteger, id, id, id, BOOL))objc_msgSend)(delegate, selWithIcon, items, (NSUInteger)YTLocalQueueSection, @"Local Queue", nil, nil, NO);
        } else if (delegate && [delegate respondsToSelector:selNoIcon]) {
            ((void (*)(id, SEL, id, NSUInteger, id, id, BOOL))objc_msgSend)(delegate, selNoIcon, items, (NSUInteger)YTLocalQueueSection, @"Local Queue", nil, NO);
        }
        return;
    }
    if (origUpdateSection) origUpdateSection(self, _cmd, category, entry);
}

__attribute__((constructor)) static void YTLP_InstallSettingsHooks(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        __block int attemptsRemaining = 20; // ~10s max with 0.5s intervals
        __block void (^tryInstallHolder)(void) = nil;

        void (^tryInstall)(void) = ^{
            BOOL allInstalled = YES;

            Class Class1 = objc_getClass("YTAppSettingsPresentationData");
            if (Class1) {
                Method m = class_getClassMethod(Class1, sel_getUid("settingsCategoryOrder"));
                if (m && !origSettingsCategoryOrder) {
                    origSettingsCategoryOrder = (SettingsCategoryOrderIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_settingsCategoryOrder);
                }
                if (!origSettingsCategoryOrder) allInstalled = NO;
            } else {
                allInstalled = NO;
            }

            Class Class2 = objc_getClass("YTSettingsGroupData");
            if (Class2) {
                Method m = class_getInstanceMethod(Class2, sel_getUid("orderedCategories"));
                if (m && !origOrderedCategories) {
                    origOrderedCategories = (OrderedCategoriesIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_orderedCategories);
                }
                Method mt = class_getClassMethod(Class2, sel_getUid("tweaks"));
                if (mt && !origTweaksList) {
                    origTweaksList = (TweaksClassIMP)method_getImplementation(mt);
                    method_setImplementation(mt, (IMP)ytlp_tweaksList);
                }
                if (!origOrderedCategories) allInstalled = NO;
            } else {
                allInstalled = NO;
            }

            Class Class3 = objc_getClass("YTSettingsSectionItemManager");
            if (Class3) {
                Method m = class_getInstanceMethod(Class3, sel_getUid("updateSectionForCategory:withEntry:"));
                if (m && !origUpdateSection) {
                    origUpdateSection = (UpdateSectionIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_updateSection);
                }
                if (!origUpdateSection) allInstalled = NO;
            } else {
                allInstalled = NO;
            }

            if (allInstalled) {
                tryInstallHolder = nil;
                return;
            }
            if (--attemptsRemaining <= 0) {
                tryInstallHolder = nil;
                return;
            }
            void (^strongTryInstall)(void) = tryInstallHolder;
            if (strongTryInstall) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), strongTryInstall);
            }
        };

        tryInstallHolder = [tryInstall copy];
        tryInstallHolder();
    });
}
