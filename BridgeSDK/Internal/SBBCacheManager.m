//
//  SBBCacheManager.m
//  BridgeSDK
//
//	Copyright (c) 2014-2018, Sage Bionetworks
//	All rights reserved.
//
//	Redistribution and use in source and binary forms, with or without
//	modification, are permitted provided that the following conditions are met:
//	    * Redistributions of source code must retain the above copyright
//	      notice, this list of conditions and the following disclaimer.
//	    * Redistributions in binary form must reproduce the above copyright
//	      notice, this list of conditions and the following disclaimer in the
//	      documentation and/or other materials provided with the distribution.
//	    * Neither the name of Sage Bionetworks nor the names of BridgeSDk's
//		  contributors may be used to endorse or promote products derived from
//		  this software without specific prior written permission.
//
//	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
//	ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//	WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//	DISCLAIMED. IN NO EVENT SHALL SAGE BIONETWORKS BE LIABLE FOR ANY
//	DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//	(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//	LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
//	ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//	(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//	SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#import "SBBCacheManager.h"
#import "SBBBridgeObject.h"
#import "SBBBridgeObjectInternal.h"
#import "SBBComponentManager.h"
#import "SBBAuthManagerInternal.h"
#import "SBBObjectManagerInternal.h"
#import "ModelObjectInternal.h"
#import "NSData+SBBAdditions.h"
#import "NSError+SBBAdditions.h"
@import UIKit;

BOOL gSBBUseCache = NO;

static NSString *gPersistentStoreSubdirectory = @"_BridgeSDKCache_";

static NSMutableDictionary *gCoreDataQueuesByPersistentStoreName;
static NSMutableDictionary *gCoreDataCacheIOContextsByPersistentStoreName;

@interface SBBCacheManager ()<NSCacheDelegate>

@property (nonatomic, weak) id<SBBAuthManagerProtocol> authManager;

@property (nonatomic, strong) NSMutableDictionary *objectsCachedByTypeAndID;
@property (nonatomic, strong) dispatch_queue_t bridgeObjectCacheQueue;

@property (nonatomic, strong) NSString *managedObjectModelName;
@property (nonatomic, strong) NSString *bundleId;
@property (nonatomic, strong) NSManagedObjectModel *managedObjectModel;
@property (nonatomic, strong) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property (nonatomic, strong) NSString *persistentStoreType;
@property (nonatomic, strong) NSPersistentStore *persistentStore;
@property (nonatomic, strong) NSManagedObjectContext *cacheIOContext;

@property (nonatomic, weak) id appWillTerminateObserver;
@property (nonatomic, weak) id memoryWarningObserver;

@end


@implementation SBBCacheManager

+ (void)initialize
{
    gCoreDataQueuesByPersistentStoreName = [[NSMutableDictionary alloc] init];
    gCoreDataCacheIOContextsByPersistentStoreName = [[NSMutableDictionary alloc] init];
}

+ (instancetype)defaultComponent
{
    if (!gSBBUseCache) {
        return nil;
    }
    
    static SBBCacheManager *shared;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [self cacheManagerWithDataModelName:@"SBBDataModel" bundleId:SBBBUNDLEIDSTRING storeType:NSSQLiteStoreType authManager:SBBComponent(SBBAuthManager)];
    });
    
    return shared;
}

+ (instancetype)cacheManagerWithDataModelName:(NSString *)modelName bundleId:(NSString *)bundleId storeType:(NSString *)storeType authManager:(id<SBBAuthManagerProtocol>)authManager
{
    SBBCacheManager *cm = [[self alloc] init];
    cm.managedObjectModelName = modelName;
    cm.bundleId = bundleId;
    NSString *storeName = [NSString stringWithFormat:@"%@.sqlite", modelName];
    cm.persistentStoreName = storeName;
    cm.persistentStoreType = storeType;
    cm.authManager = authManager;
    return cm;
}

+ (instancetype)inMemoryCacheManagerWithAuthManager:(id<SBBAuthManagerProtocol>)authManager
{
    return [self cacheManagerWithDataModelName:@"SBBDataModel" bundleId:SBBBUNDLEIDSTRING storeType:NSInMemoryStoreType authManager:authManager];
}

