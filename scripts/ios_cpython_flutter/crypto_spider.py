"""Owned, offline protocol fixture for the unmodified upstream crypto primitives."""
import json
import Crypto
from Crypto.Cipher import AES, ARC4, DES, PKCS1_OAEP
from Crypto.Hash import MD5, SHA1, SHA256
from Crypto.PublicKey import RSA, ECC
from Crypto.Signature import DSS, eddsa
from Crypto.Util import _raw_api
from Crypto.Util.Padding import pad, unpad
from base.spider import Spider as BaseSpider


class Spider(BaseSpider):
    def init(self, extension):
        self.identity = extension
        self.previous = getattr(Crypto, 'owned_fixture_identity', None)
        Crypto.owned_fixture_identity = extension
        self.stream = AES.new(bytes(16), AES.MODE_CTR, nonce=bytes(8))
        self.stream_offset = 0

    def homeContent(self, filtered):
        from Crypto.Util._ios_loader import _MODULES
        # Exercise every shipped raw library, including less common algorithms;
        # do not infer runtime loadability merely from successful compilation.
        for name in _MODULES:
            _raw_api.load_pycryptodome_raw_lib(name, '')
        known = {
            'aes_ecb': AES.new(bytes(16), AES.MODE_ECB).encrypt(bytes(16)).hex()
                == '66e94bd4ef8a2c3b884cfa59ca342b2e',
            'aes_gcm': AES.new(bytes(16), AES.MODE_GCM, nonce=bytes(12)).encrypt_and_digest(b'')[1].hex()
                == '58e2fccefa7e3061367f1d57a4e7455a',
            'des': DES.new(bytes.fromhex('133457799bbcdff1'), DES.MODE_ECB).encrypt(bytes.fromhex('0123456789abcdef')).hex()
                == '85e813540f0ab405',
            'arc4': ARC4.new(b'Key').encrypt(b'Plaintext').hex() == 'bbf316e8d940af0ad3',
            'md5': MD5.new(b'abc').hexdigest() == '900150983cd24fb0d6963f7d28e17f72',
            'sha1': SHA1.new(b'abc').hexdigest() == 'a9993e364706816aba3e25717850c26c9cd0d89d',
            'sha256': SHA256.new(b'abc').hexdigest() == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
            'padding': unpad(pad('订阅'.encode(), 16), 16) == '订阅'.encode(),
        }
        return {'version': Crypto.__version__, 'modules': sorted(_MODULES), 'known': known,
                'owner': Crypto.owned_fixture_identity, 'previous': self.previous}

    def detailContent(self, ids):
        message = b'owned iOS crypto fixture'
        rsa = RSA.generate(1024)
        public = RSA.import_key(rsa.public_key().export_key())
        encrypted = PKCS1_OAEP.new(public, hashAlgo=SHA256).encrypt(message)
        clear = PKCS1_OAEP.new(rsa, hashAlgo=SHA256).decrypt(encrypted)
        ecc = ECC.generate(curve='P-256')
        signature = DSS.new(ecc, 'fips-186-3').sign(SHA256.new(message))
        DSS.new(ECC.import_key(ecc.public_key().export_key(format='PEM')), 'fips-186-3').verify(SHA256.new(message), signature)
        seed = bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')
        key = eddsa.import_private_key(seed)
        signed = eddsa.new(key, 'rfc8032').sign(b'')
        eddsa.new(key.public_key(), 'rfc8032').verify(b'', signed)
        return {'rsa': clear == message, 'ecc': True, 'ed25519': signed.hex() ==
                'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555f'
                'b8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b'}

    def liveContent(self, mode):
        if mode == 'stream':
            value = self.stream.encrypt(bytes(32)).hex()
            self.stream_offset += 32
            return json.dumps({'bytes': value, 'offset': self.stream_offset,
                               'owner': Crypto.owned_fixture_identity})
        if mode == 'parallel':
            data = bytes(512 * 1024)
            expected = SHA256.new(data).digest()
            for _ in range(24):
                ciphertext, tag = AES.new(bytes(32), AES.MODE_GCM, nonce=bytes(12)).encrypt_and_digest(data)
                plaintext = AES.new(bytes(32), AES.MODE_GCM, nonce=bytes(12)).decrypt_and_verify(ciphertext, tag)
                if SHA256.new(plaintext).digest() != expected:
                    raise ValueError('Concurrent crypto mismatch')
            return json.dumps({'owner': Crypto.owned_fixture_identity, 'bytes': len(data) * 24})
        raise ValueError('Unknown owned fixture operation')
