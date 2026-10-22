import test from 'node:test';
import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import * as deviceAuth from '../src/device-auth.mjs';

test('account mapping keeps original HMAC bytes and identity isolation',()=>{
  assert.equal(typeof deviceAuth.accountIDForAppleIdentity,'function');
  const map=deviceAuth.accountIDForAppleIdentity,key=Buffer.alloc(32,7);
  const identity={issuer:'https://appleid.apple.com',subject:'fixture-primary'};
  const original=createHmac('sha256',key).update(identity.issuer+'\n'+identity.subject).digest('hex');
  assert.equal(map(key,identity),original);assert.match(original,/^[a-f0-9]{64}$/);
  assert.equal(map(key,identity),map(key,{...identity}));
  for(const changed of [{...identity,subject:'alternate'},{...identity,issuer:'other-issuer'},{...identity,subject:' fixture-primary'}])assert.notEqual(map(key,changed),original);
  assert.notEqual(map(Buffer.alloc(32,8),identity),original);
  assert.notEqual(map(key,{...identity,subject:'\u00e9'}),map(key,{...identity,subject:'e\u0301'}));
});
