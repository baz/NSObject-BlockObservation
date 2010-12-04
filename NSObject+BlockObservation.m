//
//  NSObject+BlockObservation.h
//  Version 1.0
//
//  Andy Matuschak
//  andy@andymatuschak.org
//  Public domain because I love you. Let me know how you use it.
//

#import "NSObject+BlockObservation.h"
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

@interface AMObserverTrampoline : NSObject
{
    @private
        __weak id observee;
        NSString *keyPath;
        AMBlockTask task;
        NSOperationQueue *queue;
        dispatch_once_t cancellationPredicate;
}

@property (nonatomic, copy) NSString *keyPath;

- (AMObserverTrampoline *)initObservingObject:(id)obj keyPath:(NSString *)keyPath onQueue:(NSOperationQueue *)queue task:(AMBlockTask)task;
- (void)cancelObservation;
@end

@implementation AMObserverTrampoline

static NSString *AMObserverTrampolineContext = @"AMObserverTrampolineContext";

@synthesize keyPath;

- (AMObserverTrampoline *)initObservingObject:(id)obj keyPath:(NSString *)newKeyPath onQueue:(NSOperationQueue *)newQueue task:(AMBlockTask)newTask
{
    if (!(self = [super init])) return nil;
    task = [newTask copy];
    self.keyPath = newKeyPath;
    queue = [newQueue retain];
    observee = obj;
    cancellationPredicate = 0;
    [observee addObserver:self forKeyPath:keyPath options:0 context:AMObserverTrampolineContext];   
    return self;
}

- (void)observeValueForKeyPath:(NSString *)aKeyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == AMObserverTrampolineContext)
    {
        if (queue)
            [queue addOperationWithBlock:^{ task(object, change); }];
        else
            task(object, change);
    }
}

- (void)cancelObservation
{
    dispatch_once(&cancellationPredicate, ^{
        [observee removeObserver:self forKeyPath:keyPath];
        observee = nil;
    });
}

- (void)dealloc
{
    [self cancelObservation];
    [task release];
    [keyPath release];
    [queue release];
    [super dealloc];
}

@end

static NSString *AMObserverTokenKey = @"org.andymatuschak.observerToken";
static NSString *AMObserverKeyPathKey = @"org.andymatuschak.observerKeyPath";
static dispatch_queue_t AMObserverMutationQueue = NULL;

static dispatch_queue_t AMObserverMutationQueueCreatingIfNecessary()
{
    static dispatch_once_t queueCreationPredicate = 0;
    dispatch_once(&queueCreationPredicate, ^{
        AMObserverMutationQueue = dispatch_queue_create("org.andymatuschak.observerMutationQueue", 0);
    });
    return AMObserverMutationQueue;
}

static void cancelTrampoline(id observer, AMObserverTrampoline *trampoline)
{
    if (!trampoline)
    {
        NSLog(@"[NSObject(AMBlockObservation) cancelTrampoline]: Ignoring attempt to remove non-existent trampoline on %@.", observer);
        return;
    }

    // Handle token mapping
    NSMutableDictionary *tokenDict = objc_getAssociatedObject(observer, AMObserverTokenKey);
    [trampoline cancelObservation];
    AMBlockToken *token = [[tokenDict allKeysForObject:trampoline] lastObject];
    [tokenDict removeObjectForKey:token];

    // Handle keyPath mapping
    NSMutableDictionary *keyPathDict = objc_getAssociatedObject(observer, AMObserverKeyPathKey);
    NSString *keyPath = trampoline.keyPath;
    NSMutableArray *trampolines = [keyPathDict objectForKey:keyPath];
    [trampolines removeObject:trampoline];
    if ([trampolines count] == 0)
        [keyPathDict removeObjectForKey:keyPath];
}