- (instancetype)init
{
    if (self = [super init]) {
        // No one could be using this instance of SBBCacheManager yet so we don't need to serialize access to its members
        self.objectsCachedByTypeAndID = [NSMutableDictionary dictionary];
        self.appWillTerminateObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            if (_cacheIOContext) {
                [self saveCacheIOContext];
            }
        }];
        self.memoryWarningObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            if (_cacheIOContext) {
                [self.cacheIOContext performBlockAndWait:^{
                    // clear out anything in the in-mem cache that's not currently being held somewhere else
                    // -- first copy everything to a strong-to-weak map table
                    NSMapTable *cacheCopy = [NSMapTable strongToWeakObjectsMapTable];
                    for (NSString *key in self.objectsCachedByTypeAndID.allKeys) {
                        [cacheCopy setObject:self.objectsCachedByTypeAndID[key] forKey:key];
                    }
                    
                    // -- now delete the original cache
                    self.objectsCachedByTypeAndID = nil;
                    
                    // -- and create a new one from the map table, which will now only contain those objects which are being held elsewhere
                    self.objectsCachedByTypeAndID = [[cacheCopy dictionaryRepresentation] mutableCopy];
                }];
            }
        }];
    }
    
    return self;
}

- (void)dealloc
{
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self.appWillTerminateObserver];
    [self discardCacheManagerCoreDataQueue];
}

#pragma mark - External interfaces

- (SBBBridgeObject *)cachedObjectOfType:(NSString *)type withId:(NSString *)objectId createIfMissing:(BOOL)create
{
    return [self cachedObjectOfType:type withId:objectId createIfMissing:create created:nil];
}

- (SBBBridgeObject *)cachedObjectOfType:(NSString *)type withId:(NSString *)objectId createIfMissing:(BOOL)create created:(NSManagedObject **)created
{
    if (created) {
        *created = nil;
    }
    
    if (!type.length || !objectId.length) {
        return nil;
    }
    
    NSManagedObjectContext *context = self.cacheIOContext;
    NSEntityDescription *entity = [NSEntityDescription entityForName:type inManagedObjectContext:context];
    if (!entity) {
        return nil;
    }
    
    NSString *keyPath = entity.userInfo[@"entityIDKeyPath"];
    if (!keyPath.length) {
        // not cacheable
        return nil;
    }
    
    __block SBBBridgeObject *fetched = nil;
    __block NSManagedObject *objectCreated = nil;

    [context performBlockAndWait:^{
        fetched = [self inMemoryBridgeObjectOfType:type andId:objectId];
        
        // if not there, look for it in CoreData
        if (!fetched) {
            NSManagedObject *fetchedMO = [self managedObjectOfEntity:entity withId:objectId atKeyPath:keyPath];
            
            SBBObjectManager *om = [SBBObjectManager objectManagerWithCacheManager:self];
            Class fetchedClass = [SBBObjectManager bridgeClassFromType:type];
            
            if (fetchedMO) {
                if ([fetchedClass instancesRespondToSelector:@selector(initWithManagedObject:objectManager:cacheManager:)]) {
                    fetched = [[fetchedClass alloc] initWithManagedObject:fetchedMO objectManager:om cacheManager:self];
                    if (!fetched) {
                        NSLog(@"Failed to create %@ instance from %@ managed object--probably trying to access encrypted data without login credentials", NSStringFromClass(fetchedClass), entity.name);
                    }
                    NSAssert(!create || fetched, @"Attempting to create duplicate %@ with %@ == %@ in cache", entity.name, keyPath, objectId);
                }
            } else if (create) {
                fetched = [[fetchedClass alloc] initWithDictionaryRepresentation:@{@"type": type, keyPath: objectId} objectManager:om];
                objectCreated = [fetched createInContext:context withObjectManager:om cacheManager:self];
                // caller's responsibility to save the cache context once all required fields have been set
            }
            
            NSString *key = [self inMemoryKeyForType:type andId:objectId];
            
            if (fetched) {
                [self.objectsCachedByTypeAndID setObject:fetched forKey:key];
            } else {
                [self.objectsCachedByTypeAndID removeObjectForKey:key];
            }
        }
    }];
    
    if (created) {
        *created = objectCreated;
    }
   
    return fetched;
}

- (SBBBridgeObject *)cachedSingletonObjectOfType:(NSString *)type createIfMissing:(BOOL)create
{
    // cacheable singletons have entityIDKeyPath set to "type"
    return [self cachedObjectOfType:type withId:type createIfMissing:create];
}

