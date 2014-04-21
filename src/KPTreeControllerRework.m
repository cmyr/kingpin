//
// Copyright 2012 Bryan Bonczek
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//


#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>

#import "KPGeometry.h"

#import "KPTreeControllerRework.h"

#import "KPGridClusteringAlgorithm.h"

#import "KPAnnotation.h"
#import "KPAnnotationTree.h"

#import "NSArray+KP.h"


static KPTreeControllerReworkConfiguration KPTreeControllerReworkDefaultConfiguration = (KPTreeControllerReworkConfiguration) {
    .gridSize = (CGSize){60.f, 60.f},
    .annotationSize = (CGSize){60.f, 60.f},
    .annotationCenterOffset = (CGPoint){30.f, 30.f},
    .animationDuration = 0.5f,
    .clusteringEnabled = YES,
};


typedef enum {
    KPTreeControllerMapViewportNoChange,
    KPTreeControllerMapViewportPan,
    KPTreeControllerMapViewportZoom
} KPTreeControllerMapViewportChangeState;


@interface KPTreeControllerRework()

@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) KPAnnotationTree *annotationTree;
@property (nonatomic, strong) KPGridClusteringAlgorithm *clusteringAlgorithm;

@property (nonatomic) MKMapRect lastRefreshedMapRect;
@property (nonatomic) MKCoordinateRegion lastRefreshedMapRegion;
@property (readonly, nonatomic) KPTreeControllerMapViewportChangeState mapViewportChangeState;
@end

@implementation KPTreeControllerRework

- (id)initWithMapView:(MKMapView *)mapView {
    
    self = [self init];
    
    if (self == nil) {
        return nil;
    }

    self.mapView = mapView;

    self.lastRefreshedMapRect = self.mapView.visibleMapRect;
    self.lastRefreshedMapRegion = self.mapView.region;

    self.configuration = KPTreeControllerReworkDefaultConfiguration;
    self.clusteringAlgorithm = [[KPGridClusteringAlgorithm alloc] init];
    self.clusteringAlgorithm.delegate = self;

    return self;
}

- (void)setAnnotations:(NSArray *)annotations {
    [self.mapView removeAnnotations:[self.annotationTree.annotations allObjects]];

    self.annotationTree = [[KPAnnotationTree alloc] initWithAnnotations:annotations];

    [self _updateVisibileMapAnnotationsOnMapView:NO];
}

- (void)refresh:(BOOL)animated {
    KPTreeControllerMapViewportChangeState mapViewportChangeState = self.mapViewportChangeState;

    if (mapViewportChangeState != KPTreeControllerMapViewportNoChange) {
        [self _updateVisibileMapAnnotationsOnMapView:(animated && mapViewportChangeState != KPTreeControllerMapViewportPan)];

        self.lastRefreshedMapRect = self.mapView.visibleMapRect;
        self.lastRefreshedMapRegion = self.mapView.region;
    }
}

// only refresh if:
// - the map has been zoomed
// - the map has been panned significantly
- (KPTreeControllerMapViewportChangeState)mapViewportChangeState {
    if (MKMapRectEqualToRect(self.mapView.visibleMapRect, self.lastRefreshedMapRect)) {
        return KPTreeControllerMapViewportNoChange;
    }

    if (fabs(self.lastRefreshedMapRect.size.width - self.mapView.visibleMapRect.size.width) > 0.1f) {
        return KPTreeControllerMapViewportZoom;
    }

    CGPoint lastPoint = [self.mapView convertCoordinate:self.lastRefreshedMapRegion.center
                                          toPointToView:self.mapView];

    CGPoint currentPoint = [self.mapView convertCoordinate:self.mapView.region.center
                                             toPointToView:self.mapView];

    if ((fabs(lastPoint.x - currentPoint.x) > self.mapView.frame.size.width) ||
        (fabs(lastPoint.y - currentPoint.y) > self.mapView.frame.size.height)) {
        return KPTreeControllerMapViewportPan;
    }

    return KPTreeControllerMapViewportNoChange;
}

#pragma mark
#pragma mark Private

