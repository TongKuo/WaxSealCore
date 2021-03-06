/*=============================================================================┐
|             _  _  _       _                                                  |  
|            (_)(_)(_)     | |                            _                    |██
|             _  _  _ _____| | ____ ___  ____  _____    _| |_ ___              |██
|            | || || | ___ | |/ ___) _ \|    \| ___ |  (_   _) _ \             |██
|            | || || | ____| ( (__| |_| | | | | ____|    | || |_| |            |██
|             \_____/|_____)\_)____)___/|_|_|_|_____)     \__)___/             |██
|                                                                              |██
|     _  _  _              ______             _ _______                  _     |██
|    (_)(_)(_)            / _____)           | (_______)                | |    |██
|     _  _  _ _____ _   _( (____  _____ _____| |_       ___   ____ _____| |    |██
|    | || || (____ ( \ / )\____ \| ___ (____ | | |     / _ \ / ___) ___ |_|    |██
|    | || || / ___ |) X ( _____) ) ____/ ___ | | |____| |_| | |   | ____|_     |██
|     \_____/\_____(_/ \_|______/|_____)_____|\_)______)___/|_|   |_____)_|    |██
|                                                                              |██
|                                                                              |██
|                         Copyright (c) 2015 Tong Guo                          |██
|                                                                              |██
|                             ALL RIGHTS RESERVED.                             |██
|                                                                              |██
└==============================================================================┘██
  ████████████████████████████████████████████████████████████████████████████████
  ██████████████████████████████████████████████████████████████████████████████*/

#import "WSCProtectedKeychainItem.h"
#import "WSCTrustedApplication.h"
#import "WSCPermittedOperation.h"
#import "WSCKeychainError.h"

#import "_WSCKeychainErrorPrivate.h"
#import "_WSCKeychainItemPrivate.h"
#import "_WSCPermittedOperationPrivate.h"

@implementation WSCProtectedKeychainItem

@dynamic secAccess;

#pragma mark Managing Permitted Operations
/* Creates a new permitted operation entry from the description, trusted application list, and prompt context provided
 * and adds it to the protected keychain item represented by receiver.
 */
- ( WSCPermittedOperation* ) addPermittedOperationWithDescription: ( NSString* )_Description
                                              trustedApplications: ( NSSet* )_TrustedApplications
                                                    forOperations: ( WSCPermittedOperationTag )_Operations
                                                    promptContext: ( WSCPermittedOperationPromptContext )_PromptContext
                                                            error: ( NSError** )_Error
    {
    NSError* error = nil;
    _WSCDontBeABitch( &error, self, [ WSCProtectedKeychainItem class ], s_guard );
    if ( error )
        {
        if ( _Error )
            *_Error = [ [ error copy ] autorelease ];

        return nil;
        }

    WSCPermittedOperation* newPermitted = nil;
    NSMutableArray* secTrustedApps = nil;

    // Convert the given Cocoa-array of WSCTrustedApplication
    // to the CoreFoundation-array of secTrustedApplicationRef
    if ( _TrustedApplications )
        {
        secTrustedApps = [ NSMutableArray arrayWithCapacity: _TrustedApplications.count ];
        [ _TrustedApplications enumerateObjectsUsingBlock:
            ^( WSCTrustedApplication* _TrustedApp, BOOL* _Stop )
                {
                [ secTrustedApps addObject: ( __bridge id )_TrustedApp.secTrustedApplication ];
                } ];
        }

    OSStatus resultCode = errSecSuccess;
    SecACLRef secNewACL = NULL;

    SecAccessRef secCurrentAccess = [ self p_secCurrentAccess: &error ];
    NSAssert( !error, error.description );

    if ( secCurrentAccess )
        {
        // Create the an ALC (Access Control List)
        if ( ( resultCode = SecACLCreateWithSimpleContents( secCurrentAccess
                                                          , ( __bridge CFArrayRef )secTrustedApps
                                                          , ( __bridge CFStringRef )_Description
                                                          , ( SecKeychainPromptSelector )_PromptContext
                                                          , &secNewACL
                                                          ) ) == errSecSuccess )
            {
            // Extract operation tags from the given bits field
            // to construct a list of authorizations that will be used for the secNewACL.
            NSArray* authorizations = _WACSecAuthorizationsFromPermittedOperationMasks( _Operations );

            // Update the authorizations of the secNewACL.
            // Because an ACL object is always associated with an access object,
            // when we modify an ACL entry, we are modifying the access object as well.
            // There is no need for a separate function to write a modified ACL object back into the secCurrentAccess object.
            if ( ( resultCode = SecACLUpdateAuthorizations( secNewACL, ( __bridge CFArrayRef )authorizations ) ) == errSecSuccess )
                // Write the modified access object (secCurrentAccess) that carries the secNewACL back into the protected keychain item represented by receiver.
                if ( ( resultCode = SecKeychainItemSetAccess( self.secKeychainItem, secCurrentAccess ) ) == errSecSuccess )
                    // Everything is OK, create the wrapper of the secNewACL that has been added to
                    // the list of permitted operations of the protected keychain item.
                    newPermitted = [ [ [ WSCPermittedOperation alloc ] p_initWithSecACLRef: secNewACL
                                                                                 appliesTo: self
                                                                                     error: _Error ] autorelease ];
            CFRelease( secNewACL );
            }

        CFRelease( secCurrentAccess );
        }

    if ( resultCode != errSecSuccess )
        if ( _Error )
            *_Error = [ NSError errorWithDomain: NSOSStatusErrorDomain code: resultCode userInfo: nil ];

    return newPermitted;
    }

