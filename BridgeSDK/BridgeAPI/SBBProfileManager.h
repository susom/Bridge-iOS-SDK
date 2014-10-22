//
//  SBBProfileManager.h
//  BridgeSDK
//
//  Created by Erin Mounts on 9/23/14.
//  Copyright (c) 2014 Sage Bionetworks. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SBBBridgeAPIManager.h"

/*!
 Completion block called when retrieving user profile from the API.
 
 @param userProfile By default, an SBBUserProfile object, unless the UserProfile type has been mapped in SBBObjectManager setupMappingForType:toClass:fieldToPropertyMappings:
 @param error       An error that occurred during execution of the method for which this is a completion block, or nil.
 */
typedef void (^SBBProfileManagerGetCompletionBlock)(id userProfile, NSError *error);

/*!
 Completion block called when updating user profile to the API.
 
 @param responseObject JSON response from the server.
 @param error          An error that occurred during execution of the method for which this is a completion block, or nil.
 */
typedef void (^SBBProfileManagerUpdateCompletionBlock)(id responseObject, NSError *error);

/*!
 *  This protocol defines the interface to the SBBProfileManager's non-constructor, non-initializer methods. The interface is
 *  abstracted out for use in mock objects for testing, and to allow selecting among multiple implementations at runtime.
 */
@protocol SBBProfileManagerProtocol <SBBBridgeAPIManagerProtocol>

/*!
 *  Fetch the UserProfile from the Bridge API.
 *
 *  @param completion An SBBProfileManagerGetCompletionBlock to be called upon completion.
 *
 *  @return An NSURLSessionDataTask object so you can cancel or suspend/resume the request.
 */
- (NSURLSessionDataTask *)getUserProfileWithCompletion:(SBBProfileManagerGetCompletionBlock)completion;

/*!
 *  Update the UserProfile to the Bridge API.
 *
 *  @param profile A client object representing the UserProfile as it should be updated.
 *  @param completion An SBBProfileManagerGetCompletionBlock to be called upon completion.
 *
 *  @return An NSURLSessionDataTask object so you can cancel or suspend/resume the request.
 */
- (NSURLSessionDataTask *)updateUserProfileWithProfile:(id)profile completion:(SBBProfileManagerUpdateCompletionBlock)completion;

@end

/*!
 *  This class handles communication with the Bridge profile API.
 */
@interface SBBProfileManager : SBBBridgeAPIManager<SBBComponent, SBBProfileManagerProtocol>

@end