- (SBBBridgeObject *)cachedObjectFromBridgeJSON:(id)json
{
    return [self cachedObjectFromBridgeJSON:json createIfMissing:YES];
}

- (SBBBridgeObject *)cachedObjectFromBridgeJSON:(id)json createIfMissing:(BOOL)create
{
    NSString *type = [json objectForKey:@"type"];
    if (!type.length) {
        return nil;
    }
    
    NSEntityDescription *entity = [NSEntityDescription entityForName:type inManagedObjectContext:self.cacheIOContext];
    if (!entity) {
#if DEBUG
        NSLog(@"Unknown type '%@' attempting to fetch cached object from Bridge JSON:\n%@", type, json);
#endif
        return nil;
    }
    
    NSString *keyPath = entity.userInfo[@"entityIDKeyPath"];
    if (!keyPath.length) {
        // not directly cacheable
        return nil;
    }
    
    NSString *key = @"";
    NSString *syntheticKeyComponentPaths = entity.userInfo[@"syntheticKeyComponentPaths"];
    if (syntheticKeyComponentPaths) {
        NSArray *paths = [syntheticKeyComponentPaths componentsSeparatedByString:@","];
        for (NSString *path in paths) {
            NSString *value = [json valueForKeyPath:path];
            key = [key stringByAppendingString:value ? : @""];
        }
    } else {
        key = [json valueForKeyPath:keyPath];
    }
    
    if (!key.length) {
#if DEBUG
        NSLog(@"Attempt to fetch cached object of type '%@' from Bridge JSON failed; JSON contains no value at the specified key path %@:\n%@", type, keyPath, json);
#endif
        return nil;
    }
    
    while ([key isKindOfClass:[NSArray class]]) {
        key = ((NSArray *)key).firstObject;
    }
    
    NSString *keyRegex = entity.userInfo[@"entityIDRegex"];
    if (keyRegex) {
        NSPredicate *keyPred = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", keyRegex];
        NSArray *keyArray = @[key];
        NSArray *matchingKeyArray = [keyArray filteredArrayUsingPredicate:keyPred];
        key = [matchingKeyArray firstObject];
        if (!key.length) {
            // again, not directly cacheable
            return nil;
        }
    }
    
    // Get it from the cache by type & id
    NSManagedObject *created;
    SBBBridgeObject *object = [self cachedObjectOfType:type withId:key createIfMissing:create created:&created];
    
    if (object) {
        SBBObjectManager *om = [SBBObjectManager objectManagerWithCacheManager:self];
        // if this is a newly-created object, i.e. didn't already exist in the cache, just fill
        // it in from the given Bridge JSON. Otherwise, let the object decide how the two should
        // be reconciled. The default implementation is that if the object is marked as extendable
        // or as having client-writable fields, then we don't update the existing cached object
        // from the server; otherwise we just overwrite whatever we had cached with the server version.
        if (created) {
            [object updateWithDictionaryRepresentation:json objectManager:om];
        } else {
            [object reconcileWithDictionaryRepresentation:json objectManager:om];
        }
        // Update CoreData cached object too
        [self.cacheIOContext performBlockAndWait:^{
            NSManagedObject *fetchedMO = [self managedObjectOfEntity:entity withId:key atKeyPath:keyPath];
            if (fetchedMO) {
                [object updateManagedObject:fetchedMO withObjectManager:om cacheManager:self];
            } else {
                [object createInContext:self.cacheIOContext withObjectManager:om cacheManager:self];
            }
            
            [self saveCacheIOContext];
        }];
    }
    
    return object;
}

- (NSManagedObject *)cachedObjectForBridgeObject:(ModelObject *)bridgeObject inContext:(NSManagedObjectContext *)context
{
    __block NSManagedObject *fetchedMO = nil;
    NSEntityDescription *entity = [bridgeObject entityForContext:self.cacheIOContext];
    NSString *entityIDKeyPath = entity.userInfo[@"entityIDKeyPath"];
    NSString *key = [bridgeObject valueForKeyPath:entityIDKeyPath];
    [context performBlockAndWait:^{
        fetchedMO = [self managedObjectOfEntity:entity withId:key atKeyPath:entityIDKeyPath];
    }];
    
    return fetchedMO;
}

