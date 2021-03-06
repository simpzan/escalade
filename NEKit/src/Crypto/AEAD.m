//
//  AEAD.m
//  NEKit
//
//  Created by simpzan on 2018/10/27.
//  Copyright © 2018 Zhuhao Wang. All rights reserved.
//

#import "AEAD.h"
#import <Sodium/Sodium.h>
#import <CommonCrypto/CommonCrypto.h>

@interface Hmac : NSObject
- (instancetype)initWithAlgorithm:(CCHmacAlgorithm)algorithm key:(NSData *)key;
- (instancetype)update:(NSData *)data;
- (instancetype)updateWithBytes:(const uint8_t *)bytes length:(size_t)len;
- (NSData *)final;
+ (NSData *)generateWithAgorithm:(CCHmacAlgorithm)algorithm key:(NSData *)key data:(NSData *)data;
@end

@implementation Hmac {
    CCHmacContext _ctx;
    CCHmacAlgorithm _algorithm;
}
- (instancetype)initWithAlgorithm:(CCHmacAlgorithm)algorithm key:(NSData *)key {
    self = [super init];
    CCHmacInit(&_ctx, algorithm, key.bytes, key.length);
    _algorithm = algorithm;
    return self;
}
- (instancetype)update:(NSData *)data {
    CCHmacUpdate(&_ctx, data.bytes, data.length);
    return self;
}
- (instancetype)updateWithBytes:(const uint8_t *)bytes length:(size_t)len {
    CCHmacUpdate(&_ctx, bytes, len);
    return self;
}
- (NSData *)final {
    NSDictionary *lengths = @{
        @(kCCHmacAlgSHA1):   @(CC_SHA1_DIGEST_LENGTH),
        @(kCCHmacAlgMD5):    @(CC_MD5_DIGEST_LENGTH),
        @(kCCHmacAlgSHA256): @(CC_SHA256_DIGEST_LENGTH),
        @(kCCHmacAlgSHA384): @(CC_SHA384_DIGEST_LENGTH),
        @(kCCHmacAlgSHA512): @(CC_SHA512_DIGEST_LENGTH),
        @(kCCHmacAlgSHA224): @(CC_SHA224_DIGEST_LENGTH)
    };
    NSUInteger len = [lengths[@(_algorithm)] unsignedIntegerValue];
    NSMutableData *result = [NSMutableData dataWithLength:len];
    CCHmacFinal(&_ctx, result.mutableBytes);
    return result;
}
+ (NSData *)generateWithAgorithm:(CCHmacAlgorithm)algorithm key:(NSData *)key data:(NSData *)data {
    Hmac *mac = [[Hmac alloc]initWithAlgorithm:algorithm key:key];
    return [[mac update:data] final];
}
@end

static NSData *generateSubkey(NSData *masterKey, NSData *salt, NSData *info) {
    NSData *prk = [Hmac generateWithAgorithm:kCCHmacAlgSHA1 key:salt data:masterKey];
    
    NSMutableData *subkey = [NSMutableData data];
    NSUInteger length = 32;
    int count = (int)ceil(length / (float)CC_SHA1_DIGEST_LENGTH);

    NSData *mixin = [NSData data];
    for (uint8_t i=1; i<=count; ++i) {
        Hmac *mac = [[Hmac alloc]initWithAlgorithm:kCCHmacAlgSHA1 key:prk];
        [mac update:mixin];
        [mac update:info];
        [mac updateWithBytes:&i length:1];
        mixin = [mac final];
        [subkey appendData:mixin];
    }
    return [subkey subdataWithRange:NSMakeRange(0, length)];
}

NSUInteger tag_len = 16;
NSUInteger chunk_size_len = 2;

