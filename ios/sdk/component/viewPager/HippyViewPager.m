/*!
 * iOS SDK
 *
 * Tencent is pleased to support the open source community by making
 * Hippy available.
 *
 * Copyright (C) 2019 THL A29 Limited, a Tencent company.
 * All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "HippyViewPager.h"
#import "UIView+Hippy.h"
#import "HippyLog.h"
#import "float.h"
#import "HippyViewPagerItem.h"
#import "HippyI18nUtils.h"


static NSString *const HippyPageScrollStateKey = @"pageScrollState";
static NSString *const HippyPageScrollStateIdle = @"idle";
static NSString *const HippyPageScrollStateSettling = @"settling";
static NSString *const HippyPageScrollStateDragging = @"dragging";


@interface HippyViewPager ()
@property (nonatomic, strong) NSMutableArray<UIView *> *viewPagerItems;
@property (nonatomic, assign) BOOL isScrolling;
@property (nonatomic, assign) BOOL loadOnce;

@property (nonatomic, assign) CGRect previousFrame;
@property (nonatomic, assign) CGSize previousSize;
@property (nonatomic, copy) NSHashTable<id<UIScrollViewDelegate>> *scrollViewListener;
@property (nonatomic, strong) NSHashTable<id<HippyScrollableLayoutDelegate>> *layoutDelegates;
@property (nonatomic, assign) NSUInteger lastPageIndex;
@property (nonatomic, assign) CGFloat targetContentOffsetX;
@property (nonatomic, assign) BOOL didFirstTimeLayout;
@property (nonatomic, assign) BOOL needsLayoutItems;
@property (nonatomic, assign) BOOL needsResetPageIndex;

@property (nonatomic, assign) CGFloat previousStopOffset;
@property (nonatomic, assign) NSUInteger lastPageSelectedCallbackIndex;

/// A weak property used to record the currently displayed item,
/// which is used for updating the page index when the data changes.
@property (nonatomic, weak) UIView *lastSelectedPageItem;

@end

@implementation HippyViewPager
#pragma mark life cycle
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.viewPagerItems = [NSMutableArray new];
        self.pagingEnabled = YES;
        self.contentOffset = CGPointZero;
        self.contentInset = UIEdgeInsetsZero;
        self.delegate = self;
        self.showsHorizontalScrollIndicator = NO;
        self.showsVerticalScrollIndicator = NO;
        self.previousFrame = CGRectZero;
        self.scrollViewListener = [NSHashTable weakObjectsHashTable];
        self.lastPageIndex = NSUIntegerMax;
        self.lastPageSelectedCallbackIndex = NSUIntegerMax;
        self.targetContentOffsetX = CGFLOAT_MAX;
        if (@available(iOS 11.0, *)) {
            self.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        }
        if (NSWritingDirectionRightToLeft ==  [[HippyI18nUtils sharedInstance] writingDirectionForCurrentAppLanguage]) {
            self.transform = CGAffineTransformMakeRotation(M_PI);
        }
    }
    return self;
}

#pragma mark hippy native methods

- (void)insertHippySubview:(UIView *)view atIndex:(NSInteger)atIndex {
    if (atIndex > self.viewPagerItems.count) {
        HippyLogWarn(@"Error In HippyViewPager: addSubview —— out of bound of array");
        return;
    }
    if (atIndex < [self.viewPagerItems count]) {
        UIView *viewAtIndex = [self.viewPagerItems objectAtIndex:atIndex];
        view.frame = viewAtIndex.frame;
    }
    if (NSWritingDirectionRightToLeft ==  [[HippyI18nUtils sharedInstance] writingDirectionForCurrentAppLanguage]) {
        view.transform = CGAffineTransformMakeRotation(M_PI);
    }
    [super insertHippySubview:view atIndex:(NSInteger)atIndex];
    [self.viewPagerItems insertObject:view atIndex:atIndex];
    
    if ([view isKindOfClass:[HippyViewPagerItem class]]) {
        HippyViewPagerItem *item = (HippyViewPagerItem *)view;
        __weak HippyViewPager *weakPager = self;
        __weak UIView *weakItem = item;
        item.frameSetBlock = ^CGRect(CGRect frame) {
            if (weakPager) {
                HippyViewPager *strongPager = weakPager;
                UIView *strongItem = weakItem;
                if (strongItem) {
                    NSUInteger index = [strongPager.viewPagerItems indexOfObject:strongItem];
                    CGRect finalFrame = [strongPager frameForItemAtIndex:index];
                    return finalFrame;
                }
            }
            return frame;
        };
    }
    
    self.needsLayoutItems = YES;
    if (_itemsChangedBlock) {
        _itemsChangedBlock([self.viewPagerItems count]);
    }
}

- (CGRect)frameForItemAtIndex:(NSInteger)index {
    CGSize viewPagerSize = self.bounds.size;
    CGFloat originX = viewPagerSize.width * index;
    return CGRectMake(originX, 0, viewPagerSize.width, viewPagerSize.height);
}

- (void)removeHippySubview:(UIView *)subview {
    [super removeHippySubview:subview];
    [self.viewPagerItems removeObject:subview];
    [self setNeedsLayout];
    if (_itemsChangedBlock) {
        _itemsChangedBlock([self.viewPagerItems count]);
    }
}

- (void)hippySetFrame:(CGRect)frame {
    if (!CGRectEqualToRect(self.bounds, frame)) {
        [super hippySetFrame:frame];
        self.needsLayoutItems = YES;
        self.needsResetPageIndex = YES;
        [self setNeedsLayout];
    }
}

- (void)didUpdateHippySubviews {
    [super didUpdateHippySubviews];
    self.needsLayoutItems = YES;
    
    // Update the latest page index based on the currently displayed item (aka lastSelectedPageItem).
    // Keep the same logic as android:
    // 1. If the previous item only changes its location,
    //    update the current location and keep the current item displayed.
    // 2. If the previous item does not exist, do not adjust the position,
    //    but keep the current position in the valid range (that is, 0 ~ count-1).
    UIView *previousSelectedItem = self.lastSelectedPageItem;
    NSUInteger updatedPageIndex;
    if (previousSelectedItem) {
        updatedPageIndex = [self.viewPagerItems indexOfObject:previousSelectedItem];
    } else {
        updatedPageIndex = MAX(0, MIN(self.lastPageIndex, self.viewPagerItems.count - 1));
    }
    if (self.lastPageIndex != updatedPageIndex) {
        self.lastPageIndex = updatedPageIndex;
        self.needsResetPageIndex = YES;
    }
    
    [self setNeedsLayout];
}

- (void)invalidate {
    [_scrollViewListener removeAllObjects];
}

#pragma mark hippy js call methods
- (void)setPage:(NSInteger)pageNumber animated:(BOOL)animated {
    if (pageNumber >= self.viewPagerItems.count || pageNumber < 0) {
        HippyLogWarn(@"Error In ViewPager setPage: pageNumber invalid");
        return;
    }

    _lastPageIndex = pageNumber;
    UIView *theItem = self.viewPagerItems[pageNumber];
    self.lastSelectedPageItem = theItem;
    self.targetContentOffsetX = CGRectGetMinX(theItem.frame);
    [self setContentOffset:theItem.frame.origin animated:animated];
    [self invokePageSelected:pageNumber];
    
    if (animated) {
        if (self.onPageScrollStateChanged) {
            HippyLogTrace(@"[HippyViewPager] settling --- (setPage withAnimation)");
            self.onPageScrollStateChanged(@{ HippyPageScrollStateKey: HippyPageScrollStateSettling });
        }
    } else {
        if (self.onPageScrollStateChanged) {
            HippyLogTrace(@"[HippyViewPager] idle ~~~~~~ (setPage withoutAnimation)");
            self.onPageScrollStateChanged(@{ HippyPageScrollStateKey: HippyPageScrollStateIdle });
        }
        // Record stop offset for onPageScroll callback
        [self recordScrollStopOffsetX];
    }
}

#pragma mark scrollview delegate methods
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {

    CGFloat currentContentOffset = self.contentOffset.x;
    CGFloat pageWidth = CGRectGetWidth(self.bounds);
    CGFloat offset = currentContentOffset - self.previousStopOffset;
    CGFloat offsetRatio = fmod((offset / pageWidth), 1.0 + DBL_EPSILON);
    
    // get current base page index
    NSUInteger currentPageIndex = floor(currentContentOffset / pageWidth);
    
    // If offsetRatio is 1.0, then currentPageIndex is nextPageIndex, else nextPageIndex add/subtract 1.
    // The theoretical maximum gap is 2 DBL_EPSILON, take 10 to allow for some redundancy.
    BOOL isRatioEqualTo1 = (fabs(ceil(offsetRatio) - offsetRatio) < 10 * DBL_EPSILON);
    NSInteger nextPageIndex = isRatioEqualTo1  ? currentPageIndex : currentPageIndex + ceil(offsetRatio);
    if (nextPageIndex < 0) {
        nextPageIndex = 0;
    } else if (nextPageIndex >= [self.viewPagerItems count]) {
        nextPageIndex = [self.viewPagerItems count] - 1;
    }
    
    if (self.onPageScroll) {
        HippyLogTrace(@"[HippyViewPager] CurrentPage:%ld NextPage:%ld Ratio:%f, %f-%f-%f",
                      currentPageIndex, nextPageIndex, offsetRatio, pageWidth, currentContentOffset, offset);
        self.onPageScroll(@{
            @"position": @(nextPageIndex),
            @"offset": @(offsetRatio),
        });
    }
    
    for (NSObject<UIScrollViewDelegate> *scrollViewListener in _scrollViewListener) {
        if ([scrollViewListener respondsToSelector:@selector(scrollViewDidScroll:)]) {
            [scrollViewListener scrollViewDidScroll:scrollView];
        }
    }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    self.isScrolling = YES;
    self.targetContentOffsetX = CGFLOAT_MAX;
    for (NSObject<UIScrollViewDelegate> *scrollViewListener in _scrollViewListener) {
        if ([scrollViewListener respondsToSelector:@selector(scrollViewWillBeginDragging:)]) {
            [scrollViewListener scrollViewWillBeginDragging:scrollView];
        }
    }
    if (self.onPageScrollStateChanged) {
        HippyLogTrace(@"[HippyViewPager] dragging --- (BeginDragging)");
        self.onPageScrollStateChanged(@{ HippyPageScrollStateKey : HippyPageScrollStateDragging });
    }
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset {
    // Note: In rare exception scenarios, targetContentOffset may deviate from expectations,
    //   adding protection for this extreme scenario.
    // Trigger condition: 
    //   The expected scrolling range is more than 1 page item,
    //   and targetOffsetX is in the opposite direction of the drag.
    CGFloat currentOffsetX = self.contentOffset.x;
    CGFloat targetOffsetX = targetContentOffset->x;
    CGFloat pageWidth = CGRectGetWidth(self.bounds);
    if (pageWidth > DBL_EPSILON && fabs(targetOffsetX - currentOffsetX) > pageWidth &&
        (velocity.x) * (targetOffsetX - currentOffsetX) < DBL_EPSILON) {
        // Corrected value is calculated in the same way as in the scrollViewDidScroll method,
        // taking the next nearest item.
        CGFloat offsetDelta = currentOffsetX - self.previousStopOffset;
        CGFloat offsetRatio = fmod((offsetDelta / CGRectGetWidth(self.bounds)), 1.0 + DBL_EPSILON);
        NSUInteger currentPageIndex = [self currentPageIndex];
        NSInteger nextPageIndex = ceil(offsetRatio) == offsetRatio ? currentPageIndex : currentPageIndex + ceil(offsetRatio);
        if (nextPageIndex < 0) {
            nextPageIndex = 0;
        } else if (nextPageIndex >= [self.viewPagerItems count]) {
            nextPageIndex = [self.viewPagerItems count] - 1;
        }
        
        UIView *theItem = self.viewPagerItems[nextPageIndex];
        CGFloat correctedOffsetX = CGRectGetMinX(theItem.frame);
        targetContentOffset->x = correctedOffsetX;
        HippyLogWarn(@"Unexpected targetContentOffsetX(%f) received in HippyViewPager!\n"
                     "ScrollView:%@, current offset:%f, velocity:%f\n"
                     "Auto corrected to %f", targetOffsetX, scrollView, currentOffsetX, velocity.x, correctedOffsetX);
    }
    
    self.targetContentOffsetX = targetContentOffset->x;
    NSUInteger page = [self targetPageIndexFromTargetContentOffsetX:self.targetContentOffsetX];
    [self invokePageSelected:page];
    for (NSObject<UIScrollViewDelegate> *scrollViewListener in _scrollViewListener) {
        if ([scrollViewListener respondsToSelector:@selector(scrollViewWillEndDragging:withVelocity:targetContentOffset:)]) {
            [scrollViewListener scrollViewWillEndDragging:scrollView withVelocity:velocity targetContentOffset:targetContentOffset];
        }
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    for (NSObject<UIScrollViewDelegate> *scrollViewListener in _scrollViewListener) {
        if ([scrollViewListener respondsToSelector:@selector(scrollViewDidEndDragging:willDecelerate:)]) {
            [scrollViewListener scrollViewDidEndDragging:scrollView willDecelerate:decelerate];
        }
    }
    if (!decelerate) {
        self.isScrolling = NO;
    }
    if (self.onPageScrollStateChanged) {
        NSString *state = decelerate ? HippyPageScrollStateSettling : HippyPageScrollStateIdle;
        HippyLogTrace(@"[HippyViewPager] %@ ??? (EndDragging)", state);
        self.onPageScrollStateChanged(@{ HippyPageScrollStateKey : state });
    }
}

- (void)scrollViewWillBeginDecelerating:(UIScrollView *)scrollView {
    for (NSObject<UIScrollViewDelegate> *scrollViewListener in _scrollViewListener) {
        if ([scrollViewListener respondsToSelector:@selector(scrollViewWillBeginDecelerating:)]) {
            [scrollViewListener scrollViewWillBeginDecelerating:scrollView];
        }
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (self.onPageScrollStateChanged) {
        HippyLogTrace(@"[HippyViewPager] idle ~~~~~~ (EndDecelerating)");
        self.onPageScrollStateChanged(@{ HippyPageScrollStateKey : HippyPageScrollStateIdle });
    }
    self.isScrolling = NO;
    for (NSObject<UIScrollViewDelegate> *scrollViewListener in _scrollViewListener) {
        if ([scrollViewListener respondsToSelector:@selector(scrollViewDidEndDecelerating:)]) {
            [scrollViewListener scrollViewDidEndDecelerating:scrollView];
        }
    }
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    self.isScrolling = NO;
    if (self.onPageScrollStateChanged) {
        HippyLogTrace(@"[HippyViewPager] idle ~~~~~~ (DidEndScrollingAnimation)");
        self.onPageScrollStateChanged(@{ HippyPageScrollStateKey : HippyPageScrollStateIdle });
    }
    
    for (NSObject<UIScrollViewDelegate> *scrollViewListener in _scrollViewListener) {
        if ([scrollViewListener respondsToSelector:@selector(scrollViewDidEndScrollingAnimation:)]) {
            [scrollViewListener scrollViewDidEndScrollingAnimation:scrollView];
        }
    }
}

- (void)scrollViewDidScrollToTop:(UIScrollView *)scrollView {
    for (NSObject<UIScrollViewDelegate> *scrollViewListener in _scrollViewListener) {
        if ([scrollViewListener respondsToSelector:@selector(scrollViewDidScrollToTop:)]) {
            [scrollViewListener scrollViewDidScrollToTop:scrollView];
        }
    }
}

- (void)recordScrollStopOffsetX {
    // Delay a bit to avoid recording offset of unfinished state
    dispatch_async(dispatch_get_main_queue(), ^{
        self.previousStopOffset = [self contentOffset].x;
    });
}

#pragma mark - scrollview listener methods

- (UIScrollView *)realScrollView {
    return self;
}

- (NSHashTable *)scrollListeners {
    return _scrollViewListener;
}

- (void)addScrollListener:(id<UIScrollViewDelegate>)scrollListener {
    [_scrollViewListener addObject:scrollListener];
}

- (void)removeScrollListener:(id<UIScrollViewDelegate>)scrollListener {
    [_scrollViewListener removeObject:scrollListener];
}

- (void)addHippyScrollableLayoutDelegate:(id<HippyScrollableLayoutDelegate>)delegate {
    HippyAssertMainThread();
    if (!self.layoutDelegates) {
        self.layoutDelegates = [NSHashTable weakObjectsHashTable];
    }
    [self.layoutDelegates addObject:delegate];
}

- (void)removeHippyScrollableLayoutDelegate:(id<HippyScrollableLayoutDelegate>)delegate {
    HippyAssertMainThread();
    [self.layoutDelegates removeObject:delegate];
}

#pragma mark other methods
- (NSUInteger)currentPageIndex {
    return [self pageIndexForContentOffset:self.contentOffset.x];
}

- (NSUInteger)pageIndexForContentOffset:(CGFloat)offset {
    CGFloat pageWidth = CGRectGetWidth(self.bounds);
    NSUInteger page = floor(offset / pageWidth);
    return page;
}

- (void)setIsScrolling:(BOOL)isScrolling {
    if (!isScrolling) {
        [self recordScrollStopOffsetX];
    }
    _isScrolling = isScrolling;
}

- (void)invokePageSelected:(NSUInteger)index {
    if (self.onPageSelected &&
        self.lastPageSelectedCallbackIndex != index &&
        index < [[self viewPagerItems] count]) {
        self.lastPageSelectedCallbackIndex = index;
        self.onPageSelected(@{ @"position": @(index)});
    }
}

- (NSUInteger)targetPageIndexFromTargetContentOffsetX:(CGFloat)targetContentOffsetX {
    NSInteger thePage = -1;
    if (fabs(targetContentOffsetX) < FLT_EPSILON) {
        thePage = 0;
    } else {
        for (int i = 0; i < self.viewPagerItems.count; i++) {
            UIView *pageItem = self.viewPagerItems[i];
            CGPoint point = [self middlePointOfView:pageItem];
            if (point.x > targetContentOffsetX) {
                thePage = i;
                break;
            }
        }
    }
    if (thePage == -1) {
        thePage = 0;
    } else if (thePage >= self.viewPagerItems.count) {
        thePage = self.viewPagerItems.count - 1;
    }
    if (_lastPageIndex != thePage) {
        _lastPageIndex = thePage;
        _lastSelectedPageItem = self.viewPagerItems[thePage];
        return thePage;
    } else {
        return _lastPageIndex;
    }
}

- (NSUInteger)pageCount {
    return [_viewPagerItems count];
}

- (void)setContentOffset:(CGPoint)contentOffset {
    _targetOffset = contentOffset;
    [super setContentOffset:contentOffset];
}

- (void)setContentOffset:(CGPoint)contentOffset animated:(BOOL)animated {
    if (CGPointEqualToPoint(contentOffset, self.contentOffset)) {
        return;
    }
    _targetOffset = contentOffset;
    [super setContentOffset:contentOffset animated:animated];
}

- (void)hippyBridgeDidFinishTransaction {
    BOOL isFrameEqual = CGRectEqualToRect(self.frame, self.previousFrame);
    BOOL isContentSizeEqual = CGSizeEqualToSize(self.contentSize, self.previousSize);
    if (!isContentSizeEqual || !isFrameEqual) {
        self.previousFrame = self.frame;
        self.previousSize = self.contentSize;
        self.needsLayoutItems = YES;
        [self setNeedsLayout];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!self.needsLayoutItems) {
        return;
    }
    self.needsLayoutItems = NO;
    if (!self.viewPagerItems.count) {
        return;
    }
    for (int i = 0; i < self.viewPagerItems.count; i++) {
        UIView *item = [self.viewPagerItems objectAtIndex:i];
        item.frame = [self frameForItemAtIndex:i];
    }

    if (self.initialPage >= self.viewPagerItems.count) {
        HippyLogWarn(@"Error In HippyViewPager: layoutSubviews");
        self.contentSize = CGSizeZero;
        return;
    }

    UIView *lastViewPagerItem = self.viewPagerItems.lastObject;
    if (!lastViewPagerItem) {
        HippyLogWarn(@"Error In HippyViewPager: addSubview");
        self.contentSize = CGSizeZero;
        return;
    }

    CGSize updatedSize = CGSizeMake(lastViewPagerItem.frame.origin.x + lastViewPagerItem.frame.size.width,
                                    lastViewPagerItem.frame.origin.y + lastViewPagerItem.frame.size.height);
    if (!CGSizeEqualToSize(self.contentSize, updatedSize)) {
        self.contentSize = updatedSize;
    }
    
    if (!_didFirstTimeLayout) {
        [self setPage:self.initialPage animated:NO];
        _didFirstTimeLayout = YES;
        self.needsResetPageIndex= NO;
    } else {
        if (self.needsResetPageIndex) {
            [self setPage:_lastPageIndex animated:NO];
            self.needsResetPageIndex= NO;
        }
    }
    
    // Notify delegates of HippyScrollableLayoutDelegate
    for (id<HippyScrollableLayoutDelegate> layoutDelegate in self.layoutDelegates) {
        if ([layoutDelegate respondsToSelector:@selector(scrollableDidLayout:)]) {
            [layoutDelegate scrollableDidLayout:self];
        }
    }
}

- (NSUInteger)nowPage {
    CGFloat nowX = self.contentOffset.x;
    NSInteger thePage = -1;
    if (fabs(nowX) < FLT_EPSILON) {
        return 0;
    }
    for (int i = 0; i < self.viewPagerItems.count; i++) {
        UIView *pageItem = self.viewPagerItems[i];
        CGPoint point = [self middlePointOfView:pageItem];
        if (point.x > nowX) {
            thePage = i;
            break;
        }
    }

    if (thePage < 0) {
        HippyLogWarn(@"Error In ViewPager nowPage: thePage invalid");
        return 0;
    } else {
        return (NSUInteger)thePage;
    }
}

//计算某个view的frame的右上角顶点的坐标
- (CGPoint)rightPointOfView:(UIView *)view {
    CGFloat x = view.frame.origin.x + view.frame.size.width;
    CGFloat y = view.frame.origin.y;
    return CGPointMake(x, y);
}

- (CGPoint)middlePointOfView:(UIView *)view {
    CGFloat x = view.frame.origin.x + view.frame.size.width * 0.5;
    CGFloat y = view.frame.origin.y;
    return CGPointMake(x, y);
}

//自动翻页
- (void)autoPageDown {
    //滚动流程中不允许轮播
    if (self.isScrolling) {
        return;
    }
    NSInteger nextPage = self.nowPage + 1;
    if (nextPage < self.viewPagerItems.count) {
        [self setPage:nextPage animated:YES];
    }
}

@end
