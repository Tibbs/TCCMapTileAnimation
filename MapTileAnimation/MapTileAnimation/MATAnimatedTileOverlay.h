//
//  MATAnimatedTileOverlay.h
//  MapTileAnimationDemo
//
//  Created by Bruce Johnson on 6/12/14.
//  Copyright (c) 2014 The Climate Corporation. All rights reserved.
//

#import <MapKit/MapKit.h>

@interface MATAnimatedTileOverlay : NSObject <MKOverlay>

@property (readwrite, strong) NSArray *mapTiles;

- (id) initWithTemplateURL: (NSString *)aTemplateURLstring numberOfAnimationFrames:(NSUInteger)numberOfAnimationFrames frameDuration:(NSTimeInterval)frameDuration;

- (id) initWithTileArray: (NSArray *)anArray;

- (void) updateWithTileArray: (NSArray *)aTileArray;

@end