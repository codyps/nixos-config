#import <Foundation/Foundation.h>
#import <Security/Security.h>

static void check(BOOL condition, NSString *message) {
  if (!condition) {
    fprintf(stderr, "%s\n", message.UTF8String);
    exit(1);
  }
}

// The partition ACL stores a hex-encoded property list in its description.
static NSArray<NSString *> *decodePartitions(NSString *description) {
  NSData *data = [description dataUsingEncoding:NSUTF8StringEncoding];
  if (![description hasPrefix:@"<?xml"]) {
    check(description.length % 2 == 0, @"Invalid partition ACL description");
    NSMutableData *decoded = [NSMutableData dataWithCapacity:description.length / 2];
    for (NSUInteger index = 0; index < description.length; index += 2) {
      unsigned value;
      NSString *pair = [description substringWithRange:NSMakeRange(index, 2)];
      NSScanner *scanner = [NSScanner scannerWithString:pair];
      check([scanner scanHexInt:&value] && scanner.isAtEnd, @"Invalid partition ACL hex");
      unsigned char byte = value;
      [decoded appendBytes:&byte length:1];
    }
    data = decoded;
  }

  NSError *error = nil;
  id plist = [NSPropertyListSerialization propertyListWithData:data
      options:NSPropertyListImmutable format:NULL error:&error];
  check([plist isKindOfClass:[NSDictionary class]], @"Invalid partition ACL property list");
  NSArray *partitions = plist[@"Partitions"];
  check([partitions isKindOfClass:[NSArray class]], @"Missing Keychain partition list");
  for (id partition in partitions) {
    check([partition isKindOfClass:[NSString class]] && [partition length] > 0 &&
        [partition rangeOfCharacterFromSet:
            [NSCharacterSet characterSetWithCharactersInString:@",\r\n"]].location == NSNotFound,
        @"Invalid Keychain partition ID");
  }
  return partitions;
}

int main(int argc, char **argv) {
  if (argc != 4) return 1;
  @autoreleasepool {
    SecKeychainRef keychain = NULL;
    check(SecKeychainOpen(argv[1], &keychain) == errSecSuccess, @"Cannot open login Keychain");
    NSDictionary *query = @{
      (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
      (__bridge id)kSecAttrService: @(argv[2]),
      (__bridge id)kSecAttrAccount: @(argv[3]),
      (__bridge id)kSecMatchSearchList: @[CFBridgingRelease(keychain)],
      (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
      (__bridge id)kSecReturnRef: @YES,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) return 2;
    check(status == errSecSuccess, @"Cannot look up Keychain item");
    NSArray *items = CFBridgingRelease(result);
    check(items.count == 1, @"Expected exactly one matching Keychain item");

    SecAccessRef access = NULL;
    check(SecKeychainItemCopyAccess((__bridge SecKeychainItemRef)items[0], &access) ==
        errSecSuccess, @"Cannot read Keychain item access controls");
    CFArrayRef aclList = NULL;
    status = SecAccessCopySelectedACLList(access, CSSM_ACL_AUTHORIZATION_PARTITION_ID, &aclList);
    CFRelease(access);
    check(status == errSecSuccess, @"Cannot read Keychain partition ACL");
    NSArray *acls = CFBridgingRelease(aclList);
    check(acls.count == 1, @"Expected exactly one Keychain partition ACL");

    CFArrayRef applications = NULL;
    CFStringRef description = NULL;
    SecKeychainPromptSelector selector = 0;
    status = SecACLCopyContents((__bridge SecACLRef)acls[0], &applications, &description, &selector);
    if (applications) CFRelease(applications);
    check(status == errSecSuccess && description, @"Cannot read Keychain partition ACL contents");
    NSArray *partitions = decodePartitions(CFBridgingRelease(description));
    puts([partitions componentsJoinedByString:@","].UTF8String);
  }
  return 0;
}
