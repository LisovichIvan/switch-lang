#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Build-time tool only. Legacy public keychain APIs are required for an explicit
// workspace file; no login/System keychain, trust or search-list setter is used.
static NSData *readPrivateFile(int directory, const char *name, size_t limit) {
    int descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (descriptor < 0) return nil;
    struct stat metadata;
    bool valid = fstat(descriptor, &metadata) == 0 && S_ISREG(metadata.st_mode) &&
        metadata.st_uid == getuid() && metadata.st_nlink == 1 && (metadata.st_mode & 0777) == 0600 &&
        metadata.st_size > 0 && (uint64_t)metadata.st_size <= limit;
    NSMutableData *data = valid ? [NSMutableData dataWithLength:(NSUInteger)metadata.st_size] : nil;
    size_t position = 0;
    while (data != nil && position < data.length) {
        ssize_t count = read(descriptor, (char *)data.mutableBytes + position, data.length - position);
        if (count <= 0) { data = nil; break; }
        position += (size_t)count;
    }
    close(descriptor);
    return data;
}

static OSStatus verifyIdentity(SecKeychainRef keychain, NSData *certificateData) {
    if (keychain == NULL || certificateData == nil) return errSecParam;
    SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certificateData);
    if (certificate == NULL) return errSecDecode;
    SecIdentityRef identity = NULL;
    OSStatus status = SecIdentityCreateWithCertificate(keychain, certificate, &identity);
    if (status == errSecSuccess && identity == NULL) status = errSecItemNotFound;
    if (identity != NULL) CFRelease(identity);
    CFRelease(certificate);
    return status;
}

static OSStatus importIdentity(SecKeychainRef keychain, NSData *package, NSString *password) {
    if (keychain == NULL || package == nil || password == nil) return errSecParam;
    SecTrustedApplicationRef signer = NULL;
    OSStatus status = SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &signer);
    if (status == errSecSuccess && signer == NULL) status = errSecInternalComponent;
    SecAccessRef access = NULL;
    if (status == errSecSuccess) {
        status = SecAccessCreate(CFSTR("Switch Lang local signing"),
            (__bridge CFArrayRef)@[(__bridge id)signer], &access);
    }
    if (signer != NULL) CFRelease(signer);
    if (status == errSecSuccess && access == NULL) status = errSecInternalComponent;
    SecExternalFormat format = kSecFormatPKCS12;
    SecExternalItemType type = kSecItemTypeAggregate;
    SecItemImportExportKeyParameters parameters = {0};
    parameters.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;
    parameters.flags = kSecKeyImportOnlyOne;
    parameters.passphrase = (__bridge CFStringRef)password;
    parameters.accessRef = access;
    parameters.keyUsage = (__bridge CFArrayRef)@[(__bridge id)kSecAttrCanSign];
    parameters.keyAttributes = (__bridge CFArrayRef)@[(__bridge id)kSecAttrIsPermanent, (__bridge id)kSecAttrIsSensitive];
    CFArrayRef imported = NULL;
    if (status == errSecSuccess) {
        status = SecItemImport((__bridge CFDataRef)package, CFSTR(".p12"), &format, &type,
            0, &parameters, keychain, &imported);
    }
    if (imported != NULL) CFRelease(imported);
    if (access != NULL) CFRelease(access);
    return status;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 3 || argc > 4) return 64;
        bool create = strcmp(argv[1], "create") == 0;
        bool unlock = strcmp(argv[1], "unlock") == 0;
        bool check = strcmp(argv[1], "check") == 0;
        bool lock = strcmp(argv[1], "lock") == 0;
        if ((!create && !unlock && !check && !lock) || argc != (create ? 4 : 3) ||
            strstr(argv[2], "/login.keychain") != NULL) return 64;
        int directory = open(argv[2], O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        struct stat metadata;
        if (directory < 0) return 1;
        if (fstat(directory, &metadata) != 0 || metadata.st_uid != getuid() ||
            (metadata.st_mode & 0777) != 0700) { close(directory); return 1; }
        NSString *path = [@(argv[2]) stringByAppendingPathComponent:@"local-signing.keychain-db"];
        struct stat keychainMetadata;
        bool exists = fstatat(directory, "local-signing.keychain-db", &keychainMetadata, AT_SYMLINK_NOFOLLOW) == 0;
        if ((create && exists) || (!create && (!exists || !S_ISREG(keychainMetadata.st_mode) ||
            keychainMetadata.st_uid != getuid() || keychainMetadata.st_nlink != 1 ||
            (keychainMetadata.st_mode & 0777) != 0600))) {
            close(directory); return 1;
        }
        NSData *passwordData = lock ? nil : readPrivateFile(directory, "password", 64);
        NSData *certificate = lock ? nil : readPrivateFile(directory, "certificate.der", 16384);
        NSString *password = passwordData.length == 64 ?
            [[NSString alloc] initWithData:passwordData encoding:NSASCIIStringEncoding] : nil;
        if (!lock && (password == nil || certificate == nil ||
            [password rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
                @"0123456789abcdef"] invertedSet]].location != NSNotFound)) {
            close(directory); return 1;
        }
        OSStatus status = SecKeychainSetUserInteractionAllowed(false);
        SecKeychainRef keychain = NULL;
        if (status == errSecSuccess) {
            status = create ? SecKeychainCreate(path.fileSystemRepresentation, (UInt32)passwordData.length,
                passwordData.bytes, false, NULL, &keychain) :
                SecKeychainOpen(path.fileSystemRepresentation, &keychain);
        }
        if (status == errSecSuccess && keychain == NULL) status = errSecInternalComponent;
        if (status == errSecSuccess && create) {
            // The private parent protects creation before the final mode is set.
            if (chmod(path.fileSystemRepresentation, 0600) != 0) status = errSecIO;
            SecKeychainSettings settings = {SEC_KEYCHAIN_SETTINGS_VERS1, true, true, 300};
            if (status == errSecSuccess) status = SecKeychainSetSettings(keychain, &settings);
            int packageDirectory = open(argv[3], O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            struct stat packageMetadata;
            bool privatePackage = packageDirectory >= 0 && fstat(packageDirectory, &packageMetadata) == 0 &&
                packageMetadata.st_uid == getuid() && (packageMetadata.st_mode & 0777) == 0700;
            NSData *package = privatePackage ? readPrivateFile(packageDirectory, "identity.p12", 65536) : nil;
            if (packageDirectory >= 0) close(packageDirectory);
            if (status == errSecSuccess) status = importIdentity(keychain, package, password);
        } else if (status == errSecSuccess && !lock) {
            status = SecKeychainUnlock(keychain, (UInt32)passwordData.length, passwordData.bytes, true);
        }
        if (status == errSecSuccess && !lock) status = verifyIdentity(keychain, certificate);
        // Failed unlock/check/create operations never intentionally leave it open.
        if (keychain != NULL && (!unlock || status != errSecSuccess)) {
            OSStatus locked = SecKeychainLock(keychain);
            if (status == errSecSuccess) status = locked;
        }
        if (keychain != NULL) CFRelease(keychain);
        close(directory);
        if (status != errSecSuccess) fprintf(stderr, "Local signing keychain operation failed: %d\n", (int)status);
        return status == errSecSuccess ? 0 : 1;
    }
}