/* Retrieves all the permitted operation entries of the protected keychain item represented by receiver.
 */
- ( NSArray* ) permittedOperations
    {
    NSError* error = nil;
    _WSCDontBeABitch( &error, self, [ WSCProtectedKeychainItem class ], s_guard );
    if ( error )
        {
        _WSCPrintNSErrorForLog( error );
        return nil;
        }

    OSStatus resultCode = errSecSuccess;
    NSMutableArray* mutablePermittedOperations = nil;

    SecAccessRef secCurrentAccess = [ self p_secCurrentAccess: &error ];
    if ( !error )
        {
        CFArrayRef secACLList = NULL;

        // Retrieves all the access control list entries of a given access object.
        if ( ( resultCode = SecAccessCopyACLList( secCurrentAccess, &secACLList ) ) == errSecSuccess )
            {
            mutablePermittedOperations = [ NSMutableArray array ];

            // Convert the given CoreFoundation-array of SecACLRef
            // to the Cocoa-array of WSCPermittedOperation by wrapping them into the WSCPermittedOperation class
            // and adding the wrapper to the mutable array.
            for ( id _SecACL in ( __bridge NSArray* )secACLList )
                {
                WSCPermittedOperation* newPermittedOperation =
                    [ WSCPermittedOperation permittedOperationWithSecACLRef: ( __bridge SecACLRef )_SecACL
                                                                  appliesTo: self
                                                                      error: &error ];
                if ( !error )
                    [ mutablePermittedOperations addObject: newPermittedOperation ];
                }

            CFRelease( secACLList );
            }

        CFRelease( secCurrentAccess );
        }

    if ( resultCode != errSecSuccess )
        {
        error = [ NSError errorWithDomain: NSOSStatusErrorDomain code: resultCode userInfo: nil ];
        _WSCPrintNSErrorForLog( error );
        }

    return [ [ mutablePermittedOperations copy ] autorelease ];
    }

#pragma mark Keychain Services Bridge

/* The reference of the `SecAccess` opaque object, which wrapped by `WSCProtectedKeychainItem` object. (read-only)
 */
- ( SecAccessRef ) secAccess
    {
    NSError* error = nil;
    SecAccessRef secCurrentAccess = [ self p_secCurrentAccess: &error ];
    NSAssert( !error, error.description );
    CFSetAddValue( self->_secAccessAutoReleasePool, secCurrentAccess );

    return secCurrentAccess;
    }

@end // WSCProtectedKeychainItem

/*================================================================================┐
|                              The MIT License (MIT)                              |
|                                                                                 |
|                           Copyright (c) 2015 Tong Guo                           |
|                                                                                 |
|  Permission is hereby granted, free of charge, to any person obtaining a copy   |
|  of this software and associated documentation files (the "Software"), to deal  |
|  in the Software without restriction, including without limitation the rights   |
|    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell    |
|      copies of the Software, and to permit persons to whom the Software is      |
|            furnished to do so, subject to the following conditions:             |
|                                                                                 |
| The above copyright notice and this permission notice shall be included in all  |
|                 copies or substantial portions of the Software.                 |
|                                                                                 |
|   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR    |
|    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,     |
|   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE   |
|     AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER      |
|  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,  |
|  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE  |
|                                    SOFTWARE.                                    |
└================================================================================*/