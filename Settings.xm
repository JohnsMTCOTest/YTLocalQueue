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

// NOTE: We deliberately do NOT reference the YTSettingsSectionItem class
// symbol directly. That class lives in the YouTube app binary, not in this
// dylib, so a direct `[YTSettingsSectionItem ...]` call emits an undefined
// link-time symbol (_OBJC_CLASS_$_YTSettingsSectionItem) that makes dyld abort
// at launch ("symbol not found in flat namespace"). Instead we resolve the
// class at runtime via objc_getClass() and send messages through typed
// function-pointer casts of objc_msgSend whose signatures EXACTLY match the
// real methods (correct arm64e ABI -> no toggle crash either).

// Typed block aliases used by the casts below.
typedef BOOL (^YTLPSwitchBlock)(id cell, BOOL enabled);
typedef BOOL (^YTLPSelectBlock)(id cell, NSUInteger arg);
typedef NSString * (^YTLPDetailBlock)(void);

// Build a switch item by sending switchItemWithTitle:... to the runtime class.
static id ytlp_makeSwitchItem(Class cls, NSString *title, NSString *desc,
                              BOOL on, YTLPSwitchBlock block) {
    SEL sel = @selector(switchItemWithTitle:titleDescription:accessibilityIdentifier:switchOn:switchBlock:settingItemId:);
    if (![cls respondsToSelector:sel]) return nil;
    // CRASH FIX: copy the block to the heap. The caller passes a stack block;
    // the switch item stores it and YouTube invokes it LATER (when you toggle).
    // By then the original stack frame is gone, so an un-copied stack block is a
    // dangling pointer -> objc_retain on a garbage address (0x8004...) the moment
    // the switch fires. Heap-copying makes the block outlive this frame.
    YTLPSwitchBlock heapBlock = [block copy];
    id (*send)(Class, SEL, NSString *, NSString *, NSString *, BOOL, YTLPSwitchBlock, NSInteger) =
        (id (*)(Class, SEL, NSString *, NSString *, NSString *, BOOL, YTLPSwitchBlock, NSInteger))objc_msgSend;
    return send(cls, sel, title, desc, nil, on, heapBlock, 0);
}

// Build a plain (tappable) item by sending itemWithTitle:... to the runtime class.
static id ytlp_makeSelectItem(Class cls, NSString *title, YTLPSelectBlock block) {
    SEL sel = @selector(itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:selectBlock:);
    if (![cls respondsToSelector:sel]) return nil;
    // Same heap-copy fix as the switch item: the select block is invoked later
    // (when the row is tapped), so it must outlive this stack frame.
    YTLPSelectBlock heapBlock = [block copy];
    id (*send)(Class, SEL, NSString *, NSString *, NSString *, YTLPDetailBlock, YTLPSelectBlock) =
        (id (*)(Class, SEL, NSString *, NSString *, NSString *, YTLPDetailBlock, YTLPSelectBlock))objc_msgSend;
    return send(cls, sel, title, nil, nil, (YTLPDetailBlock)nil, heapBlock);
}

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

// Build section items via runtime class resolution + typed objc_msgSend casts.
static NSArray *ytlp_buildSectionItems(void) {
    NSMutableArray *items = [NSMutableArray array];
    Class SectionItemClass = objc_getClass("YTSettingsSectionItem");
    if (!SectionItemClass) return items;

    // Auto advance toggle
    id enableAuto = ytlp_makeSwitchItem(SectionItemClass,
        @"Auto advance",
        @"Automatically play next item from local queue when video ends",
        YTLP_AutoAdvanceEnabled(),
        ^BOOL(id cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"ytlp_queue_auto_advance_enabled"];
            return YES;
        });
    if (enableAuto) [items addObject:enableAuto];

    // Show Play Next button toggle
    id showPlayNext = ytlp_makeSwitchItem(SectionItemClass,
        @"Show Play Next button",
        @"Show the Play Next button in the video player overlay",
        YTLP_ShowPlayNextButton(),
        ^BOOL(id cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"ytlp_show_play_next_button"];
            return YES;
        });
    if (showPlayNext) [items addObject:showPlayNext];

    // Show Queue button toggle
    id showQueue = ytlp_makeSwitchItem(SectionItemClass,
        @"Show Queue button",
        @"Show the Queue button in the video player overlay",
        YTLP_ShowQueueButton(),
        ^BOOL(id cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"ytlp_show_queue_button"];
            return YES;
        });
    if (showQueue) [items addObject:showQueue];

    // Open Local Queue
    id openUI = ytlp_makeSelectItem(SectionItemClass,
        @"Open Local Queue",
        ^BOOL(id cell, NSUInteger arg1) {
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
        });
    if (openUI) [items addObject:openUI];

    // Clear Local Queue
    id clear = ytlp_makeSelectItem(SectionItemClass,
        @"Clear Local Queue",
        ^BOOL(id cell, NSUInteger arg1) {
            NSInteger count = [[YTLPLocalQueueManager shared] allItems].count;
            [[YTLPLocalQueueManager shared] clear];
            NSString *message = (count > 0)
                ? [NSString stringWithFormat:@"Cleared %ld video%@", (long)count, count == 1 ? @"" : @"s"]
                : @"Queue is empty";
            ytlp_showHUD(message);
            return YES;
        });
    if (clear) [items addObject:clear];

    // Version info (non-interactive)
    id versionItem = ytlp_makeSelectItem(SectionItemClass,
        [NSString stringWithFormat:@"Version %@", kYTLPVersion],
        ^BOOL(id cell, NSUInteger arg1) { return NO; });
    if (versionItem) [items addObject:versionItem];

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