- (void)removeFromCacheObjectOfType:(NSString *)type withId:(NSString *)objectId
{
    NSManagedObjectContext *context = self.cacheIOContext;
    NSEntityDescription *entity = [NSEntityDescription entityForName:type inManagedObjectContext:context];
    if (!entity) {
        return;
    }
    
    NSString *keyPath = entity.userInfo[@"entityIDKeyPath"];
    if (!keyPath.length) {
        // not cacheable
        return;
    }
    
    [context performBlock:^{
        NSManagedObject *fetchedMO = [self managedObjectOfEntity:entity withId:objectId atKeyPath:keyPath];
        if (fetchedMO) {
            [context deleteObject:fetchedMO];
            [context processPendingChanges];
            
            // if it has *any* relationships with cascade-delete rules, we'll run through the entire mem cache and clean out
            // anything with no corresponding managed object, just to be sure it's correct and up-to-date
            NSDictionary <NSString *, NSRelationshipDescription *> *relationshipsByName = fetchedMO.entity.relationshipsByName;
            for (NSString *relationshipName in relationshipsByName.allKeys) {
                NSRelationshipDescription *relationship = relationshipsByName[relationshipName];
                if (relationship.deleteRule == NSCascadeDeleteRule) {
                    [self cleanupDeletedManagedObjectsFromMemoryCache];
                    break;
                }
            }
        }
        
        [self removeFromMemoryBridgeObjectOfType:type andId:objectId];
    }];
}

- (NSString *)encryptionKey
{
    NSString *encryptionKey = nil;
    
    // encrypt/decrypt with reauth token
    if ([self.authManager respondsToSelector:@selector(savedReauthToken)]) {
        encryptionKey = [(id)self.authManager savedReauthToken];
    }
    
    // if no reauthToken, fall back to password -- will only happen on old app installations before first re-authentication
    // after updating to this BridgeSDK version
    if (!encryptionKey && [self.authManager respondsToSelector:@selector(savedPassword)]) {
        encryptionKey = [(id)self.authManager savedPassword];
    }
    
    return encryptionKey;
}

- (NSArray <SBBBridgeObject *> *)fetchCachedObjectsOfType:(NSString *)type predicate:(NSPredicate *)predicate sortDescriptors:(nullable NSArray <NSSortDescriptor *> *)sortDescriptors fetchLimit:(NSUInteger)fetchLimit error:(NSError **)error {
    
    __block NSArray <SBBBridgeObject *> *bridgeObjects = nil;
    __block NSError *requestError = nil;
    NSManagedObjectContext *context = self.cacheIOContext;
    [context performBlockAndWait:^{
        
        NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:type];
        request.predicate = predicate;
        request.sortDescriptors = sortDescriptors;
        if (fetchLimit > 0) {
            request.fetchLimit = fetchLimit;
        }

        NSArray *objects = [context executeFetchRequest:request error:&requestError];
        if (objects) {
            SBBObjectManager *om = [SBBObjectManager objectManagerWithCacheManager:self];
            Class fetchedClass = [SBBObjectManager bridgeClassFromType:type];
            
            if ([fetchedClass instancesRespondToSelector:@selector(initWithManagedObject:objectManager:cacheManager:)]) {
                __block NSMutableArray *results = [NSMutableArray new];
                [objects enumerateObjectsUsingBlock:^(id  _Nonnull fetchedMO, NSUInteger idx, BOOL * _Nonnull stop) {
                    id fetched = [[fetchedClass alloc] initWithManagedObject:fetchedMO objectManager:om cacheManager:self];
                    if (fetched) {
                        [results addObject:fetched];
                    }
                    else {
                        NSLog(@"Failed to create %@ instance from %@ managed object--probably trying to access encrypted data without login credentials", NSStringFromClass(fetchedClass), type);
                        requestError = [NSError generateSBBObjectNotFoundForType:type];
                        results = nil;
                        *stop = true;
                    }
                }];
                bridgeObjects = [results copy];
            } else {
                requestError = [NSError generateSBBObjectNotFoundForType:type];
            }
        }
    }];
    
    if ((requestError != nil) && (error != nil)) {
        *error = requestError;
    }
    
    return bridgeObjects;
}

#pragma mark - In-memory cache

- (dispatch_queue_t)bridgeObjectCacheQueue
{
    if (!_bridgeObjectCacheQueue) {
        _bridgeObjectCacheQueue = dispatch_queue_create("org.sagebase.BridgeObjectCacheQueue", DISPATCH_QUEUE_SERIAL);
    }
    
    return _bridgeObjectCacheQueue;
}

