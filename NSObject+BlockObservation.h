//
//  NSObject+BlockObservation.h
//  BlockObserve
//
//  Created by Andy Matuschak on 7/23/09.
//  Copyright 2009 Andy Matuschak. All rights reserved.
//

#import <Cocoa/Cocoa.h>

typedef NSString AMBlockToken;
typedef void (^AMBlockTask)(id obj, NSDictionary *change);

@interface NSObject (AMBlockObservation)
- (AMBlockToken *)addObserverForKeyPath:(NSString *)keyPath task:(AMBlockTask)task;
- (AMBlockToken *)addObserverForKeyPath:(NSString *)keyPath onQueue:(NSOperationQueue *)queue task:(AMBlockTask)task;
- (void)removeObserverWithBlockToken:(AMBlockToken *)token;
@end