static void cleanUpObserverDicts(id observer)
{
    // Due to a bug in the obj-c runtime, these dictionaries do not get cleaned up on release when running without GC.
    NSMutableDictionary *keyPathDict = objc_getAssociatedObject(observer, AMObserverKeyPathKey);
    if ([keyPathDict count] == 0)
        objc_setAssociatedObject(observer, AMObserverKeyPathKey, nil, OBJC_ASSOCIATION_RETAIN);

    NSMutableDictionary *tokenDict = objc_getAssociatedObject(observer, AMObserverTokenKey);
    if ([tokenDict count] == 0)
        objc_setAssociatedObject(observer, AMObserverTokenKey, nil, OBJC_ASSOCIATION_RETAIN);
}

@implementation NSObject (AMBlockObservation)

- (AMBlockToken *)addObserverForKeyPath:(NSString *)keyPath task:(AMBlockTask)task
{
    return [self addObserverForKeyPath:keyPath onQueue:nil task:task];
}

- (AMBlockToken *)addObserverForKeyPath:(NSString *)keyPath onQueue:(NSOperationQueue *)queue task:(AMBlockTask)task
{
    AMBlockToken *token = [[NSProcessInfo processInfo] globallyUniqueString];
    dispatch_sync(AMObserverMutationQueueCreatingIfNecessary(), ^{
        // Handle token mapping
        NSMutableDictionary *tokenDict = objc_getAssociatedObject(self, AMObserverTokenKey);
        if (!tokenDict)
        {
            tokenDict = [[NSMutableDictionary alloc] init];
            objc_setAssociatedObject(self, AMObserverTokenKey, tokenDict, OBJC_ASSOCIATION_RETAIN);
            [tokenDict release];
        }
        AMObserverTrampoline *trampoline = [[AMObserverTrampoline alloc] initObservingObject:self keyPath:keyPath onQueue:queue task:task];
        [tokenDict setObject:trampoline forKey:token];

        // Handle keyPath mapping
        NSMutableDictionary *keyPathDict = objc_getAssociatedObject(self, AMObserverKeyPathKey);
        if (!keyPathDict)
        {
            keyPathDict = [[NSMutableDictionary alloc] init];
            objc_setAssociatedObject(self, AMObserverKeyPathKey, keyPathDict, OBJC_ASSOCIATION_RETAIN);
            [keyPathDict release];
        }
        NSMutableArray *trampolines = [keyPathDict objectForKey:keyPath];
        if (!trampolines)
        {
            trampolines = [[NSMutableArray alloc] initWithCapacity:0];
            [keyPathDict setObject:trampolines forKey:keyPath];
            [trampolines release];
        }
        [trampolines addObject:trampoline];

        [trampoline release];
    });
    return token;
}

- (void)removeObserverWithBlockToken:(AMBlockToken *)token
{
    dispatch_sync(AMObserverMutationQueueCreatingIfNecessary(), ^{
        // Handle token mapping
        NSMutableDictionary *tokenDict = objc_getAssociatedObject(self, AMObserverTokenKey);
        AMObserverTrampoline *trampoline = [tokenDict objectForKey:token];
        if (!trampoline)
        {
            NSLog(@"[NSObject(AMBlockObservation) removeObserverWithBlockToken]: Ignoring attempt to remove non-existent observer on %@ for token %@.", self, token);
            return;
        }
        cancelTrampoline(self, trampoline);
        cleanUpObserverDicts(self);
    });
}

- (void)removeAllObserversForKeyPath:(NSString *)keyPath
{
    dispatch_sync(AMObserverMutationQueueCreatingIfNecessary(), ^{
        // Handle keyPath mapping
        NSMutableDictionary *keyPathDict = objc_getAssociatedObject(self, AMObserverKeyPathKey);
        NSMutableArray *trampolines = [keyPathDict objectForKey:keyPath];
        if (!trampolines)
        {
            NSLog(@"[NSObject(AMBlockObservation) removeAllObserversForKeyPath]: Ignoring attempt to remove non-existent observer(s) on %@ for keyPath %@.", self, keyPath);
            return;
        }
        NSArray *trampolinesShallowCopy = [trampolines copyWithZone:nil];
        for (AMObserverTrampoline *trampoline in trampolinesShallowCopy) {
            cancelTrampoline(self, trampoline);
        }
        [trampolinesShallowCopy release];
        cleanUpObserverDicts(self);
    });
}

@end