//// BE CAREFUL never to allow this to be called recursively, even indirectly.
//// The only way to ensure this is to never synchronously call out to anything
//// in dispatchBlock that you can't absolutely guarantee will never get back here.
//- (void)dispatchSyncToBridgeObjectCacheQueue:(dispatch_block_t)dispatchBlock
//{
//    dispatch_sync(self.bridgeObjectCacheQueue, dispatchBlock);
//}
//
//- (void)dispatchAsyncToBridgeObjectCacheQueue:(dispatch_block_t)dispatchBlock
//{
//    dispatch_async(self.bridgeObjectCacheQueue, dispatchBlock);
//}

- (NSString *)inMemoryKeyForType:(NSString *)type andId:(NSString *)objectId
{
    return [NSString stringWithFormat:@"%@:%@", type, objectId];
}

- (SBBBridgeObject *)inMemoryBridgeObjectOfType:(NSString *)type andId:(NSString *)objectId
{
    NSString *key = [self inMemoryKeyForType:type andId:objectId];
    __block SBBBridgeObject *object = nil;
    [self.cacheIOContext performBlockAndWait:^{
        object = [self.objectsCachedByTypeAndID objectForKey:key];
    }];
    
    return object;
}

// should only be called from within the context's queue
- (void)removeFromMemoryBridgeObjectOfType:(NSString *)type andId:(NSString *)objectId
{
    NSString *key = [self inMemoryKeyForType:type andId:objectId];
    [self.objectsCachedByTypeAndID removeObjectForKey:key];
}

// should only be called from within the context's queue
- (void)cleanupDeletedManagedObjectsFromMemoryCache
{
    NSMutableDictionary *cacheCopy = [self.objectsCachedByTypeAndID mutableCopy];
    for (NSString *key in self.objectsCachedByTypeAndID.allKeys) {
        SBBBridgeObject *bridgeObj = self.objectsCachedByTypeAndID[key];
        NSManagedObject *fetchedMO = [self cachedObjectForBridgeObject:bridgeObj inContext:self.cacheIOContext];
        if (!fetchedMO) {
            [cacheCopy removeObjectForKey:key];
        }
    }
    self.objectsCachedByTypeAndID = cacheCopy;
}

#pragma mark - CoreData cache

// must be called in the cacheIOContext private queue
- (NSManagedObject *)managedObjectOfEntity:(NSEntityDescription *)entity withId:(NSString *)objectId atKeyPath:(NSString *)keyPath
{
    NSManagedObject *fetchedMO = nil;
    
    if (entity && entity.userInfo[@"entityIDKeyPath"] && objectId.length && keyPath.length) {
        NSFetchRequest *request = [[NSFetchRequest alloc] init];
        [request setEntity:entity];
        
        NSRange range;
        BOOL keyPathIsIndexed = ((range = [keyPath rangeOfString:@"]"]).location != NSNotFound);
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"%K LIKE %@", keyPath, objectId];
        if (!keyPathIsIndexed) {
            [request setPredicate:predicate];
        }
        
        NSError *error;
        NSArray *objects = [self.cacheIOContext executeFetchRequest:request error:&error];
        
        if (objects.count && keyPathIsIndexed) {
            objects = [objects filteredArrayUsingPredicate:predicate];
        }
        
        if (objects.count) {
            NSAssert(objects.count == 1, @"%lu %@ objects found with %@ == @\"%@\"", (unsigned long)objects.count, entity.name, keyPath, objectId);
            fetchedMO = [objects firstObject];
        }
    }
    
    return fetchedMO;
}

dispatch_queue_t CoreDataQueueForPersistentStoreName(NSString *name)
{
    dispatch_queue_t queue = [gCoreDataQueuesByPersistentStoreName objectForKey:name];
    if (!queue) {
        NSString *qName = [NSString stringWithFormat:@"org.sagebase.CoreDataQueueFor%@", [name capitalizedString]];
        queue = dispatch_queue_create([qName cStringUsingEncoding:NSUTF8StringEncoding], DISPATCH_QUEUE_SERIAL);
        [gCoreDataQueuesByPersistentStoreName setObject:queue forKey:name];
    }
    
    return queue;
}

void removeCoreDataQueueForPersistentStoreName(NSString *name)
{
    [gCoreDataQueuesByPersistentStoreName removeObjectForKey:name];
}