@implementation AEAD {
    NSData *subkey;
    NSMutableData *nonce;
    NSMutableData *buffer;
    crypto_aead_aes256gcm_state gcmState;
    AEADAlgorithm algorithm;
}
- (NSUInteger)aead_encrypt:(const uint8_t *)plain :(NSUInteger)length :(uint8_t *)cipher {
    NSUInteger expectedLength = length + tag_len;
    unsigned long long actualLength = 0;
    int err = 0;
    if (algorithm == AEAD_AES256GCM) {
        err = crypto_aead_aes256gcm_encrypt_afternm(cipher, &actualLength,
                plain, length, NULL, 0, NULL, nonce.bytes, &gcmState);
    } else {
        err = crypto_aead_chacha20poly1305_ietf_encrypt(cipher, &actualLength,
                plain, length, NULL, 0, NULL, nonce.bytes, subkey.bytes);
    }
    assert(err == 0);
    assert(actualLength == expectedLength);
    return expectedLength;
}
- (NSUInteger)aead_decrypt:(const uint8_t *)cipher :(NSUInteger)length :(uint8_t *)plain {
    NSUInteger expectedLength = length - tag_len;
    unsigned long long actualLength = 0;
    int err = 0;
    if (algorithm == AEAD_AES256GCM) {
        err = crypto_aead_aes256gcm_decrypt_afternm(plain, &actualLength,
                NULL, cipher, length, NULL, 0, nonce.bytes, &gcmState);
    } else {
        err = crypto_aead_chacha20poly1305_ietf_decrypt(plain, &actualLength,
                NULL, cipher, length, NULL, 0, nonce.bytes, subkey.bytes);
    }
    assert(err == 0);
    assert(actualLength == expectedLength);
    return expectedLength;
}
- (instancetype)initWithMasterKey:(NSData *)key :(NSData *)salt :(AEADAlgorithm)algorithmName {
    self = [super init];
    NSData *info = [@"ss-subkey" dataUsingEncoding:NSUTF8StringEncoding];
    subkey = generateSubkey(key, salt, info);
    nonce = [NSMutableData dataWithLength:12];
    buffer = [NSMutableData data];
    memset(&gcmState, 0, sizeof(gcmState));
    algorithm = algorithmName;
    if (algorithm == AEAD_AES256GCM) {
        int error = crypto_aead_aes256gcm_beforenm(&gcmState, subkey.bytes);
        if (error) NSLog(@"crypto_aead_aes256gcm_beforenm failed.");
    }
    return self;
}
- (NSData *)encrypted:(NSData *)plainData {
    NSUInteger cipherLength = tag_len * 2 + plainData.length + chunk_size_len;
    NSMutableData *cipherData = [NSMutableData dataWithLength:cipherLength];
    uint8_t *cipher = cipherData.mutableBytes;
    
    uint16_t len = htons(plainData.length);
    cipher += [self aead_encrypt:(const uint8_t *)&len :sizeof(len) :cipher];
    sodium_increment(nonce.mutableBytes, nonce.length);

    cipher += [self aead_encrypt:plainData.bytes :plainData.length :cipher];
    sodium_increment(nonce.mutableBytes, nonce.length);
    
    return cipherData;
}
- (NSUInteger)_decrypted:(const uint8_t *)cipherData :(NSUInteger)length :(uint8_t *)plain {
    if (length <= tag_len * 2 + chunk_size_len) return 0;

    NSUInteger cipherLengthLen = chunk_size_len + tag_len;
    [self aead_decrypt:cipherData :cipherLengthLen :plain];
    uint16_t len = *(uint16_t *)plain;
    len = ntohs(len);
    NSUInteger chunkLength = 2 * tag_len + chunk_size_len + len;
    if (length < chunkLength) return 0;

    sodium_increment(nonce.mutableBytes, nonce.length);

    NSUInteger cipherPayloadLen = len + tag_len;
    const uint8_t *cipherPayload = cipherData + cipherLengthLen;
    NSUInteger result = [self aead_decrypt:cipherPayload :cipherPayloadLen :plain];
    sodium_increment(nonce.mutableBytes, nonce.length);

    return result;
}
- (NSData *)decrypted:(NSData *)cipherData {
    [buffer appendData:cipherData];
    const uint8_t *buf = buffer.bytes;
    NSUInteger bufLen = buffer.length;
    NSMutableData *plainData = [NSMutableData dataWithLength:buffer.length];
    uint8_t *plain = plainData.mutableBytes;
    NSUInteger plainLength = 0;
    while (true) {
        NSUInteger length = [self _decrypted:buf :bufLen :plain];
        if (length == 0) break;
        
        NSUInteger chunkLen = length + chunk_size_len + 2 * tag_len;
        assert(bufLen >= chunkLen);
        bufLen -= chunkLen;
        buf += chunkLen;
        plain += length;
        plainLength += length;
    }
    buffer = [NSMutableData dataWithBytes:buf length:bufLen];
    plainData.length = plainLength;
    return plainData;
}
@end
