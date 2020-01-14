//
//  TCCAnimationTileOverlayRenderer.m
//  MapTileAnimationDemo
//
//  Created by Bruce Johnson on 6/12/14.
//  Copyright (c) 2014 The Climate Corporation. All rights reserved.
//

#import "TCCAnimationTileOverlayRenderer.h"
#import "TCCAnimationTileOverlay.h"
#import "TCCAnimationTile.h"
#import "TCCMapKitHelpers.h"

NSInteger const TCCMaxZoomLevel = 20;
int const TCCTileSize = 256; // on iOS 12 and earlier, all tiles are 256. in 13, we've had to divide up given tiles and render our images within, because iOS gives us tiles 512 pts sq. this may change in the future, so we just lay out as many tiles as will fit.

@interface TCCAnimationTileOverlayRenderer ()
- (int)tileCoordinateSizeForZoomLevel:(int)zoomLevel;
@property (readwrite, atomic) NSUInteger renderedTileZoomLevel;
//The set is used to limit number of requests
@property (nonatomic) NSMutableSet *activeDownloads;
@end

@implementation TCCAnimationTileOverlayRenderer

#pragma mark - Lifecycle

- (id)initWithOverlay:(id<MKOverlay>)overlay
{
    if (self = [super initWithOverlay:overlay])
    {
        _activeDownloads = [NSMutableSet set];
        if (![overlay isKindOfClass:[TCCAnimationTileOverlay class]]) {
            [NSException raise:@"Unsupported overlay type" format:@"Must be MATAnimatedTileOverlay"];
        }
    }
    return self;
}

#pragma mark - Public methods

- (int)tileCoordinateSizeForZoomLevel:(int)zoomLevel {
    return (int)(TCCTileSize * pow(2, (TCCMaxZoomLevel - zoomLevel)));
}

- (BOOL)canDrawMapRect:(MKMapRect)mapRect zoomScale:(MKZoomScale)zoomScale
{
    __weak TCCAnimationTileOverlayRenderer * weakSelf = self;
    weakSelf.renderedTileZoomLevel = [TCCMapKitHelpers zoomLevelForZoomScale:zoomScale];

    //The overlay can be nil if often or quickly to dealloc the renderer.
    __weak __typeof__(TCCAnimationTileOverlay *) animationOverlay = weakSelf.overlay;
    
    // Render static tiles if we're stopped. Uses the MKTileOverlay method loadTileAtPath:result:
    // to load and render tile images asynchronously and on demand.
    if (animationOverlay.currentAnimationState == TCCAnimationStateStopped) {
        NSUInteger cappedZoomLevel = MIN([TCCMapKitHelpers zoomLevelForZoomScale:zoomScale], animationOverlay.maximumZ);
        
        int tileSizeForZoomLevel = [self tileCoordinateSizeForZoomLevel:((int)cappedZoomLevel)];
        int heightCount = mapRect.size.height / tileSizeForZoomLevel;
        int widthCount = mapRect.size.width / tileSizeForZoomLevel;
        
        BOOL resultState = NO;
        
        int tileRow = 0;
        //The duplicate requests appear because this func loads tiles for retina display (1 mapRect contains 4-6 tiles).
        while (tileRow < heightCount) {
            int tileCol = 0;
            while (tileCol < widthCount) {
                                
                MKMapRect localMapRect = MKMapRectMake(mapRect.origin.x + (tileCol * tileSizeForZoomLevel), mapRect.origin.y + (tileRow * tileSizeForZoomLevel), tileSizeForZoomLevel, tileSizeForZoomLevel);

                //The tile can be nil in a case of low memory
                __weak __typeof__(TCCAnimationTile *) tile;
                @synchronized (weakSelf) {
                    tile = [animationOverlay staticTileForMapRect:localMapRect zoomLevel:cappedZoomLevel];
                }
                
                // Draw the image if we have it, otherwise load the tile data. Returning NO will make sure that
                // drawRect doesn't get called immediately until setNeedsDisplayInMapRect:zoomScale: gets called
                // when the tile has finished loading
                // If the tile image failed to fetch, then return `YES` to avoid overwhelming `loadTileAtPath:result:` as this
                // delegate method is called continously while any rect returns `NO`.
                if (tile.tileImage || tile.failedToFetch) {
                    resultState = YES;
                }
                
                if (!tile.tileImage) {
                    MKTileOverlayPath tilePath = [TCCMapKitHelpers tilePathForMapRect:localMapRect zoomLevel:cappedZoomLevel];

                    BOOL tileActive = NO;
                    @synchronized(weakSelf) {
                        //Keep a set of requests which in the downloading process by the tile path key.
                        NSString * xyz = [[weakSelf class] keyForTilePath:tilePath];
                        tileActive = ([weakSelf.activeDownloads containsObject:xyz]);
                        if (!tileActive) {
                            [weakSelf.activeDownloads addObject:xyz];
                        }
                    }
                    //Avoid a duplicate request which already in the downloading process
                    if (!tileActive) {
                        [animationOverlay loadTileAtPath:tilePath result:^(NSData *tileData, NSError *error) {
                            @synchronized(weakSelf) {
                                [weakSelf.activeDownloads removeObject:[[weakSelf class] keyForTilePath:tilePath]];
                            }
                            if (tileData) {
                                //The setNeedsDisplayInMapRect is called once for each downloaded sub-tile of the mapRect (4-6 sub-tiles for retina).
                                [weakSelf setNeedsDisplayInMapRect:mapRect zoomScale:zoomScale];
                            }
                        }];
                    }
                }
                                
                tileCol++;
            }
            tileRow++;
        }
        
        return resultState;
    }
    
    return YES;
}

