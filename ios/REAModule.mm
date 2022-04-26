#import <React/RCTBridge+Private.h>
#import <React/RCTScheduler.h>
#import <React/RCTSurface.h>
#import <React/RCTSurfacePresenter.h>
#import <React/RCTSurfaceView.h>

#import <RNReanimated/NativeProxy.h>
#import <RNReanimated/NewestShadowNodesRegistry.h>
#import <RNReanimated/REAModule.h>
#import <RNReanimated/REANodesManager.h>
#import <RNReanimated/ReaRCTFabricSurface.h>
#import <RNReanimated/ReanimatedUIManagerBinding.h>
#import <React/RCTFabricSurface.h>
#import <React/RCTSurfacePresenterBridgeAdapter.h>
#include <react/renderer/uimanager/UIManagerCommitHook.h>

using namespace facebook::react;
using namespace reanimated;

@interface RCTBridge (JSIRuntime)
- (void *)runtime;
@end

@interface RCTBridge (RCTTurboModule)
- (std::shared_ptr<facebook::react::CallInvoker>)jsCallInvoker;
- (void)_tryAndHandleError:(dispatch_block_t)block;
@end

typedef void (^AnimatedOperation)(REANodesManager *nodesManager);

static __strong ReaRCTFabricSurface *reaSurface;

@implementation REAModule {
  NSMutableArray<AnimatedOperation> *_operations;
  __weak RCTSurfacePresenter *_surfacePresenter;
  std::shared_ptr<NewestShadowNodesRegistry> newestShadowNodesRegistry_;
  std::weak_ptr<NativeReanimatedModule> reanimatedModule_;
  std::weak_ptr<REAModule> reaModule_;
}

RCT_EXPORT_MODULE(ReanimatedModule);

- (void)invalidate
{
  [_surfacePresenter removeObserver:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_nodesManager invalidate];
  [super invalidate];
}

- (dispatch_queue_t)methodQueue
{
  // This module needs to be on the same queue as the UIManager to avoid
  // having to lock `_operations` and `_preOperations` since `uiManagerWillPerformMounting`
  // will be called from that queue.
  return RCTGetUIManagerQueue();
}

- (std::shared_ptr<UIManager>)getUiManager
{
  RCTScheduler *scheduler = [_surfacePresenter scheduler];
  return scheduler.uiManager;
}

- (void)injectUIManagerBinding:(jsi::Runtime &)runtime uiManager:(std::shared_ptr<UIManager>)uiManager
{
  RuntimeExecutor syncRuntimeExecutor = [&](std::function<void(jsi::Runtime & runtime_)> &&callback) {
    callback(runtime);
  };
  ReanimatedUIManagerBinding::createAndInstallIfNeeded(
      runtime, syncRuntimeExecutor, uiManager, newestShadowNodesRegistry_);
}

- (void)injectREAModule:(std::shared_ptr<UIManager>)uiManager
{
  if (auto reanimatedModule = reanimatedModule_.lock()) {
    reanimatedModule->setUIManager(uiManager);
  }
}

#pragma mark-- Initialize

- (void)installUIManagerBinding
{
  RCTCxxBridge *cxxBridge = (RCTCxxBridge *)self.bridge;
  react_native_assert(cxxBridge.runtime != nil);
  jsi::Runtime &runtime = *(jsi::Runtime *)cxxBridge.runtime;

  auto uiManager = [self getUiManager];
  [self injectREAModule:uiManager];
  [self injectUIManagerBinding:runtime uiManager:uiManager];
}

- (void)installUIManagerBindingAfterReload
{
  __weak __typeof__(self) weakSelf = self;
  _surfacePresenter = self.bridge.surfacePresenter;
  [_surfacePresenter addObserver:self];
  [_nodesManager setSurfacePresenter:_surfacePresenter];

  RCTRuntimeExecutorFromBridge(self.bridge)(^(jsi::Runtime &runtime) {
    if (__typeof__(self) strongSelf = weakSelf) {
      auto uiManager = [strongSelf getUiManager];
      react_native_assert(uiManager.get() != nil);
      [self injectREAModule:uiManager];
      [self injectUIManagerBinding:runtime uiManager:uiManager];
    }
  });
}