// BE CAREFUL never to allow this to be called recursively, even indirectly.
// The only way to ensure this is to never synchronously call out to anything
// in dispatchBlock that you can't absolutely guarantee will never get back here.
- (void)dispatchSyncToCacheManagerCoreDataQueue:(dispatch_block_t)dispatchBlock
{
    dispatch_sync(CoreDataQueueForPersistentStoreName(self.persistentStoreName), dispatchBlock);
}

- (void)discardCacheManagerCoreDataQueue
{
    removeCoreDataQueueForPersistentStoreName(self.persistentStoreName);
}

- (NSURL *)appDocumentsDirectory
{
    return [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
}

- (NSManagedObjectModel *)managedObjectModel
{
    if (_managedObjectModel != nil)
    {
        return _managedObjectModel;
    }
    
    NSURL *modelURL = [[NSBundle bundleWithIdentifier:_bundleId] URLForResource:self.managedObjectModelName withExtension:@"momd"];
    if (!modelURL) {
        modelURL = [[NSBundle bundleWithIdentifier:_bundleId] URLForResource:self.managedObjectModelName withExtension:@"mom"];
    }
    
    _managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    
    //NSLog(@"_managedObjectModel: %@",_managedObjectModel);
    
    return _managedObjectModel;
}

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (_persistentStoreCoordinator != nil)
    {
        return _persistentStoreCoordinator;
    }
    
    NSURL *storeURL = [self storeURL];
    NSURL *storeDirURL = [self storeDirURL];
    NSError *error = nil;
    
    if (![[NSFileManager defaultManager] createDirectoryAtURL:storeDirURL withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"Error attempting to create persistent store directory at path %@:\n%@", storeDirURL.absoluteURL, error);
        return nil;
    }
    
    // Automatic Lightweight Migration
    NSMutableDictionary *options = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                    [NSNumber numberWithBool:YES], NSMigratePersistentStoresAutomaticallyOption,
                                    [NSNumber numberWithBool:YES], NSInferMappingModelAutomaticallyOption, nil];
    
    _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self managedObjectModel]];
    
    self.persistentStore = [_persistentStoreCoordinator addPersistentStoreWithType:_persistentStoreType configuration:nil URL:storeURL options:options error:&error];
    
    if (!self.persistentStore)
    {
        /*
         NOTE: Replace this implementation with code to handle the error appropriately.
         
         abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development. If it is not possible to recover from the error, display an alert panel that instructs the user to quit the application by pressing the Home button.
         
         Typical reasons for an error here include:
         * The persistent store is not accessible;
         * The schema for the persistent store is incompatible with current managed object model.
         Check the error message to determine what the actual problem was.
         
         
         If the persistent store is not accessible, there is typically something wrong with the file path. Often, a file URL is pointing into the application's resources directory instead of a writeable directory.
         
         If you encounter schema incompatibility errors during development, you can reduce their frequency by:
         * Simply deleting the existing store:
         
         [[NSFileManager defaultManager] removeItemAtURL:storeURL error:nil]
         
         * Performing automatic lightweight migration by passing the following dictionary as the options parameter:
         [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:YES], NSMigratePersistentStoresAutomaticallyOption, [NSNumber numberWithBool:YES], NSInferMappingModelAutomaticallyOption, nil];
         
         Lightweight migration will only work for a limited set of schema changes; consult "Core Data Model Versioning and Data Migration Programming Guide" for details.
         
         */
        
        NSString *message = [NSString stringWithFormat:@"Unresolved error %@, %@", error, [error localizedDescription]];
        NSLog(@"%@", message);
        
        // removing store
        [[NSFileManager defaultManager] removeItemAtURL:storeDirURL error:nil];
        
        // resetting _persistentStoreCoordinator
        _persistentStoreCoordinator = nil;
        
    }
    
    return _persistentStoreCoordinator;
}

- (NSURL *)storeDirURL
{
    NSURL *storeOrigin = nil;
    NSString *appGroupIdentifier = SBBBridgeInfo.shared.appGroupIdentifier;
    
    // if there's a shared container, use it; otherwise use the Documents directory
    if (appGroupIdentifier.length > 0) {
        storeOrigin = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:appGroupIdentifier];
    } else {
        storeOrigin = [self appDocumentsDirectory];
    }
    
    // put the persistent store in a subdirectory so it's easy to manage
    NSURL *storeDirURL = [storeOrigin URLByAppendingPathComponent:gPersistentStoreSubdirectory];
    
    return storeDirURL;
}