- (void)_updateVisibileMapAnnotationsOnMapView:(BOOL)animated {
    NSSet *visibleAnnotations = [self.mapView annotationsInMapRect:[self.mapView visibleMapRect]];

    // Calculate the grid size in terms of MKMapPoints.
    double widthPercentage = self.configuration.gridSize.width / CGRectGetWidth(self.mapView.frame);
    double heightPercentage = self.configuration.gridSize.height / CGRectGetHeight(self.mapView.frame);

    MKMapSize cellSize = MKMapSizeMake(
        ceil(widthPercentage * self.mapView.visibleMapRect.size.width),
        ceil(heightPercentage * self.mapView.visibleMapRect.size.height)
    );

    MKMapRect mapRect = self.mapView.visibleMapRect;

    mapRect = MKMapRectInset(self.mapView.visibleMapRect,
                             -self.mapView.visibleMapRect.size.width,
                             -self.mapView.visibleMapRect.size.height);

    mapRect.size.width  = MIN(mapRect.size.width, MKMapRectWorld.size.width);
    mapRect.size.height = MIN(mapRect.size.height, MKMapRectWorld.size.height);

    // Normalize grid to a cell size.
    mapRect = MKMapRectNormalizeToCellSize(mapRect, cellSize);


    NSArray *newClusters = [self.clusteringAlgorithm performClusteringOfAnnotationsInMapRect:mapRect cellSize:cellSize annotationTree:self.annotationTree];


    if ([self.delegate respondsToSelector:@selector(treeController:configureAnnotationForDisplay:)]) {
        for (KPAnnotation *annotation in newClusters) {
            [self.delegate treeController:self configureAnnotationForDisplay:annotation];
        }
    }

    NSArray *oldClusters = [self.mapView.annotations kp_filter:^BOOL(id annotation) {
        if ([annotation isKindOfClass:[KPAnnotation class]]) {
            return ([self.annotationTree.annotations containsObject:[[(KPAnnotation*)annotation annotations] anyObject]]);
        }
        else {
            return NO;
        }
    }];

    if (animated) {

        for(KPAnnotation *newCluster in newClusters){

            [self.mapView addAnnotation:newCluster];

            // if was part of an old cluster, then we want to animate it from the old to the new (spreading animation)

            for(KPAnnotation *oldCluster in oldClusters){

                BOOL shouldAnimate = ![oldCluster.annotations isEqualToSet:newCluster.annotations];

                if([oldCluster.annotations member:[newCluster.annotations anyObject]]){

                    if([visibleAnnotations member:oldCluster] && shouldAnimate){
                        [self _animateCluster:newCluster
                                          fromAnnotation:oldCluster
                                            toAnnotation:newCluster
                                              completion:nil];
                    }

                    [self.mapView removeAnnotation:oldCluster];
                }

                // if the new cluster had old annotations, then animate the old annotations to the new one, and remove it
                // (collapsing animation)

                else if([newCluster.annotations member:[oldCluster.annotations anyObject]]){

                    if(MKMapRectContainsPoint(self.mapView.visibleMapRect, MKMapPointForCoordinate(newCluster.coordinate)) && shouldAnimate){

                        [self _animateCluster:oldCluster
                                          fromAnnotation:oldCluster
                                            toAnnotation:newCluster
                                              completion:^(BOOL finished) {
                                                  [self.mapView removeAnnotation:oldCluster];
                                              }];
                    }
                    else {
                        [self.mapView removeAnnotation:oldCluster];
                    }
                    
                }
            }
        }
        
    }
    else {
        [self.mapView removeAnnotations:oldClusters];
        [self.mapView addAnnotations:newClusters];
    }

    
}

- (void)_animateCluster:(KPAnnotation *)cluster
         fromAnnotation:(KPAnnotation *)fromAnnotation
           toAnnotation:(KPAnnotation *)toAnnotation
             completion:(void (^)(BOOL finished))completion
{
    
    CLLocationCoordinate2D fromCoord = fromAnnotation.coordinate;
    CLLocationCoordinate2D toCoord = toAnnotation.coordinate;
    
    cluster.coordinate = fromCoord;
    
    if ([self.delegate respondsToSelector:@selector(treeController:willAnimateAnnotation:fromAnnotation:toAnnotation:)]) {
        [self.delegate treeController:self willAnimateAnnotation:cluster fromAnnotation:fromAnnotation toAnnotation:toAnnotation];
    }
    
    void (^completionDelegate)() = ^ {
        if ([self.delegate respondsToSelector:@selector(treeController:didAnimateAnnotation:fromAnnotation:toAnnotation:)]) {
            [self.delegate treeController:self didAnimateAnnotation:cluster fromAnnotation:fromAnnotation toAnnotation:toAnnotation];
        }
    };
    
    void (^completionBlock)(BOOL finished) = ^(BOOL finished) {

        completionDelegate();
        
        if (completion) {
            completion(finished);
        }
    };
    
    [UIView animateWithDuration:self.configuration.animationDuration
                          delay:0.f
                        options:self.configuration.animationOptions
                     animations:^{
                         cluster.coordinate = toCoord;
                     }
                     completion:completionBlock];
    
}


#pragma mark 
#pragma mark <KPGridClusteringAlgorithmDelegate>

- (BOOL)clusterIntersects:(KPAnnotation *)clusterAnnotation anotherCluster:(KPAnnotation *)anotherClusterAnnotation {
    // calculate CGRects for each annotation, memoizing the coord -> point conversion as we go
    // if the two views overlap, merge them

    if (clusterAnnotation._annotationPointInMapView == nil) {
        clusterAnnotation._annotationPointInMapView = [NSValue valueWithCGPoint:[self.mapView convertCoordinate:clusterAnnotation.coordinate toPointToView:self.mapView]];
    }

    if (anotherClusterAnnotation._annotationPointInMapView == nil) {
        anotherClusterAnnotation._annotationPointInMapView = [NSValue valueWithCGPoint:[self.mapView convertCoordinate:anotherClusterAnnotation.coordinate toPointToView:self.mapView]];
    }

    CGPoint p1 = [clusterAnnotation._annotationPointInMapView CGPointValue];
    CGPoint p2 = [anotherClusterAnnotation._annotationPointInMapView CGPointValue];

    CGRect r1 = CGRectMake(
        p1.x - self.configuration.annotationSize.width + self.configuration.annotationCenterOffset.x,
        p1.y - self.configuration.annotationSize.height + self.configuration.annotationCenterOffset.y,
        self.configuration.annotationSize.width,
        self.configuration.annotationSize.height
    );

    CGRect r2 = CGRectMake(
        p2.x - self.configuration.annotationSize.width + self.configuration.annotationCenterOffset.x,
        p2.y - self.configuration.annotationSize.height + self.configuration.annotationCenterOffset.y,
        self.configuration.annotationSize.width,
        self.configuration.annotationSize.height
    );

    return CGRectIntersectsRect(r1, r2);
}


@end