- (void)setBridge:(RCTBridge *)bridge
{
  [super setBridge:bridge];
  _operations = [NSMutableArray new];
  [[self.moduleRegistry moduleForName:"EventDispatcher"] addDispatchObserver:self];
  [bridge.uiManager.observerCoordinator addObserver:self];
  newestShadowNodesRegistry_ = getNewestShadowNodesRegistry();

  // only within the first loading `self.bridge.surfacePresenter` exists
  // during the reload `self.bridge.surfacePresenter` is null
  _surfacePresenter = self.bridge.surfacePresenter;
  if (reaSurface == nil) {
    reaSurface = [[ReaRCTFabricSurface alloc] init];
    [_surfacePresenter registerSurface:reaSurface];
  }
  reaSurface.reaModule = self;

  if (_surfacePresenter == nil) {
    // _surfacePresenter will be set in installUIManagerBindingAfterReload
    _nodesManager = [[REANodesManager alloc] initWithModule:self bridge:self.bridge surfacePresenter:nil];
    return;
  }

  [self installUIManagerBinding];

  [_surfacePresenter addObserver:self];
  _nodesManager = [[REANodesManager alloc] initWithModule:self bridge:self.bridge surfacePresenter:_surfacePresenter];
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(installTurboModule)
{
  facebook::jsi::Runtime *jsiRuntime = [self.bridge respondsToSelector:@selector(runtime)]
      ? reinterpret_cast<facebook::jsi::Runtime *>(self.bridge.runtime)
      : nullptr;

  if (jsiRuntime) {
    // Reanimated
    auto reanimatedModule = reanimated::createReanimatedModule(self.bridge, self.bridge.jsCallInvoker);
    jsiRuntime->global().setProperty(
        *jsiRuntime,
        "_WORKLET_RUNTIME",
        static_cast<double>(reinterpret_cast<std::uintptr_t>(reanimatedModule->runtime.get())));

    jsiRuntime->global().setProperty(
        *jsiRuntime,
        jsi::PropNameID::forAscii(*jsiRuntime, "__reanimatedModuleProxy"),
        jsi::Object::createFromHostObject(*jsiRuntime, reanimatedModule));
    reanimatedModule_ = reanimatedModule;

    RCTScheduler *scheduler = [_surfacePresenter scheduler];
    if (scheduler != nil) { // first load, on reload scheduler will be null
      reanimatedModule->setUIManager(scheduler.uiManager);
    }
  }
  return nil;
}

#pragma mark-- Transitioning API

RCT_EXPORT_METHOD(triggerRender)
{
  [self addOperationBlock:^(REANodesManager *nodesManager) {
    [nodesManager postRunUpdatesAfterAnimation];
  }];
}

#pragma mark-- Batch handling

- (void)addOperationBlock:(AnimatedOperation)operation
{
  [_operations addObject:operation];
}

#pragma mark - RCTSurfacePresenterObserver

- (void)willMountComponentsWithRootTag:(NSInteger)rootTag
{
  RCTAssertMainQueue();

  RCTExecuteOnUIManagerQueue(^{
    if (_operations.count == 0) {
      return;
    }
    NSArray<AnimatedOperation> *operations = _operations;
    _operations = [NSMutableArray new];
    REANodesManager *nodesManager = _nodesManager;

    RCTExecuteOnMainQueue(^{
      for (AnimatedOperation operation in operations) {
        operation(nodesManager);
      }
      [nodesManager operationsBatchDidComplete];
    });
  });
}

RCT_EXPORT_METHOD(setValue : (nonnull NSNumber *)nodeID newValue : (nonnull NSNumber *)newValue)
{
  [self addOperationBlock:^(REANodesManager *nodesManager) {
    [nodesManager setValueForNodeID:nodeID value:newValue];
  }];
}

- (void)didMountComponentsWithRootTag:(NSInteger)rootTag
{
  RCTAssertMainQueue();
  RCTExecuteOnUIManagerQueue(^{
    /*NSArray<AnimatedOperation> *operations = self->_operations;
    self->_operations = [NSMutableArray new];*/

    RCTExecuteOnMainQueue(^{
        /*for (AnimatedOperation operation in operations) {
          operation(self->_nodesManager);
        }*/
    });
  });
}

#pragma mark - RCTUIManagerObserver

- (void)uiManagerWillPerformMounting:(RCTUIManager *)uiManager
{
  [_nodesManager maybeFlushUpdateBuffer];
  if (_operations.count == 0) {
    return;
  }

  NSArray<AnimatedOperation> *operations = _operations;
  _operations = [NSMutableArray new];

  REANodesManager *nodesManager = _nodesManager;

  [uiManager addUIBlock:^(__unused RCTUIManager *manager, __unused NSDictionary<NSNumber *, UIView *> *viewRegistry) {
    for (AnimatedOperation operation in operations) {
      operation(nodesManager);
    }
    [nodesManager operationsBatchDidComplete];
  }];
}

#pragma mark-- Events

- (NSArray<NSString *> *)supportedEvents
{
  return @[ @"onReanimatedCall", @"onReanimatedPropsChange" ];
}

- (void)eventDispatcherWillDispatchEvent:(id<RCTEvent>)event
{
  // Events can be dispatched from any queue
  [_nodesManager dispatchEvent:event];
}

@end