- (NSURL *)storeURL {
    return [[self storeDirURL] URLByAppendingPathComponent:self.persistentStoreName];
}

- (NSManagedObjectContext *)cacheIOContext
{
    if (!_cacheIOContext) {
        [self dispatchSyncToCacheManagerCoreDataQueue:^{
            // Check again in case it got set before we got our turn in the core data queue.
            if (_cacheIOContext != nil) {
                return;
            }
            
            // Now check if one already exists for this persistent store name.
            NSManagedObjectContext *cacheIOContext = gCoreDataCacheIOContextsByPersistentStoreName[self.persistentStoreName];
            if (!cacheIOContext) {
                // If not, then create one for this persistent store name and store it where other CacheManager instances can find it.
                cacheIOContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
                cacheIOContext.persistentStoreCoordinator = [self persistentStoreCoordinator];
                cacheIOContext.undoManager = [[NSUndoManager alloc] init];
                gCoreDataCacheIOContextsByPersistentStoreName[self.persistentStoreName] = cacheIOContext;
            }
            _cacheIOContext = cacheIOContext;
        }];
    }
    
    return _cacheIOContext;
}

- (void)saveCacheIOContext
{
    __block NSError *error;
    __block NSInteger SQLiteErrorCode = 0;
    NSManagedObjectContext *context = self.cacheIOContext;
    [context performBlock:^{
        if (![context save:&error]) {
            NSDictionary *errorInfo = [error userInfo];
            
            SQLiteErrorCode = [[errorInfo valueForKey:NSSQLiteErrorDomain] integerValue];
            
            if (SQLiteErrorCode == 11) {
                // if the error code is 11 'database disk image is malformed', delete and
                // rebuild the SQLite db
                if ([self resetCache]) {
                    NSLog(@"Corrupt SQLite db deleted and rebuilt");
                }
            }
#if DEBUG
            else {
                // Now that we're setting some attributes and relationships as non-optional,
                // we will get this error any time we add a new object to the cache that has
                // directly-cacheable subobjects and a non-optional relationship, when those
                // subobjects are recursively added and try to save the context before the
                // new object's non-optional relationship has been set. So we have to just
                // ignore this and assume at some point the context will get back into a
                // savable state and be saved to persistent store.
                NSLog(@"Error saving cache manager's managed object context. If this is a validation error and at some later time the context is successfully saved, you can ignore this error:\n%@",  error);
            }
        } else {
            NSLog(@"Cache manager's managed object context has been saved");
#endif
        }
    }];
}


- (BOOL)resetCache
{
    NSManagedObjectContext *context = self.cacheIOContext;
    __block BOOL reset = NO;
    [context performBlockAndWait:^{
        self.objectsCachedByTypeAndID = [NSMutableDictionary dictionary];
        reset = [self resetDatabase];
        if (reset) {
            // remove ourselves from the global cacheIOContext map
            gCoreDataCacheIOContextsByPersistentStoreName[self.persistentStoreName] = nil;
        }
    }];
    
    return reset;
}

- (BOOL)resetDatabase
{
    __block NSError *error;
    __block BOOL reset = NO;
    
    [self dispatchSyncToCacheManagerCoreDataQueue:^{
        [_cacheIOContext performBlockAndWait:^{
            [_cacheIOContext reset];
            
            if (_persistentStoreCoordinator) {
                if (![_persistentStoreCoordinator removePersistentStore:self.persistentStore error:&error]) {
                    NSLog(@"Unable to remove persistent store: error %@, %@", error, [error userInfo]);
                    return;
                }
            }
            _persistentStoreCoordinator = nil;
            _cacheIOContext= nil;
            _managedObjectModel = nil;
            
            if (![_persistentStoreType isEqualToString:NSInMemoryStoreType]) {
                NSURL *storeDirURL = [self storeDirURL];
                NSFileManager *fm = [NSFileManager defaultManager];
                if ([fm fileExistsAtPath:storeDirURL.path]) {
                    if (![fm removeItemAtURL:storeDirURL error:&error]) {
                        NSLog(@"Unable to delete SQLite db files directory at %@ : error %@, %@", storeDirURL, error, [error userInfo]);
                        return;
                    }
                }
            }
            
            reset = YES;
        }];
    }];
    
    return reset;
}


@end