+ (NSString *)keyForTilePath:(MKTileOverlayPath)path
{
    return [NSString stringWithFormat:@"%ld-%ld-%ld", (long)path.x, (long)path.y, (long)path.z];
}

/*
 even though this renderer and associated overlay are *NOT* tiled, drawMapRect gets called multilple times with each mapRect being a tiled region within the visibleMapRect. So MKMapKit drawing is tiled by design even though setNeedsDisplay is only called once.
 */
-(void)drawMapRect:(MKMapRect)mapRect zoomScale:(MKZoomScale)zoomScale inContext:(CGContextRef)context
{
    TCCAnimationTileOverlay *mapOverlay = (TCCAnimationTileOverlay *)self.overlay;
    NSInteger zoomLevel = [TCCMapKitHelpers zoomLevelForZoomScale:zoomScale];
    
    int tileSizeForZoomLevel = [self tileCoordinateSizeForZoomLevel:((int)zoomLevel)];
    int heightCount = mapRect.size.height / tileSizeForZoomLevel;
    int widthCount = mapRect.size.width / tileSizeForZoomLevel;
    
    NSUInteger cappedZoomLevel = MIN(zoomLevel, mapOverlay.maximumZ);
    
    NSMutableArray * dividedTiles = [NSMutableArray array];
    
    int tileRow = 0;
    while (tileRow < heightCount) {
        int tileCol = 0;
        while (tileCol < widthCount) {
            TCCAnimationTile *tile;
            
            MKMapRect localMapRect = MKMapRectMake(mapRect.origin.x + (tileCol * tileSizeForZoomLevel), mapRect.origin.y + (tileRow * tileSizeForZoomLevel), tileSizeForZoomLevel, tileSizeForZoomLevel);
            
            if (self.drawDebugInfo) {
                MKTileOverlayPath path = [TCCMapKitHelpers tilePathForMapRect:mapRect zoomLevel:zoomLevel];
                [TCCMapKitHelpers drawDebugInfoForX:path.x + tileCol Y:path.y + tileRow Z:path.z color:[UIColor blackColor] inRect:[self rectForMapRect:localMapRect] context:context];
            }
            
            // There are two different methods for getting tiles from the overlay, depending on whether the overlay
            // is currently animating or of it's static. This is because the tiles are stored in different data
            // structures depending on whether it's currently animating or if it's static.
            @synchronized (self) {
                if (mapOverlay.currentAnimationState == TCCAnimationStateStopped) {
                    tile = [mapOverlay staticTileForMapRect:localMapRect zoomLevel:cappedZoomLevel];
                } else {
                    tile = [mapOverlay animationTileForMapRect:localMapRect zoomLevel:zoomLevel];
                }
            }
            if (tile) {
                [dividedTiles addObject:tile];
            }
            tileCol++;
        }
        tileRow++;
    }
    
    // If we have a tile that matches the current zoom level of the map, we can render it immediately.
    if ([dividedTiles count] > 0 && zoomLevel == cappedZoomLevel) {
        [dividedTiles enumerateObjectsUsingBlock:^(TCCAnimationTile * obj, NSUInteger idx, BOOL * stop) {
            UIImage *image = obj.tileImage;
            UIGraphicsPushContext(context);
            CGRect renderRect = [self rectForMapRect:obj.mapRectFrame];
            [image drawInRect:renderRect blendMode:kCGBlendModeNormal alpha:self.alpha];
            UIGraphicsPopContext();
        }];
        return;
    }
    
    // If we reach this point, the TCCAnimationTileOverlay doesn't have a tile to draw for this map rect.
    // This can happen when the tile hasn't been fetched yet (user must call fetchTiles first), failed to
    // fetch (tile server failed), or if the map is zoomed to a level where the overlay doesn't have any
    // tile data for that zoom level.
    //
    // We can't do anything about the first two cases, but in the last case, we must support "overzoom"
    // rendering (i.e. scaled drawing) of the highest supported zoom level (i.e. maximumZ).
    NSInteger overZoom = 1;
    if (zoomLevel > mapOverlay.maximumZ) {
        overZoom = pow(2, (zoomLevel - mapOverlay.maximumZ));
    }
    
    // There are two different methods for getting tiles from the overlay, depending on whether the overlay
    // is currently animating or of it's static. This is because the tiles are stored in different data
    // structures depending on whether it's currently animating or if it's static.
    NSArray *tiles;
    @synchronized (self) {
        if (mapOverlay.currentAnimationState == TCCAnimationStateStopped) {
            tiles = [mapOverlay cachedStaticTilesForMapRect:mapRect zoomLevel:cappedZoomLevel];
        } else {
            tiles = [mapOverlay cachedTilesForMapRect:mapRect zoomLevel:cappedZoomLevel];
        }
    }
    
    for (TCCAnimationTile *tile in tiles) {
        // For each image tile, draw it in its corresponding MKMapRect frame
        CGRect rect = [self rectForMapRect:tile.mapRectFrame];
        if (!MKMapRectIntersectsRect(mapRect, tile.mapRectFrame)) continue;
        
        // Make sure there's image data for us to draw
        UIImage *tileImage = tile.tileImage;
        if (!tileImage) continue;
        
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, CGRectGetMinX(rect), CGRectGetMinY(rect));
        // OverZoom mode - 1 when using tiles as is, 2, 4, 8 etc when overzoomed.
        CGContextScaleCTM(context, overZoom/zoomScale, overZoom/zoomScale);
        CGContextTranslateCTM(context, 0, tileImage.size.height);
        CGContextScaleCTM(context, 1, -1);
        CGContextDrawImage(context, CGRectMake(0, 0, tileImage.size.width, tileImage.size.height), [tileImage CGImage]);
        CGContextRestoreGState(context);
        
        if (self.drawDebugInfo) {
            [TCCMapKitHelpers drawDebugInfoForX:tile.x Y:tile.y Z:tile.z color:[UIColor blueColor] inRect:rect context:context];
        }
    }
}

@end
