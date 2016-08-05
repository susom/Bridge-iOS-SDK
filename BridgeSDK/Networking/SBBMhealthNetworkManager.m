/*
 Copyright (c) 2016, Sage Bionetworks. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without modification,
 are permitted provided that the following conditions are met:
 
 1.  Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.
 
 2.  Redistributions in binary form must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation and/or
 other materials provided with the distribution.
 
 3. Neither the name of the copyright holder(s) nor the names of any contributors
 may be used to endorse or promote products derived from this software without
 specific prior written permission. No license is granted to the trademarks of
 the copyright holders even if such marks are included in this software.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
 FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "SBBMhealthNetworkManager.h"

NSString *kStanfordBackgroundSessionIdentifier = @"edu.stanford.backgroundsession";

@interface SBBNetworkManager (BackgroundSession)

-(NSString*) baseURL;
-(NSURLSession*) backgroundSession;
-(void) setBackgroundSession:(NSURLSession *)backgroundSession;
-(void (^)(void)) backgroundCompletionHandler;
-(void)setBackgroundCompletionHandler:(void (^)(void))backgroundCompletionHandler;
@end

@interface SBBMhealthNetworkManager ()
@property (nonatomic, strong) NSURLSession * mHealthBackgroundSession; //For upload/download tasks
@end

@implementation SBBMhealthNetworkManager

- (NSURLSession *)backgroundSession
{
    if (!_mHealthBackgroundSession) {
      // dispatch_once to make sure there's only ever one instance of a background session created with this identifier
      static NSURLSession *bgSession;
      static dispatch_once_t onceToken;
      dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:kStanfordBackgroundSessionIdentifier];
        bgSession = [NSURLSession sessionWithConfiguration:config delegate:(id<NSURLConnectionDataDelegate, NSURLSessionDownloadDelegate>)self delegateQueue:nil];
      });
      
      _mHealthBackgroundSession = bgSession;
    }
  
    return _mHealthBackgroundSession;
}

- (void)restoreBackgroundSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler
{
  // make sure we're being called with the expected identifier--if not, ignore
  if ([identifier isEqualToString:kStanfordBackgroundSessionIdentifier]) {
    [self backgroundSession];
    self.backgroundCompletionHandler = completionHandler;
  }
}

- (NSURL *) URLForRelativeorAbsoluteURLString: (NSString*) URLString
{
    if ([URLString hasPrefix:@"/"]) {
        URLString = [URLString substringFromIndex:1];
    }
   
    NSURL *url = [NSURL URLWithString:URLString];
    if ([url.scheme.lowercaseString hasPrefix:@"http"]) {
        return url;
    }
    else
    {
        return [NSURL URLWithString:[NSString stringWithFormat:@"%@%@", self.baseURL, URLString]];
    }
}

@end
