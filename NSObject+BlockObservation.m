//
//  NSObject+BlockObservation.m
//  BlockObserve
//
//  Created by Andy Matuschak on 7/23/09.
//  Copyright 2009 Andy Matuschak. All rights reserved.
//

#import "NSObject+BlockObservation.h"
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

@interface AMObserverTrampoline : NSObject
{
	__weak id observee;
	NSString *keyPath;
	AMBlockTask task;
	NSOperationQueue *queue;
}

- (AMObserverTrampoline *)initObservingObject:(id)obj keyPath:(NSString *)keyPath onQueue:(NSOperationQueue *)queue task:(AMBlockTask)task;
- (void)cancelObservation;
@end

@implementation AMObserverTrampoline

static NSString *AMObserverTrampolineContext = @"AMObserverTrampolineContext";

- (AMObserverTrampoline *)initObservingObject:(id)obj keyPath:(NSString *)newKeyPath onQueue:(NSOperationQueue *)newQueue task:(AMBlockTask)newTask
{
	if (!(self = [super init])) return nil;
	task = [newTask copy];
	keyPath = [newKeyPath copy];
	queue = [newQueue retain];
	observee = obj;
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
	else
	{
		[super observeValueForKeyPath:aKeyPath ofObject:object change:change context:context];
	}
}

- (void)cancelObservation
{
	[observee removeObserver:self forKeyPath:keyPath];
}

- (void)dealloc
{
	[task release];
	[keyPath release];
	[queue release];
	[super dealloc];
}

@end

static NSString *AMObserverMapKey = @"AMObserverMapKey";

@implementation NSObject (AMBlockObservation)

- (AMBlockToken *)addObserverForKeyPath:(NSString *)keyPath task:(AMBlockTask)task
{
	return [self addObserverForKeyPath:keyPath onQueue:nil task:task];
}

- (AMBlockToken *)addObserverForKeyPath:(NSString *)keyPath onQueue:(NSOperationQueue *)queue task:(AMBlockTask)task
{
	AMBlockToken *token = [[NSProcessInfo processInfo] globallyUniqueString];
	dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		if (!objc_getAssociatedObject(self, AMObserverMapKey))
			objc_setAssociatedObject(self, AMObserverMapKey, [NSMutableDictionary dictionary], OBJC_ASSOCIATION_RETAIN);
		AMObserverTrampoline *trampoline = [[[AMObserverTrampoline alloc] initObservingObject:self keyPath:keyPath onQueue:queue task:task] autorelease];
		[objc_getAssociatedObject(self, AMObserverMapKey) setObject:trampoline forKey:token];
	});
	return token;
}

- (void)removeObserverWithBlockToken:(AMBlockToken *)token
{
	NSMutableDictionary *observationDictionary = objc_getAssociatedObject(self, AMObserverMapKey);
	AMObserverTrampoline *trampoline = [observationDictionary objectForKey:token];
	if (!trampoline)
	{
		NSLog(@"Tried to remove non-existent observer on %@ for token %@", self, token);
		return;
	}
	[trampoline cancelObservation];
	[observationDictionary removeObjectForKey:token];
}

@end